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

    /// 当前分支名（shallow clone 失败时用 "main" 兜底）
    static func currentBranch(sourceURL: URL) async -> String {
        let r = await ShellRunner.run(path: gitPath,
                                      args: ["-C", sourceURL.path, "rev-parse", "--abbrev-ref", "HEAD"],
                                      timeout: 15)
        let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0, !name.isEmpty, name != "HEAD" { return name }
        return "main"
    }

    static func pull(sourceURL: URL, proxy: String, logs: LogStore?) async -> (ok: Bool, error: String?) {
        let e = env(withProxy: proxy)
        // 1. 先尝试 --ff-only（快照式更新，不产生合并提交）
        var r = await ShellRunner.run(path: gitPath, args: ["-C", sourceURL.path, "pull", "--ff-only"],
                                      env: e, timeout: 180, logs: logs)
        if r.code == 0 { return (true, nil) }

        let out = r.output
        // 2. 分支分叉导致非快进失败 → fetch + reset --hard origin/<branch>（一步到位，不靠用户手动点强制重建）
        if out.contains("Not possible to fast-forward") || out.contains("diverging") || out.contains("diverged") {
            logs?.launcherMessage("检测到分支分叉，正在 fetch 远程并重置本地到最新版本…", level: "WARN")
            let fetchR = await ShellRunner.run(path: gitPath,
                                               args: ["-C", sourceURL.path, "fetch", "--depth=1", "origin"],
                                               env: e, timeout: 15, logs: logs)
            if fetchR.code != 0 {
                if ShellRunner.looksLikeNetworkError(fetchR.output) {
                    return (false, "网络错误：fetch 失败，请检查网络代理设置")
                }
                return (false, "git fetch 失败（exit \(fetchR.code)）：\(fetchR.output.suffix(300))")
            }
            let branch = await currentBranch(sourceURL: sourceURL)
            let resetR = await ShellRunner.run(path: gitPath,
                                               args: ["-C", sourceURL.path, "reset", "--hard", "origin/\(branch)"],
                                               env: e, timeout: 60, logs: logs)
            if resetR.code == 0 { return (true, nil) }
            return (false, "git reset --hard origin/\(branch) 失败（exit \(resetR.code)）：\(resetR.output.suffix(300))")
        }

        // 3. 其他错误直接返回
        if ShellRunner.looksLikeNetworkError(out) {
            return (false, "网络错误：拉取失败，请检查网络代理设置")
        }
        return (false, "git pull 失败（exit \(r.code)）：\(out.suffix(300))")
    }

    /// fetch + reset --hard origin/<branch>（强制重建专用，跳过 pull 逻辑）
    static func fetchAndReset(sourceURL: URL, proxy: String, logs: LogStore?) async -> Bool {
        let e = env(withProxy: proxy)
        logs?.launcherMessage("fetch 最新远程提交…")
        let fetchR = await ShellRunner.run(path: gitPath,
                                           args: ["-C", sourceURL.path, "fetch", "--depth=1", "origin"],
                                           env: e, timeout: 15, logs: logs)
        if fetchR.code != 0 {
            if ShellRunner.looksLikeNetworkError(fetchR.output) {
                logs?.launcherMessage("网络错误：fetch 失败，请检查网络代理设置", level: "ERROR")
            } else {
                logs?.launcherMessage("git fetch 失败（exit \(fetchR.code)）：\(fetchR.output.suffix(200))", level: "ERROR")
            }
            // fetch 失败时降级为 reset --hard HEAD（至少清理本地未提交变更）
            let fallback = await ShellRunner.run(path: gitPath,
                                                 args: ["-C", sourceURL.path, "reset", "--hard", "HEAD"],
                                                 timeout: 60, logs: logs)
            return fallback.code == 0
        }
        let branch = await currentBranch(sourceURL: sourceURL)
        logs?.launcherMessage("重置到 origin/\(branch) …")
        let r = await ShellRunner.run(path: gitPath,
                                      args: ["-C", sourceURL.path, "reset", "--hard", "origin/\(branch)"],
                                      env: e, timeout: 60, logs: logs)
        if r.code != 0 {
            logs?.launcherMessage("git reset --hard origin/\(branch) 失败（exit \(r.code)）", level: "ERROR")
            return false
        }
        return true
    }

    /// 回滚到指定 commit（升级/重建失败时自动回退用）
    static func resetToCommit(sourceURL: URL, commit: String, logs: LogStore?) async -> Bool {
        logs?.launcherMessage("回滚到 commit \(commit) …")
        let r = await ShellRunner.run(path: gitPath,
                                      args: ["-C", sourceURL.path, "reset", "--hard", commit],
                                      timeout: 60, logs: logs)
        if r.code == 0 {
            logs?.launcherMessage("已回滚到 commit \(commit)")
            return true
        }
        logs?.launcherMessage("回滚失败（exit \(r.code)）：\(r.output.suffix(200))", level: "ERROR")
        return false
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
