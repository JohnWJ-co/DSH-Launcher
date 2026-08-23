import Foundation

/// 升级 / 强制重建 / 源码克隆（对齐飞牛版 build.go 的 CheckUpdate/Upgrade/Rebuild）。
/// pnpm 调用优先 corepack（尊重 repo 钉死的 packageManager 版本），规避本机 pnpm 大版本不一致问题。
@MainActor @Observable
final class UpdateService {
    private(set) var checking = false
    private(set) var hasUpdate = false
    private(set) var currentCommit = ""
    private(set) var remoteCommit = ""
    private(set) var building = false
    private(set) var lastError = ""

    private let harness: HarnessService
    private let configProvider: () -> LauncherConfig
    private let toolchainProvider: () -> Toolchain?

    init(harness: HarnessService,
         configProvider: @escaping () -> LauncherConfig,
         toolchainProvider: @escaping () -> Toolchain?) {
        self.harness = harness
        self.configProvider = configProvider
        self.toolchainProvider = toolchainProvider
    }

    /// git fetch --depth=1 对比 HEAD 与 FETCH_HEAD（15s 超时）
    @discardableResult
    func checkUpdate() async -> Bool {
        checking = true
        defer { checking = false }
        let cfg = configProvider()
        currentCommit = await GitService.currentCommit(sourceURL: cfg.sourceURL) ?? ""
        let (remote, error) = await GitService.fetchRemoteCommit(sourceURL: cfg.sourceURL, proxy: cfg.networkProxy)
        if let error {
            lastError = error
            hasUpdate = false
            harness.message(error)
            return false
        }
        remoteCommit = remote ?? ""
        lastError = ""
        hasUpdate = !currentCommit.isEmpty && !remoteCommit.isEmpty && currentCommit != remoteCommit
        return hasUpdate
    }

    /// 升级（git pull --ff-only + install + build）或强制重建（reset --hard + install + build）
    @discardableResult
    func upgrade(forceRebuild: Bool) async -> Bool {
        guard !building else { return false }
        guard harness.status != .starting, harness.status != .building else {
            harness.message("服务正在\(harness.status == .starting ? "启动" : "构建")，请稍后再试")
            return false
        }
        let cfg = configProvider()
        guard let toolchain = toolchainProvider() else {
            harness.message("未找到 node，无法执行构建")
            return false
        }
        guard let pnpm = toolchain.pnpmCommand(sourceURL: cfg.sourceURL) else {
            harness.message("未找到可用的 pnpm（corepack 或 npx），无法执行构建")
            return false
        }
        let wasRunning = harness.status == .running
        if wasRunning { await harness.stopAndWait() }
        guard harness.beginBuilding() else { return false }
        building = true
        defer {
            building = false
            harness.endBuilding()
        }
        let logs = harness.logs
        let src = cfg.sourceURL
        let env = HarnessService.childEnv(config: cfg, toolchain: toolchain)

        func fail(_ reason: String) -> Bool {
            lastError = reason
            harness.message(reason)
            logs.launcherMessage(reason, level: "ERROR")
            return false
        }

        // 1. git 同步
        if forceRebuild {
            logs.launcherMessage("强制重建：git reset --hard …")
            guard await GitService.resetHard(sourceURL: src, logs: logs) else {
                return fail("强制重建失败：git reset --hard 出错")
            }
        } else {
            logs.launcherMessage("升级：git pull --ff-only …")
            let (ok, err) = await GitService.pull(sourceURL: src, proxy: cfg.networkProxy, logs: logs)
            guard ok else { return fail(err ?? "git pull 失败") }
        }
        // 2. 依赖安装
        logs.launcherMessage("安装依赖：\(pnpm.path) \(pnpm.args.joined(separator: " ")) install …")
        let install = await ShellRunner.run(path: pnpm.path, args: pnpm.args + ["install"],
                                            cwd: src.path, env: env, timeout: 900, logs: logs)
        guard install.code == 0 else {
            return fail("依赖安装失败（exit \(install.code)），详见运行日志")
        }
        // 3. 构建
        logs.launcherMessage("构建：\(pnpm.path) \(pnpm.args.joined(separator: " ")) run build …")
        let build = await ShellRunner.run(path: pnpm.path, args: pnpm.args + ["run", "build"],
                                          cwd: src.path, env: env, timeout: 1800, logs: logs)
        guard build.code == 0 else {
            return fail("构建失败（exit \(build.code)），详见运行日志")
        }
        // 4. 刷新版本信息并按需恢复运行
        harness.refreshMeta()
        harness.message(forceRebuild ? "重建完成" : "升级完成")
        logs.launcherMessage(forceRebuild ? "重建完成" : "升级完成")
        if wasRunning {
            await harness.startWithRetry()
        }
        return true
    }

    /// 源码不存在时克隆 harness 仓库（--depth=1）
    @discardableResult
    func cloneSource() async -> Bool {
        guard !building else { return false }
        let cfg = configProvider()
        let dst = cfg.sourceURL
        guard !FileManager.default.fileExists(atPath: dst.path) else { return true }
        guard harness.beginBuilding() else { return false }
        building = true
        defer {
            building = false
            harness.endBuilding()
        }
        let logs = harness.logs
        logs.launcherMessage("克隆 harness 源码到 \(dst.path) …")
        let (ok, err) = await GitService.clone(dst: dst, proxy: cfg.networkProxy, logs: logs)
        guard ok else {
            lastError = err ?? "克隆失败"
            harness.message(lastError)
            return false
        }
        harness.message("源码克隆完成，接下来将安装依赖并构建")
        return await upgrade(forceRebuild: false) || true
    }
}
