import Foundation

/// 通用子命令执行器：超时强杀进程组、输出可流入日志。
enum ShellRunner {
    struct Result {
        var code: Int32
        var output: String
        var timedOut: Bool
    }

    static func run(path: String,
                    args: [String],
                    cwd: String? = nil,
                    env: [String: String]? = nil,
                    timeout: TimeInterval,
                    logs: LogStore? = nil) async -> Result {
        let spec = ChildProcess.Spec(path: path,
                                     args: args,
                                     env: env ?? ProcessInfo.processInfo.environment,
                                     cwd: cwd)
        guard let proc = ChildProcess(spec: spec) else {
            return Result(code: -1, output: "无法启动进程：\(path)", timedOut: false)
        }
        let lock = NSLock()
        var collected: [String] = []
        proc.onLine = { _, line in
            lock.lock(); collected.append(line); lock.unlock()
            logs?.append(line)
        }
        let exitCode: Int32 = await withCheckedContinuation { cont in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !proc.hasExited {
                    proc.stopRequested = true
                    proc.forceKill()
                }
            }
            proc.onExit = { code in
                timeoutTask.cancel()
                cont.resume(returning: code)
            }
            proc.begin()
        }
        lock.lock()
        let text = collected.joined(separator: "\n")
        lock.unlock()
        let timedOut = exitCode < 0 && proc.stopRequested
        return Result(code: exitCode, output: text, timedOut: timedOut)
    }

    /// 网络类错误识别（对齐飞牛版 formatGitError 的提示语义）
    static func looksLikeNetworkError(_ output: String) -> Bool {
        let markers = ["Could not resolve host", "Connection timed out", "Connection refused",
                       "Network is unreachable", "SSL_ERROR", "GnuTLS", "Failed to connect",
                       "ETIMEDOUT", "ECONNREFUSED", "ENOTFOUND", "unable to access"]
        return markers.contains { output.contains($0) }
    }
}
