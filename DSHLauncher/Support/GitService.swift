import Foundation

/// git 操作封装（/usr/bin/git，全部走 -C 指定仓库）
enum GitService {
    static let gitPath = "/usr/bin/git"
    static let repoURL = "https://github.com/deepseek-ai/deepseek-harness"

    private static func env(withProxy proxy: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let p = proxy.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty {
            env["HTTP_PROXY"] = p; env["HTTPS_PROXY"] = p; env["ALL_PROXY"] = p
            env["http_proxy"] = p; env["https_proxy"] = p; env["all_proxy"] = p
            env["NO_PROXY"] = "localhost,127.0.0.1,::1"
        }
        return env
    }

    /// 当前 HEAD 短 commit
    static func currentCommit(sourceURL: URL) async -> String? {
        let r = await ShellRunner.run(path: gitPath, args: ["-C", sourceURL.path, "rev-parse", "--short", "HEAD"],
                                      timeout: 15)
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !out.isEmpty ? out : nil
    }

    /// fetch --depth=1 并返回 FETCH_HEAD 短 commit（15s 超时，对齐飞牛版）
    static func fetchRemoteCommit(sourceURL: URL, proxy: String) async -> (commit: String?, error: String?) {
        let fetch = await ShellRunner.run(path: gitPath,
                                          args: ["-C", sourceURL.path, "fetch", "--depth=1", "origin"],
                                          env: env(withProxy: proxy), timeout: 15)
        guard fetch.code == 0 else {
            if ShellRunner.looksLikeNetworkError(fetch.output) {
                return (nil, "网络错误：无法访问 GitHub，请在设置中配置网络代理后重试")
            }
            return (nil, "git fetch 失败：\(fetch.output.suffix(300))")
        }
        let r = await ShellRunner.run(path: gitPath, args: ["-C", sourceURL.path, "rev-parse", "--short", "FETCH_HEAD"],
                                      timeout: 15)
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.code == 0 && !out.isEmpty ? out : nil, nil)
    }

    static func pull(sourceURL: URL, proxy: String, logs: LogStore?) async -> (ok: Bool, error: String?) {
        let r = await ShellRunner.run(path: gitPath, args: ["-C", sourceURL.path, "pull", "--ff-only"],
                                      env: env(withProxy: proxy), timeout: 180, logs: logs)
        if r.code == 0 { return (true, nil) }
        if ShellRunner.looksLikeNetworkError(r.output) {
            return (false, "网络错误：拉取失败，请检查网络代理设置")
        }
        return (false, "git pull 失败（exit \(r.code)）：\(r.output.suffix(300))")
    }

    static func resetHard(sourceURL: URL, logs: LogStore?) async -> Bool {
        let r = await ShellRunner.run(path: gitPath, args: ["-C", sourceURL.path, "reset", "--hard"],
                                      timeout: 60, logs: logs)
        return r.code == 0
    }

    static func clone(dst: URL, proxy: String, logs: LogStore?) async -> (ok: Bool, error: String?) {
        let r = await ShellRunner.run(path: gitPath, args: ["clone", "--depth=1", repoURL, dst.path],
                                      env: env(withProxy: proxy), timeout: 1800, logs: logs)
        if r.code == 0 { return (true, nil) }
        if ShellRunner.looksLikeNetworkError(r.output) {
            return (false, "网络错误：克隆失败，请在设置中配置网络代理后重试")
        }
        return (false, "git clone 失败：\(r.output.suffix(300))")
    }

    /// 网络代理写入/清除 git 配置（对齐飞牛版 ApplyProxyEnv 的 git 部分）
    static func applyGitHttpProxy(sourceURL: URL, proxy: String) async {
        let p = proxy.trimmingCharacters(in: .whitespaces)
        if p.isEmpty {
            _ = await ShellRunner.run(path: gitPath,
                                      args: ["-C", sourceURL.path, "config", "--unset", "http.proxy"],
                                      timeout: 15)
        } else {
            _ = await ShellRunner.run(path: gitPath,
                                      args: ["-C", sourceURL.path, "config", "http.proxy", p],
                                      timeout: 15)
        }
    }
}
