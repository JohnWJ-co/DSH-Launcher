import Foundation

struct LauncherConfig: Codable, Equatable {
    var serverPort: Int = 3080
    var nodePath: String = ""
    var sourcePath: String = Paths.defaultSourcePath
    var dshHome: String = ""
    var networkProxy: String = ""
    var autoRunOnLaunch: Bool = false

    enum CodingKeys: String, CodingKey {
        case serverPort = "server_port"
        case nodePath = "node_path"
        case sourcePath = "source_path"
        case dshHome = "dsh_home"
        case networkProxy = "network_proxy"
        case autoRunOnLaunch = "auto_run"
    }

    /// 源码目录（展开 ~）
    var sourceURL: URL { URL(fileURLWithPath: Paths.expand(sourcePath), isDirectory: true) }
}

struct ConfigStore {
    let url: URL

    func load() -> LauncherConfig {
        guard let data = try? Data(contentsOf: url) else { return LauncherConfig() }
        let decoder = JSONDecoder()
        return (try? decoder.decode(LauncherConfig.self, from: data)) ?? LauncherConfig()
    }

    /// 原子写：先写 .tmp 再 rename（对齐飞牛版）
    func save(_ config: LauncherConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tmp, options: .atomic)
        // 如果目标被其他进程占用，rename 也具备原子性
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// 端口可用性探测（对齐飞牛版 checkPortAvailable：bind 试探）
    /// 必须与真实服务端一样启用 SO_REUSEADDR，否则刚停止的旧进程遗留的
    /// TIME_WAIT 连接会导致误报“端口被占用”，重启场景必现。
    static func isPortAvailable(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
