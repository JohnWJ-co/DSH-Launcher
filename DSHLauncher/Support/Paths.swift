import Foundation

enum Paths {
    static let appName = "DSHLauncher"

    /// 默认的 harness 源码位置（本机既有的 checkout）
    static let defaultSourcePath = "/Users/qiangwenjun/Documents/project/deepseek-harness"

    /// 候选源码位置（默认路径失效时用于提示/探测）
    static let sourcePathCandidates = [
        defaultSourcePath,
        NSHomeDirectory() + "/Documents/project/deepseek-harness",
        NSHomeDirectory() + "/deepseek-harness",
    ]

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    static var logFile: URL { appSupport.appendingPathComponent("harness.log") }
    static var pidFile: URL { appSupport.appendingPathComponent("harness.pid") }
    static var allowBuildsSidecar: URL { appSupport.appendingPathComponent("allowbuilds.json") }

    /// 配置里的 DSH_HOME（nil 表示默认 ~/.dsh）
    static func dshHome(_ raw: String?) -> URL {
        let expanded = raw.map { NSString(string: $0).expandingTildeInPath } ?? ""
        if expanded.isEmpty { return URL(fileURLWithPath: NSHomeDirectory() + "/.dsh", isDirectory: true) }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    static func expand(_ raw: String) -> String {
        NSString(string: raw).expandingTildeInPath
    }
}
