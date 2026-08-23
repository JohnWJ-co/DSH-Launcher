import Foundation
import AppKit

enum HarnessStatus: String {
    case stopped, starting, running, building

    var displayName: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .building: return "构建中"
        }
    }
}

/// harness 生命周期状态机（对齐飞牛版 harness.go/process.go）：
/// 四态 + 3 秒看门狗巡检自愈 + 官方就绪信号（stdout 的 "dsh web: http://…" 行）
/// + SIGTERM→5s→SIGKILL 进程组停止 + 启动时孤儿清理（pid 文件 + lsof，替代飞牛的 fuser）。
@MainActor @Observable
final class HarnessService {
    private(set) var status: HarnessStatus = .stopped
    private(set) var lastMessage = ""
    private(set) var pid: pid_t?
    private(set) var startedAt: Date?
    private(set) var boundPort: Int?
    private(set) var readyURL: URL?
    private(set) var version = ""
    private(set) var commit = ""

    let logs = LogStore()

    private var child: ChildProcess?
    private var watchdogTimer: Timer?
    private var readyFlag = false
    private var readyPort: Int?
    private var startTimedOut = false
    private let configProvider: () -> LauncherConfig
    private let toolchainProvider: () -> Toolchain?

    init(configProvider: @escaping () -> LauncherConfig,
         toolchainProvider: @escaping () -> Toolchain?) {
        self.configProvider = configProvider
        self.toolchainProvider = toolchainProvider
    }

    private var config: LauncherConfig { configProvider() }

    // MARK: - 元信息

    func refreshMeta() {
        let src = config.sourceURL
        version = DshCommand.readVersion(sourceURL: src) ?? ""
        Task {
            commit = await GitService.currentCommit(sourceURL: src) ?? ""
        }
    }

    func message(_ text: String) { lastMessage = text }

    // MARK: - 启动

    func start() {
        guard status == .stopped else {
            message("当前状态（\(status.displayName)）不允许启动")
            return
        }
        let cfg = config
        guard let toolchain = toolchainProvider() else {
            message("未找到 node，请在“设置”中指定 node 路径")
            logs.launcherMessage("启动中止：未找到 node 工具链", level: "WARN")
            return
        }
        if !toolchain.nodeVersionOK {
            logs.launcherMessage("node 版本 \(toolchain.nodeVersion) 不满足 dsh 要求（^22.19.0 || >=24），仅警告不阻断", level: "WARN")
        }
        guard let dsh = DshCommand.resolve(sourceURL: cfg.sourceURL, toolchain: toolchain) else {
            message("未找到 harness 启动入口（apps/cli/lib/bin.js），请检查源码路径或先在源码目录执行构建")
            logs.launcherMessage("启动中止：未找到 dsh 启动入口（源码路径 \(cfg.sourcePath)）", level: "WARN")
            return
        }
        guard ConfigStore.isPortAvailable(cfg.serverPort) else {
            message("端口 \(cfg.serverPort) 已被占用，请先停止占用进程或修改端口")
            logs.launcherMessage("启动中止：端口 \(cfg.serverPort) 已被占用", level: "WARN")
            return
        }

        readyFlag = false
        readyPort = nil
        startTimedOut = false
        status = .starting

        let spec = ChildProcess.Spec(
            path: toolchain.nodeURL.path,
            args: dsh.prefixArgs + ["web", "--no-open", "--port", String(cfg.serverPort)],
            env: Self.childEnv(config: cfg, toolchain: toolchain),
            cwd: cfg.sourceURL.path)
        guard let proc = ChildProcess(spec: spec) else {
            status = .stopped
            message("进程启动失败（posix_spawn 错误）")
            return
        }
        child = proc
        writePid(proc.pid)
        logs.launcherMessage("启动 harness：node \(dsh.prefixArgs.joined(separator: " ")) web --no-open --port \(cfg.serverPort)")

        proc.onLine = { [weak self] stream, line in
            let text = stream == .stderr ? "[stderr] \(line)" : line
            Task { @MainActor [weak self] in
                self?.logs.append(text)
                self?.checkReady(line: line)
            }
        }
        proc.onExit = { [weak self] code in
            Task { @MainActor [weak self] in
                self?.finishExit(code: code)
            }
        }
        proc.begin()
        waitForReady(proc: proc)
        message("正在启动…")
    }

