import Foundation

/// 解析 harness 源码的 dsh CLI 调用入口（对齐飞牛版 dshCliCmd 的三级降级）：
/// ① apps/cli/lib/bin.js 存在 → node bin.js <args>
/// ② package.json scripts.dsh（node/tsx 开头）→ node <script> <args>
/// ③ 兜底 corepack pnpm dsh <args>
enum DshCommand {
    struct Invocation: Equatable {
        var executable: String
        var prefixArgs: [String]
    }

    static func resolve(sourceURL: URL, toolchain: Toolchain) -> Invocation? {
        let bin = sourceURL.appendingPathComponent("apps/cli/lib/bin.js").path
        if FileManager.default.fileExists(atPath: bin) {
            return Invocation(executable: toolchain.nodeURL.path, prefixArgs: [bin])
        }
        if let script = readRootScript(sourceURL: sourceURL) {
            let tokens = script.split(separator: " ").map(String.init)
            if tokens.first == "node" {
                return Invocation(executable: toolchain.nodeURL.path, prefixArgs: Array(tokens.dropFirst()))
            }
            if tokens.first == "tsx" {
                return Invocation(executable: toolchain.nodeURL.path,
                                  prefixArgs: ["--import", "tsx/esm"] + Array(tokens.dropFirst()))
            }
        }
        if let pnpm = toolchain.pnpmCommand(sourceURL: sourceURL) {
            return Invocation(executable: pnpm.path, prefixArgs: pnpm.args + ["dsh"])
        }
        return nil
    }

    private static func readRootScript(sourceURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceURL.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: Any] else { return nil }
        return scripts["dsh"] as? String
    }

    /// 读取 harness 版本（package.json version）
    static func readVersion(sourceURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceURL.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }
}
