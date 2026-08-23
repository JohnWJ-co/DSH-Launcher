import Foundation

/// 以独立进程组（POSIX_SPAWN_SETPGROUP）拉起子进程，
/// 支持 stdout/stderr 行回调、退出回调、进程组级优雅终止（SIGTERM → 宽限 → SIGKILL）。
/// 对齐飞牛版 process.go 的进程组语义（fuser 在 macOS 无对应，端口清理由调用方用 lsof 处理）。
final class ChildProcess {
    enum Stream { case stdout, stderr }

    struct Spec {
        var path: String
        var args: [String]
        var env: [String: String]
        var cwd: String?
    }

    let pid: pid_t
    var onLine: ((Stream, String) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// 标记主动停止，用于区分“正常停止”与“异常退出”
    var stopRequested = false

    private let ioQueue = DispatchQueue(label: "dsh.launcher.childio", qos: .utility)
    private var exited = false
    private let exitLock = NSLock()
    private var procSource: DispatchSourceProcess?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var outAssembler = LineAssembler()
    private var errAssembler = LineAssembler()
    private var reaped = false

    init?(spec: Spec) {
        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setpgroup(&attrs, 0)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        pipe(&outPipe)
        pipe(&errPipe)

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])
        if let cwd = spec.cwd {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
        }

        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(spec.path)]
        for a in spec.args { cArgs.append(strdup(a)) }
        cArgs.append(nil)
        let envList = spec.env.map { "\($0.key)=\($0.value)" }.sorted()
        var cEnv: [UnsafeMutablePointer<CChar>?] = envList.map { strdup($0) }
        cEnv.append(nil)

        defer {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
            posix_spawnattr_destroy(&attrs)
            posix_spawn_file_actions_destroy(&fileActions)
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, spec.path, &fileActions, &attrs, &cArgs, &cEnv)
        guard rc == 0 else { return nil }

        // 父进程关闭写端
        close(outPipe[1])
        close(errPipe[1])
        pid = childPid

        stdoutHandle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        stderrHandle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
    }

    /// 在设置完 onLine/onExit 回调后调用，开始读流与退出监听
    func begin() {
        startReading()
        watchExit()
    }

    private func startReading() {
        let outH = stdoutHandle, errH = stderrHandle
        outH?.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if data.isEmpty {
                h.readabilityHandler = nil
                if let rest = self.outAssembler.flush() { self.emit(.stdout, rest) }
            } else if let lines = self.outAssembler.push(data) {
                for l in lines { self.emit(.stdout, l) }
            }
        }
        errH?.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if data.isEmpty {
                h.readabilityHandler = nil
                if let rest = self.errAssembler.flush() { self.emit(.stderr, rest) }
            } else if let lines = self.errAssembler.push(data) {
                for l in lines { self.emit(.stderr, l) }
            }
        }
    }

    private func emit(_ stream: Stream, _ line: String) {
        ioQueue.async { [weak self] in
            self?.onLine?(stream, line)
        }
    }

    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            let r = waitpid(self.pid, &status, WNOHANG)
            guard r == self.pid else { return }
            self.exitLock.lock()
            if self.exited { self.exitLock.unlock(); return }
            self.exited = true
            self.exitLock.unlock()
            source.cancel()
            // Darwin 不向 Swift 导出 WIFEXITED 等宏，手工按 wait(4) 位布局解析
            let code: Int32
            if status & 0x7F == 0 {
                code = (status >> 8) & 0xFF
            } else {
                code = -(status & 0x7F)
            }
            self.onExit?(code)
        }
        source.resume()
        procSource = source
    }

    var hasExited: Bool {
        exitLock.lock(); defer { exitLock.unlock() }
        return exited
    }

    var isAlive: Bool {
        if hasExited { return false }
        return kill(pid, 0) == 0
    }

    /// 进程组 SIGTERM → 宽限轮询 → SIGKILL（宽限期对齐 dsh 官方 5 秒优雅期）
    func terminate(grace: TimeInterval = 5) async {
        guard !hasExited else { return }
        stopRequested = true
        killpg()
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if hasExited { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !hasExited {
            kill(-pid, SIGKILL)
        }
        // 留出 reap 时间
        for _ in 0..<20 where !hasExited {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func forceKill() {
        stopRequested = true
        killpg()
    }

    private func killpg(sig: Int32 = SIGTERM) {
        kill(-pid, sig)
        kill(pid, sig)
    }
}

/// 行缓冲装配器：按 \n 切行，保留不完整尾部
private struct LineAssembler {
    private var buffer = Data()

    mutating func push(_ data: Data) -> [String]? {
        buffer.append(data)
        guard let idx = buffer.firstIndex(of: 0x0A) else { return nil }
        var lines: [String] = []
        while let i = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer.subdata(in: 0..<i)
            if lineData.last == 0x0D { lineData.removeLast() }
            lines.append(String(data: lineData, encoding: .utf8) ?? "")
            buffer.removeSubrange(0...i)
        }
        return lines
    }

    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let rest = String(data: buffer, encoding: .utf8) ?? ""
        buffer.removeAll()
        return rest.isEmpty ? nil : rest
    }
}