    /// 官方就绪信号：stdout 打出 "dsh web: http://127.0.0.1:<port>"
    private static let readyRegex = try? NSRegularExpression(pattern: #"dsh web: https?://([0-9.]+):(\d+)"#)

    private func checkReady(line: String) {
        guard status == .starting, !readyFlag,
              let regex = Self.readyRegex else { return }
        let range = NSRange(line.startIndex..., in: line)
        if let m = regex.firstMatch(in: line, options: [], range: range),
           let portStr = Range(m.range(at: 2), in: line).map({ String(line[$0]) }),
           let port = Int(portStr) {
            readyFlag = true
            readyPort = port
            if let hostR = Range(m.range(at: 1), in: line) {
                readyURL = URL(string: "http://\(line[hostR]):\(port)")
            }
        }
    }

    private func waitForReady(proc: ChildProcess) {
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if proc.hasExited { return }
                if self.readyFlag {
                    self.markRunning(port: self.readyPort ?? self.config.serverPort)
                    return
                }
                if Self.tcpReachable(port: self.config.serverPort) {
                    self.readyFlag = true
                    self.markRunning(port: self.config.serverPort)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // 60 秒总超时：杀进程组并报错（对齐飞牛版）
            if !proc.hasExited {
                self.startTimedOut = true
                self.logs.launcherMessage("启动超时：60 秒内未检测到服务就绪，终止进程", level: "WARN")
                proc.forceKill()
            }
        }
    }

    private func markRunning(port: Int) {
        guard status == .starting else { return }
        status = .running
        startedAt = Date()
        boundPort = port
        if readyURL == nil { readyURL = URL(string: "http://127.0.0.1:\(port)") }
        if let readyURL { message("服务已就绪：\(readyURL.absoluteString)") }
        logs.launcherMessage("harness 已就绪，端口 \(port)")
    }

    // MARK: - 停止 / 重启

    func stop() {
        guard status == .running || status == .starting else { return }
        message("正在停止…")
        Task { await self.stopAndWait() }
    }

    func restart() {
        guard status == .running || status == .starting else { return }
        Task {
            await self.stopAndWait()
            await self.startWithRetry()
        }
    }

    /// 启动（端口尚未释放时自动重试，最多 5 次、间隔 1 秒）
    func startWithRetry() async {
        for _ in 0..<5 {
            start()
            if status == .starting || status == .running { return }
            guard lastMessage.contains("端口") else { return }
            logs.launcherMessage("端口尚未释放，1 秒后重试启动…", level: "WARN")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func stopAndWait() async {
        guard let proc = child else { return }
        await proc.terminate(grace: 5)
        if !proc.hasExited { proc.forceKill() }
        for _ in 0..<40 where child != nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if child != nil {
            logs.launcherMessage("退出回调未达，本地纠偏为已停止", level: "WARN")
            finishExit(code: 0)
        }
    }

    /// App 退出时同步停止（applicationWillTerminate 里调用，尽量快）
    func shutdownSync() {
        guard let proc = child else { return }
        proc.stopRequested = true
        kill(-proc.pid, SIGTERM)
        kill(proc.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !proc.hasExited {
            usleep(100_000)
        }
        if !proc.hasExited {
            kill(-proc.pid, SIGKILL)
            kill(proc.pid, SIGKILL)
        }
        removePidFile()
    }

    private func finishExit(code: Int32) {
        guard let proc = child else { return }
        let requested = proc.stopRequested
        child = nil
        startReadyReset()
        removePidFile()
        status = .stopped
        startedAt = nil
        boundPort = nil
        pid = nil
        if startTimedOut {
            message("启动超时：60 秒内未检测到服务就绪")
            startTimedOut = false
        } else if requested {
            message("harness 已停止")
            logs.launcherMessage("harness 已停止")
        } else if code == 0 {
            message("harness 已退出")
            logs.launcherMessage("harness 已退出", level: "WARN")
        } else {
            message("harness 异常退出（exit \(code)），详情见运行日志")
            logs.launcherMessage("harness 异常退出（exit \(code)）", level: "WARN")
        }
    }

    private func startReadyReset() {
        readyFlag = false
        readyPort = nil
        readyURL = nil
    }

    // MARK: - 构建态（升级/重建/克隆共用）

    /// 要求当前处于 stopped
    func beginBuilding() -> Bool {
        guard status == .stopped else { return false }
        status = .building
        return true
    }

    func endBuilding() {
        if status == .building { status = .stopped }
    }

    // MARK: - 看门狗（3 秒巡检，对齐飞牛版 inspectAndHeal）

    func startWatchdog() {
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.inspectAndHeal() }
        }
    }

    private func inspectAndHeal() {
        switch status {
        case .running, .starting:
            if let child {
                if child.hasExited {
                    finishExit(code: 0)
                } else if !child.isAlive {
                    logs.launcherMessage("看门狗：进程已死亡但退出事件未达，执行清理", level: "WARN")
                    child.forceKill()
                    finishExit(code: -1)
                }
            } else {
                logs.launcherMessage("看门狗：状态与进程不一致，已纠偏为停止", level: "WARN")
                startReadyReset()
                removePidFile()
                status = .stopped
            }
        case .stopped:
            if FileManager.default.fileExists(atPath: Paths.pidFile.path) {
                removePidFile()
            }
        case .building:
            break
        }
    }

    // MARK: - pid 文件

    private func writePid(_ pid: pid_t) {
        try? String(pid).write(to: Paths.pidFile, atomically: true, encoding: .utf8)
        self.pid = pid
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: Paths.pidFile)
    }

    // MARK: - 子进程环境（对齐飞牛版 InitAppEnv / ApplyProxyEnv 的 macOS 适配版）

    static func childEnv(config: LauncherConfig, toolchain: Toolchain) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = ""
        if let pnpmDir = toolchain.pnpmBinDir { path += pnpmDir + ":" }
        path += toolchain.nodeDir + ":" + (env["PATH"] ?? "")
        env["PATH"] = path
        let dshHome = Paths.expand(config.dshHome)
        if !dshHome.isEmpty { env["DSH_HOME"] = dshHome }
        env["CI"] = "true"
        let proxy = config.networkProxy.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty {
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                env[key] = proxy
            }
            env["NO_PROXY"] = "localhost,127.0.0.1,::1"
            env["NODE_USE_ENV_PROXY"] = "1"
        }
        return env
    }

    // MARK: - 探测/清理工具

    /// TCP 直连探测（loopback，非阻塞 connect + poll 500ms）
    nonisolated static func tcpReachable(port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 500) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// App 启动时清理上次残留（pid 文件 + 端口占用，对齐飞牛版 KillHarness 四步清理的 macOS 版）
    nonisolated static func cleanupOrphans(config: LauncherConfig, logs: LogStore) {
        let pidPath = Paths.pidFile.path
        if let text = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            let cmd = commandLine(of: pid)
            if kill(pid, 0) == 0 && (cmd.contains("bin.js") || cmd.contains("dsh")) {
                logs.launcherMessage("发现上次残留的 harness 进程（pid \(pid)），正在清理", level: "WARN")
                kill(-pid, SIGTERM); kill(pid, SIGTERM)
                usleep(300_000)
                kill(-pid, SIGKILL); kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(atPath: pidPath)

        // 端口占用（fuser 的 macOS 替代：lsof）
        let port = config.serverPort
        let out = runSync(path: "/usr/sbin/lsof", args: ["-t", "-i", ":\(port)"])
        for line in out.split(separator: "\n") {
            guard let pid = Int32(line), pid > 1 else { continue }
            let cmd = commandLine(of: pid)
            if cmd.contains("node") && (cmd.contains("bin.js") || cmd.contains("dsh")) {
                kill(pid, SIGTERM)
                usleep(200_000)
                kill(pid, SIGKILL)
                logs.launcherMessage("清理占用端口 \(port) 的残留进程（pid \(pid)）", level: "WARN")
            }
        }
    }

    nonisolated static func commandLine(of pid: pid_t) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated static func runSync(path: String, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
