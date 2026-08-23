import Foundation

/// 插件管理编排（对齐 fnos plugins.go 的 launchPluginOp / runPluginOpWithRecovery / handleListPlugins）。
/// 环境适配差异：macOS 不强制 npmmirror registry（尊重本机 npm 配置，按设计共识）。
@MainActor @Observable
final class PluginService {
    struct PluginItem: Identifiable, Equatable {
        var name: String
        var version: String
        var spec: String
        var state: String          // live / disabled / inert
        var entryIDs: [String]
        var descriptionText: String
        var author: String
        var homepage: String
        var license: String
        var keywords: [String]
        var isProtected: Bool
        var hasBundle: Bool
        var id: String { name }
    }

    struct PluginMeta {
        var name: String
        var version: String
        var descriptionText: String
        var homepage: String
        var license: String
        var keywords: [String]
        var author: String
        var hasBundle: Bool
    }

    struct ProfileManifest {
        var deps: [String: String]
        var bundles: [String]
        var legacyDisabled: [String]
    }

    private(set) var running = false
    private(set) var ok: Bool?
    private(set) var message = ""
    private(set) var list: [PluginItem] = []
    private(set) var bundles: [String] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var needsRestart = false

    private var currentProcess: ChildProcess?
    private var cancelled = false

    let logs: LogStore
    private let configProvider: () -> LauncherConfig
    private let toolchainProvider: () -> Toolchain?
    private let harnessStatus: () -> HarnessStatus

    init(logs: LogStore,
         configProvider: @escaping () -> LauncherConfig,
         toolchainProvider: @escaping () -> Toolchain?,
         harnessStatus: @escaping () -> HarnessStatus) {
        self.logs = logs
        self.configProvider = configProvider
        self.toolchainProvider = toolchainProvider
        self.harnessStatus = harnessStatus
    }

    // MARK: - 路径

    var profileDir: URL {
        Paths.dshHome(configProvider().dshHome).appendingPathComponent("profiles/web", isDirectory: true)
    }
    var patchPath: String { profileDir.appendingPathComponent("cordis.patch.yml").path }
    var workspaceYamlPath: String { profileDir.appendingPathComponent("pnpm-workspace.yaml").path }
    var sidecarPath: String { Paths.allowBuildsSidecar.path }

    /// fnos pluginEnv 的 macOS 适配版（去掉 npmmirror registry 强制）
    static let pluginEnv: [String: String] = [
        "NPM_CONFIG_FETCH_TIMEOUT": "30000",
        "NPM_CONFIG_NETWORK_TIMEOUT": "30000",
        "NPM_CONFIG_FETCH_RETRIES": "2",
        "NPM_CONFIG_FETCH_RETRY_MINTIMEOUT": "2000",
        "NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT": "10000",
        "PNPM_CONFIG_FETCH_TIMEOUT": "30000",
        "PNPM_CONFIG_NETWORK_TIMEOUT": "30000",
        "PNPM_CONFIG_FETCH_RETRIES": "2",
    ]

    static func verbTimeout(_ verb: PluginVerb) -> TimeInterval {
        switch verb {
        case .remove: return 60
        case .add, .update, .install: return 180
        case .list, .why: return 30
        }
    }

    // MARK: - 元数据读取

