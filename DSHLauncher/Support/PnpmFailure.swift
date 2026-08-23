import Foundation

/// pnpm 故障分类与消息格式化（逐字移植 fnos profile.go）
struct PnpmFailureInfo: Equatable {
    enum Code: String {
        case hoistPatternDiff = "hoist-pattern-diff"
        case releaseAge = "release-age-violation"
        case fetchTimeout = "fetch-timeout"
        case transientNetwork = "transient-network"
        case ignoredBuilds = "ignored-builds"
        case gitDepPrepare = "git-prepare-not-allowed"
        case fetch404 = "fetch-404"
        case addingToRoot = "adding-to-root"   // 定义保留（fnos 同样未在分类中使用）
        case unexpectedStore = "unexpected-store"
        case unknown = "unknown"
    }
    var code: Code
    var recoverable: Bool
    var message: String
    var detailPkg: String
}

enum PnpmFailure {
    static let re404Pkg = try! NSRegularExpression(pattern: #"(?:GET|fetch)\s+\S*\/([^/\s:]+)(?::|\s)"#)
    static let reTransientNet = try! NSRegularExpression(
        pattern: #"(?i)(?:ERR_PNPM_FETCH_5\d\d|ERR_PNPM_META_FETCH_FAIL|FetchError|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENETUNREACH|socket hang up|network timeout)"#)
    static let reFetchTimeout = try! NSRegularExpression(
        pattern: #"(?i)(?:operation was aborted due to timeout|TimeoutError|error \(23\))"#)

    static func classify(_ output: String) -> PnpmFailureInfo {
        func contains(_ s: String) -> Bool { output.contains(s) }
        func regexHit(_ re: NSRegularExpression) -> Bool {
            re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
        }
        // 匹配顺序严格对齐 fnos
        if contains("ERR_PNPM_PUBLIC_HOIST_PATTERN_DIFF") {
            return PnpmFailureInfo(code: .hoistPatternDiff, recoverable: true,
                                   message: "node_modules 是旧版 pnpm 创建的，存在依赖结构差异，已自动重建后重试", detailPkg: "")
        }
        if contains("ERR_PNPM_UNEXPECTED_STORE") {
            return PnpmFailureInfo(code: .unexpectedStore, recoverable: true,
                                   message: "依赖存储位置变更，已自动清理缓存并重试", detailPkg: "")
        }
        if contains("ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION") || contains("ERR_PNPM_NO_MATURE_MATCHING_VERSION") {
            return PnpmFailureInfo(code: .releaseAge, recoverable: true,
                                   message: "检测到刚发布的新版本受 pnpm 安全期限制，已自动放行并重试", detailPkg: "")
        }
        if regexHit(reFetchTimeout) {
            return PnpmFailureInfo(code: .fetchTimeout, recoverable: true,
                                   message: "下载耗时超出默认限制，已自动延长超时时间并重试", detailPkg: "")
        }
        if contains("ERR_PNPM_IGNORED_BUILDS") {
            return PnpmFailureInfo(code: .ignoredBuilds, recoverable: true,
                                   message: "依赖包含构建脚本，已被 pnpm 默认拦截，已自动配置放行并重试", detailPkg: "")
        }
        if contains("ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED") {
            return PnpmFailureInfo(code: .gitDepPrepare, recoverable: true,
                                   message: "Git 插件包含构建脚本，已自动配置放行并重试", detailPkg: "")
        }
        if contains("ERR_PNPM_FETCH_404") {
            var detailPkg = ""
            if let m = re404Pkg.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let r = Range(m.range(at: 1), in: output) {
                detailPkg = String(output[r])
                    .replacingOccurrences(of: "%2F", with: "/")
                    .replacingOccurrences(of: "%2f", with: "/")
            }
            var msg = "指定的插件包在 npm 镜像源上不存在 (404)"
            if !detailPkg.isEmpty {
                msg = "依赖包「\(detailPkg)」在镜像源上不存在 (404)，可能未发布或存在历史残留"
            }
            return PnpmFailureInfo(code: .fetch404, recoverable: false, message: msg, detailPkg: detailPkg)
        }
        if regexHit(reTransientNet) {
            return PnpmFailureInfo(code: .transientNetwork, recoverable: true,
                                   message: "网络连接瞬态抖动，已自动重试", detailPkg: "")
        }
        return PnpmFailureInfo(code: .unknown, recoverable: false,
                               message: "插件指令执行失败", detailPkg: "")
    }

    static func formatMessage(_ output: String) -> String {
        let info = classify(output)
        if info.code == .fetch404 {
            return info.message
        }
        let lines = output.components(separatedBy: "\n")
        var meaningful: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("ERR_PNPM_") || trimmed.hasPrefix("npm ERR!")
                || trimmed.hasPrefix("error:") || trimmed.contains("Error:") {
                meaningful.append(trimmed)
            }
        }
        if let first = meaningful.first {
            return "\(info.message)（\(first)）"
        }
        // 兜底：从最后一行向前找第一条非空且不以 "at " 开头的行
        for line in lines.reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("at ") {
                var s = t
                let bytes = Array(s.utf8)
                if bytes.count > 120 {
                    s = String(decoding: bytes.prefix(120), as: UTF8.self) + "…"
                }
                return "\(info.message): \(s)"
            }
        }
        return info.message
    }
}
