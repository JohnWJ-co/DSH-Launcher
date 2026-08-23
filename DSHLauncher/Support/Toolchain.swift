import Foundation

/// node / corepack / pnpm 工具链解析。
/// GUI App 从 Finder/Dock 启动时 PATH 不含 Homebrew，必须显式探测绝对路径。
struct Toolchain: Equatable {
    let nodeURL: URL
    let corepackURL: URL?
    /// 用于注入子进程 PATH 的 pnpm 所在目录
    let pnpmBinDir: String?
    let nodeVersion: String

    var nodeDir: String { nodeURL.deletingLastPathComponent().path }

    /// 是否满足 dsh engines（^22.19.0 || >=24.0.0）
    var nodeVersionOK: Bool {
        guard let v = SemVer(nodeVersion) else { return false }
        return SemVer.satisfiesNode(v)
    }

    static func resolve(config: LauncherConfig) -> Toolchain? {
        for candidate in nodeCandidates(config: config) {
            if FileManager.default.isExecutableFile(atPath: candidate),
               let version = probeVersion(nodePath: candidate) {
                let url = URL(fileURLWithPath: candidate)
                let nodeDir = url.deletingLastPathComponent().path
                // corepack：node 同目录或 Homebrew
                var corepack: String? = nil
                for cp in [nodeDir + "/corepack", "/opt/homebrew/bin/corepack", "/usr/local/bin/corepack"] {
                    if FileManager.default.isExecutableFile(atPath: cp) { corepack = cp; break }
                }
                // pnpm：用户已安装的（供 dsh plugin 内部调用）
                var pnpmDir: String? = nil
                for p in ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm", NSHomeDirectory() + "/.volta/bin/pnpm"] {
                    if FileManager.default.isExecutableFile(atPath: p) {
                        pnpmDir = (URL(fileURLWithPath: p).deletingLastPathComponent().path)
                        break
                    }
                }
                if pnpmDir == nil, let corepack, FileManager.default.isExecutableFile(atPath: corepack) {
                    pnpmDir = nodeDir
                }
                return Toolchain(nodeURL: url, corepackURL: corepack.map(URL.init(fileURLWithPath:)),
                                 pnpmBinDir: pnpmDir, nodeVersion: version)
            }
        }
        return nil
    }

    private static func nodeCandidates(config: LauncherConfig) -> [String] {
        var list: [String] = []
        let configured = Paths.expand(config.nodePath)
        if !configured.isEmpty { list.append(configured) }
        list += [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            NSHomeDirectory() + "/.volta/bin/node",
            NSHomeDirectory() + "/.local/share/fnm/node-versions/node.sh",  // fnm 别名（尽力而为）
        ]
        // nvm：取版本号最大的
        let nvmRoot = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = versions.sorted { a, b in
                let va = SemVer(a) ?? SemVer("0.0.0")!
                let vb = SemVer(b) ?? SemVer("0.0.0")!
                return va > vb
            }
            for v in sorted { list.append("\(nvmRoot)/\(v)/bin/node") }
        }
        list.append("/usr/bin/node")
        return list
    }

    private static func probeVersion(nodePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// pnpm 调用方式：优先 corepack（尊重 repo packageManager 钉死版本），否则 npx pnpm@<pin>，最后裸 pnpm
    func pnpmCommand(sourceURL: URL) -> (path: String, args: [String])? {
        if let corepack = corepackURL?.path {
            return (corepack, ["pnpm"])
        }
        if let pinned = pinnedPnpmVersion(sourceURL: sourceURL) {
            let npx = nodeDir + "/npx"
            if FileManager.default.isExecutableFile(atPath: npx) {
                return (npx, ["-y", "pnpm@\(pinned)"])
            }
        }
        if let dir = pnpmBinDir, FileManager.default.isExecutableFile(atPath: dir + "/pnpm") {
            return (dir + "/pnpm", [])
        }
        return nil
    }

    private func pinnedPnpmVersion(sourceURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceURL.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pm = obj["packageManager"] as? String else { return nil }
        // "pnpm@11.7.0" → "11.7.0"
        guard pm.hasPrefix("pnpm@") else { return nil }
        return String(pm.dropFirst("pnpm@".count))
    }
}