    func readProfileManifest() -> ProfileManifest? {
        let path = profileDir.appendingPathComponent("package.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let deps = obj["dependencies"] as? [String: String] ?? [:]
        let dsh = obj["dsh"] as? [String: Any]
        let profile = dsh?["profile"] as? [String: Any]
        return ProfileManifest(
            deps: deps,
            bundles: (profile?["bundles"] as? [String]) ?? [],
            legacyDisabled: (profile?["disabled"] as? [String]) ?? [])
    }

    func installedMetadata(_ name: String) -> PluginMeta? {
        let cfg = configProvider()
        let home = Paths.dshHome(cfg.dshHome)
        let candidates = [
            profileDir.appendingPathComponent("node_modules/\(name)/package.json").path,
            home.appendingPathComponent("profiles/node_modules/\(name)/package.json").path,
            cfg.sourceURL.appendingPathComponent("node_modules/\(name)/package.json").path,
        ]
        for path in candidates {
            guard let meta = parsePackageMeta(path) else { continue }
            return meta
        }
        return nil
    }

    private func parsePackageMeta(_ path: String) -> PluginMeta? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return nil }
        var author = ""
        if let a = obj["author"] as? String {
            author = a
        } else if let a = obj["author"] as? [String: Any], let n = a["name"] as? String {
            author = n
        }
        let dsh = obj["dsh"] as? [String: Any]
        let bundle = dsh?["bundle"] as? [String: Any]
        let patch = bundle?["patch"] as? String
        return PluginMeta(
            name: name,
            version: (obj["version"] as? String) ?? "",
            descriptionText: (obj["description"] as? String) ?? "",
            homepage: (obj["homepage"] as? String) ?? "",
            license: (obj["license"] as? String) ?? "",
            keywords: (obj["keywords"] as? [String]) ?? [],
            author: author,
            hasBundle: !(patch ?? "").isEmpty)
    }

    // MARK: - 命令构造（fnos dshArgs 逐字移植）

    private func profileHasWorkspace() -> Bool {
        FileManager.default.fileExists(atPath: workspaceYamlPath)
    }

    func dshArgs(_ cmd: PluginCommand) -> [String] {
        if cmd.verb == .update {
            // 更新重构：注入 minimumReleaseAge=0 穿透 pnpm 11 新鲜期限制，并解析真实最新目标
            var args = ["plugin", "--profile", cmd.profile, "add"]
            if profileHasWorkspace() { args.append("-w") }
            args.append("--config.minimumReleaseAge=0")
            for spec in cmd.specs {
                args.append(resolveUpdateTarget(spec))
            }
            return args
        }
        var args = ["plugin", "--profile", cmd.profile, cmd.verb.rawValue]
        if (cmd.verb == .add || cmd.verb == .remove) && profileHasWorkspace() {
            args.append("-w")
        }
        if cmd.verb == .add || cmd.verb == .install {
            args.append("--config.minimumReleaseAge=0")
        }
        args += cmd.specs
        return args
    }

    func resolveUpdateTarget(_ spec: String) -> String {
        let norm = PluginParsing.normalizePluginKey(spec)
        if let manifest = readProfileManifest(),
           let origSpec = manifest.deps[norm], !origSpec.isEmpty,
           origSpec.hasPrefix("github:") || origSpec.hasPrefix("git+")
               || origSpec.hasPrefix("http:") || origSpec.hasPrefix("https:") {
            return origSpec
        }
        var target = norm
        if target.hasPrefix("@") {
            if !target.dropFirst().contains("@") {
                target += "@latest"
            }
        } else if !target.contains("@") && !target.hasPrefix("github:") {
            target += "@latest"
        }
        return target
    }

    private func pluginAllowKey(_ cmd: PluginCommand) -> String {
        if cmd.specs.isEmpty { return "" }
        return cmd.specs.map { PluginParsing.normalizePluginKey($0) }.joined(separator: " ")
    }

    // MARK: - 进程执行

    private enum OpOutcome {
        case success(output: String)
        case failure(tail: String)
        case timedOut(seconds: TimeInterval)
        case cancelledByUser
        case envError(String)
    }

    private func runPluginProcess(args: [String], timeout: TimeInterval) async -> OpOutcome {
        let cfg = configProvider()
        guard let toolchain = toolchainProvider(),
              let dsh = DshCommand.resolve(sourceURL: cfg.sourceURL, toolchain: toolchain) else {
            return .envError("运行环境未就绪或依赖文件缺失")
        }
        var env = HarnessService.childEnv(config: cfg, toolchain: toolchain)
        for (k, v) in Self.pluginEnv { env[k] = v }
        let spec = ChildProcess.Spec(path: dsh.executable,
                                     args: dsh.prefixArgs + args,
                                     env: env,
                                     cwd: cfg.sourceURL.path)
        guard let proc = ChildProcess(spec: spec) else {
            return .envError("无法启动插件操作进程")
        }
        currentProcess = proc
        cancelled = false
        let tailLock = NSLock()
        var tail = Data()
        var fullOutput: [String] = []
        let outputLock = NSLock()
        let box = TimeoutBox()
        proc.onLine = { [weak self] stream, line in
            let text = stream == .stderr ? "[stderr] \(line)" : line
            self?.logs.append(text)
            tailLock.lock()
            tail.append(contentsOf: Array(line.utf8))
            tail.append(0x0A)
            if tail.count > 800 { tail.removeFirst(tail.count - 800) }
            tailLock.unlock()
            outputLock.lock()
            fullOutput.append(line)
            outputLock.unlock()
        }
        let exitCode: Int32 = await withCheckedContinuation { cont in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !proc.hasExited {
                    box.timedOut = true
                    self.logs.launcherMessage(
                        "[插件管理] 操作执行超时 (\(Int(timeout))s)，正在强制终止进程组 (PID: \(proc.pid))...",
                        level: "WARN")
                    proc.forceKill()
                }
            }
            proc.onExit = { code in
                timeoutTask.cancel()
                cont.resume(returning: code)
            }
            proc.begin()
        }
        currentProcess = nil
        tailLock.lock()
        let tailText = String(decoding: tail, as: UTF8.self)
        tailLock.unlock()
        outputLock.lock()
        let outputText = fullOutput.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        outputLock.unlock()

        if cancelled { return .cancelledByUser }
        if box.timedOut { return .timedOut(seconds: timeout) }
        if exitCode == 0 { return .success(output: outputText) }
        return .failure(tail: tailText)
    }

    private final class TimeoutBox: @unchecked Sendable {
        var timedOut = false
    }

    // MARK: - 带自愈的执行（六类，顺序对齐 fnos）

    private func runPluginOpWithRecovery(_ cmd: PluginCommand, doneMsg: String) async -> (Bool, String) {
        let timeout = Self.verbTimeout(cmd.verb)
        let args = dshArgs(cmd)

        // list / why：同步执行，输出直接返回
        if cmd.verb == .list || cmd.verb == .why {
            let outcome = await runPluginProcess(args: args, timeout: timeout)
            switch outcome {
            case .success(let output):
                return (true, output.isEmpty ? "操作完成" : output)
            case .failure(let tail):
                return (false, PnpmFailure.formatMessage(tail))
            case .timedOut(let seconds):
                return (false, "插件操作超时（超过 \(Int(seconds))秒），已自动终止")
            case .cancelledByUser:
                return (false, "操作已被用户手动取消")
            case .envError(let msg):
                return (false, msg)
            }
        }

        var outcome = await runPluginProcess(args: args, timeout: timeout)
        if case .success = outcome { return (true, doneMsg) }
        guard cmd.verb == .add || cmd.verb == .update || cmd.verb == .install else {
            if case .failure(let tail) = outcome { return (false, PnpmFailure.formatMessage(tail)) }
            if case .timedOut(let seconds) = outcome {
                return (false, "插件操作超时（超过 \(Int(seconds))秒），已自动终止")
            }
            if case .cancelledByUser = outcome { return (false, "操作已被用户手动取消") }
            if case .envError(let msg) = outcome { return (false, msg) }
            return (false, "插件指令执行失败")
        }
        guard case .failure(var tail) = outcome else {
            // 超时/取消/环境错误对可自愈动词也直接返回
            switch outcome {
            case .timedOut(let seconds):
                return (false, "插件操作超时（超过 \(Int(seconds))秒），网络请求或依赖解析未能按时完成，已自动终止")
            case .cancelledByUser:
                return (false, "操作已被用户手动取消")
            case .envError(let msg):
                return (false, msg)
            default:
                return (false, "插件指令执行失败")
            }
        }
        var failure = PnpmFailure.classify(tail)

        // 自愈 1：跨大版本 Hoist 差异
        if failure.code == .hoistPatternDiff {
            logs.launcherMessage("[自动自愈] 依赖结构存在跨版本差异，正在执行重建 (pnpm install --no-frozen-lockfile)...", level: "WARN")
            _ = await runPluginProcess(args: ["plugin", "--profile", cmd.profile, "install", "--no-frozen-lockfile"],
                                       timeout: timeout)
            outcome = await runPluginProcess(args: args, timeout: timeout)
            if case .success = outcome { return (true, doneMsg + "（已自动重建依赖环境）") }
            if case .failure(let t) = outcome { tail = t; failure = PnpmFailure.classify(tail) }
            else { return plainOutcome(outcome) }
        }
        // 自愈 2：存储位置变更
        if failure.code == .unexpectedStore {
            try? FileManager.default.removeItem(atPath: profileDir.appendingPathComponent("node_modules").path)
            logs.launcherMessage("[自动自愈] 存储位置变更，已自动清理本地缓存并重试: \(cmd.display)", level: "WARN")
            outcome = await runPluginProcess(args: args, timeout: timeout)
            if case .success = outcome { return (true, doneMsg) }
            if case .failure(let t) = outcome { tail = t; failure = PnpmFailure.classify(tail) }
            else { return plainOutcome(outcome) }
        }
        // 自愈 3：新鲜发布安全期
        if failure.code == .releaseAge {
            logs.launcherMessage("[自动自愈] 新发布版本受安全期检查拦截，已自动追加 --config.minimumReleaseAge=0 重试...", level: "WARN")
            outcome = await runPluginProcess(args: args + ["--config.minimumReleaseAge=0"], timeout: timeout)
            if case .success = outcome { return (true, doneMsg + "（已自动放行新发布版本）") }
            if case .failure(let t) = outcome { tail = t; failure = PnpmFailure.classify(tail) }
            else { return plainOutcome(outcome) }
        }
        // 自愈 4：慢网/大包下载超时（超时延长 10 分钟）
        if failure.code == .fetchTimeout {
            logs.launcherMessage("[自动自愈] 大包下载超时，正在以 10 分钟超时延长重试...", level: "WARN")
            outcome = await runPluginProcess(args: args + ["--config.fetchTimeout=600000"],
                                             timeout: timeout + 600)
            if case .success = outcome { return (true, doneMsg + "（已自动延长超时完成下载）") }
            if case .failure(let t) = outcome { tail = t; failure = PnpmFailure.classify(tail) }
            else { return plainOutcome(outcome) }
        }
        // 自愈 5：瞬态网络抖动（原参重试 1 次）
        if failure.code == .transientNetwork {
            logs.launcherMessage("[自动自愈] 检测到网络瞬时波动，正在自动重试 1 次...", level: "WARN")
            outcome = await runPluginProcess(args: args, timeout: timeout)
            if case .success = outcome { return (true, doneMsg) }
            if case .failure(let t) = outcome { tail = t; failure = PnpmFailure.classify(tail) }
            else { return plainOutcome(outcome) }
        }
        // 自愈 6：构建脚本拦截（allowBuilds 放行）
        let blocked = AllowBuilds.parseBlockedPackages(tail)
        if !blocked.isEmpty {
            do {
                try AllowBuilds.ensureAllowed(profileWorkspaceYaml: workspaceYamlPath,
                                              sidecarPath: sidecarPath,
                                              pluginKey: pluginAllowKey(cmd),
                                              pkgs: blocked)
                logs.launcherMessage("[自动自愈] 构建脚本被拦截 [\(blocked.joined(separator: ", "))]，已自动配置放行并重新执行", level: "WARN")
                outcome = await runPluginProcess(args: args, timeout: timeout)
                if case .success = outcome {
                    return (true, doneMsg + "（已自动放行构建脚本: " + blocked.joined(separator: ", ") + "）")
                }
                if case .failure(let t) = outcome { tail = t }
                else { return plainOutcome(outcome) }
            } catch {
                logs.launcherMessage("[自动自愈] 配置 allowBuilds 失败: \(error.localizedDescription)", level: "WARN")
            }
        }
        return (false, PnpmFailure.formatMessage(tail))
    }

    private func plainOutcome(_ outcome: OpOutcome) -> (Bool, String) {
        switch outcome {
        case .success:
            return (true, "操作完成")
        case .failure(let tail):
            return (false, PnpmFailure.formatMessage(tail))
        case .timedOut(let seconds):
            return (false, "插件操作超时（超过 \(Int(seconds))秒），网络请求或依赖解析未能按时完成，已自动终止")
        case .cancelledByUser:
            return (false, "操作已被用户手动取消")
        case .envError(let msg):
            return (false, msg)
        }
    }

    // MARK: - 对外动作

    func run(_ input: String) {
        let (cmd, reason) = PluginParsing.parse(input)
        guard let cmd else {
            ok = false
            message = reason ?? "命令解析失败"
            return
        }
        Task { await self.runCommand(cmd) }
    }

    func runCommand(_ cmd: PluginCommand) async {
        guard !running else {
            ok = false
            message = "插件操作正在进行中，请稍候"
            return
        }
        let hs = harnessStatus()
        if hs == .building {
            ok = false; message = "正在构建中，请稍候再试"; return
        }
        if hs == .starting {
            ok = false; message = "服务正在启动中，请稍候再试"; return
        }
        let cfg = configProvider()
        guard let toolchain = toolchainProvider(),
              DshCommand.resolve(sourceURL: cfg.sourceURL, toolchain: toolchain) != nil,
              readProfileManifest() != nil else {
            ok = false
            message = "运行环境未就绪或依赖文件缺失"
            return
        }
        // add 查重
        if cmd.verb == .add, let manifest = readProfileManifest() {
            for spec in cmd.specs {
                let norm = PluginParsing.normalizePluginKey(spec)
                if manifest.deps[norm] != nil, let meta = installedMetadata(norm), !meta.version.isEmpty {
                    ok = false
                    message = "插件「\(norm)」已安装 (当前版本: \(meta.version))"
                    return
                }
            }
        }
        // remove 保护
        if cmd.verb == .remove {
            for spec in cmd.specs {
                let norm = PluginParsing.normalizePluginKey(spec)
                if CordisPatch.isProtectedPlugin(norm) {
                    ok = false
                    message = "核心基础设施插件「\(norm)」受到保护，禁止卸载"
                    return
                }
            }
        }

        running = true
        defer { running = false }

        let doneMsg: String
        let startMsg: String
        switch cmd.verb {
        case .add, .install:
            doneMsg = "安装完成，重启服务后生效"
            startMsg = "已开始执行插件安装"
        case .remove:
            doneMsg = "卸载完成，重启服务后生效"
            startMsg = "已开始卸载插件「\(cmd.specs.joined(separator: " "))」"
        case .update:
            doneMsg = "更新完成，重启服务后生效"
            startMsg = "已开始更新插件「\(cmd.specs.joined(separator: " "))」"
        default:
            doneMsg = "操作完成"
            startMsg = "已开始执行插件指令"
        }
        ok = true
        message = startMsg
        logs.launcherMessage("[插件管理] \(cmd.display)")

        // update 前记录旧版本
        var before: [String: String] = [:]
        if cmd.verb == .update {
            for spec in cmd.specs {
                let name = PluginParsing.normalizePluginKey(spec)
                before[name] = installedMetadata(name)?.version ?? ""
            }
        }

        let (success, resultMsg) = await runPluginOpWithRecovery(cmd, doneMsg: doneMsg)
        var finalMsg = resultMsg
        if success {
            if cmd.verb == .update, let stale = staleUpdateMessage(cmd, before: before) {
                finalMsg = stale
            }
            if cmd.verb == .remove {
                for spec in cmd.specs {
                    try? CordisPatch.removePluginEntries(patchPath: patchPath, packageName: spec, entryIDs: [])
                }
                let key = pluginAllowKey(cmd)
                if !key.isEmpty {
                    do {
                        try AllowBuilds.cleanup(profileWorkspaceYaml: workspaceYamlPath,
                                                sidecarPath: sidecarPath, pluginKey: key)
                    } catch {
                        logs.launcherMessage("清理 allowBuilds 失败: \(error.localizedDescription)", level: "WARN")
                    }
                }
            }
            if harnessStatus() == .running {
                needsRestart = true
            }
        }
        ok = success
        message = finalMsg
        await refreshList()
    }

    /// update 后版本比对（fnos Stale Update Detection，分隔符为中文分号）
    private func staleUpdateMessage(_ cmd: PluginCommand, before: [String: String]) -> String? {
        guard !cmd.specs.isEmpty else { return nil }
        var details: [String] = []
        var hasAnyUpgrade = false
        for spec in cmd.specs {
            let name = PluginParsing.normalizePluginKey(spec)
            guard let oldVer = before[name], !oldVer.isEmpty else { continue }
            guard let meta = installedMetadata(name), !meta.version.isEmpty else { continue }
            let cmp = Self.compareVersions(meta.version, oldVer)
            if cmp > 0 {
                details.append("\(name): v\(oldVer) -> v\(meta.version)")
                hasAnyUpgrade = true
            } else if meta.version == oldVer {
                details.append("\(name): 当前已是最新版本 (v\(meta.version))")
            } else {
                details.append("\(name): v\(meta.version)")
                hasAnyUpgrade = true
            }
        }
        if details.isEmpty { return nil }
        if !hasAnyUpgrade {
            return details.joined(separator: "；") + "，远端无新发布版本"
        }
        return "更新完成（" + details.joined(separator: "；") + "），重启服务后生效"
    }

    /// semver 比较；非 semver 退化为字典序（对齐 fnos CompareSemver）
    nonisolated static func compareVersions(_ a: String, _ b: String) -> Int {
        guard let va = SemVer(a), let vb = SemVer(b) else {
            if a == b { return 0 }
            return a < b ? -1 : 1
        }
        if va < vb { return -1 }
        if va > vb { return 1 }
        return 0
    }

    func cancel() {
        if let p = currentProcess, !p.hasExited {
            logs.launcherMessage("[插件管理] 收到取消请求，正在终止插件操作进程组 (PID: \(p.pid))...", level: "WARN")
            cancelled = true
            p.stopRequested = true
            p.forceKill()
            message = "已发送取消指令"
        } else {
            ok = false
            message = "当前没有正在执行的插件操作"
        }
    }

    func toggle(_ name: String, enabled: Bool) {
        let (err, ids) = CordisPatch.setPluginDisabled(patchPath: patchPath,
                                                       profileDir: profileDir.path,
                                                       packageName: name,
                                                       disabled: !enabled)
        if let err {
            ok = false
            message = err
            return
        }
        logs.launcherMessage("[Cordis Patch] 已通过 user patch \(enabled ? "启用" : "禁用") 插件 \(name) (Entry IDs: \(ids))")
        ok = true
        message = enabled ? "已启用插件" : "已禁用插件"
        if harnessStatus() == .running {
            needsRestart = true
        }
        Task { await self.refreshList() }
    }

    func updateOne(_ name: String) {
        Task { await self.runCommand(PluginCommand(profile: "web", verb: .update, specs: [name])) }
    }

    func removeOne(_ name: String) {
        Task { await self.runCommand(PluginCommand(profile: "web", verb: .remove, specs: [name])) }
    }

    func clearNeedsRestart() { needsRestart = false }

    // MARK: - 插件列表（fnos handleListPlugins 移植）

    func refreshList() async {
        loading = true
        defer {
            loading = false
            loaded = true
        }
        guard let manifest = readProfileManifest() else {
            list = []
            bundles = []
            return
        }
        var rows: [[String: Any]] = []
        if let r = try? CordisPatch.read(path: patchPath) { rows = r }
        var disabledMap = CordisPatch.readDisabledEntryMap(rows)

        // 旧版 disabled 迁移
        for disName in manifest.legacyDisabled {
            let trimmed = disName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let ids = CordisPatch.extractPluginEntryIDs(profileDir: profileDir.path, packageName: trimmed)
            if !ids.contains(where: { disabledMap.contains($0) }) {
                let (err, _) = CordisPatch.setPluginDisabled(patchPath: patchPath,
                                                             profileDir: profileDir.path,
                                                             packageName: trimmed,
                                                             disabled: true)
                if err == nil {
                    disabledMap.formUnion(ids)
                    logs.launcherMessage("[历史配置迁移] 检测到旧版 package.json 中的 disabled 状态，已自动无缝迁移至官方 cordis.patch.yml: \(trimmed)")
                }
            }
        }

        let bundleSet = Set(manifest.bundles)
        var items: [PluginItem] = []
        for name in manifest.deps.keys.sorted() {
            let spec = manifest.deps[name] ?? ""
            let meta = installedMetadata(name)
            let hasBundle = meta?.hasBundle ?? false
            let ids = CordisPatch.extractPluginEntryIDs(profileDir: profileDir.path, packageName: name)
            var state = "live"
            if ids.contains(where: { disabledMap.contains($0) }) {
                state = "disabled"
            } else if !hasBundle && !bundleSet.contains(name) {
                state = "inert"
            }
            items.append(PluginItem(
                name: name,
                version: meta?.version ?? "",
                spec: spec,
                state: state,
                entryIDs: ids,
                descriptionText: meta?.descriptionText ?? "",
                author: meta?.author ?? "",
                homepage: meta?.homepage ?? "",
                license: meta?.license ?? "",
                keywords: meta?.keywords ?? [],
                isProtected: CordisPatch.isProtectedPlugin(name),
                hasBundle: hasBundle))
        }
        list = items
        bundles = manifest.bundles
    }
}
