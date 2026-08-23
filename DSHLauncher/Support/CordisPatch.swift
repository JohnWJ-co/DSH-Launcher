import Foundation
import Yams

/// cordis.patch.yml 存取与插件启停（逐字移植 fnos profile.go：
/// ReadProfileUserPatch / WriteProfileUserPatch / SetPluginDisabled / RemovePluginFromProfileUserPatch /
/// ReadDisabledEntryMap / ExtractPluginEntryIDs / IsProtectedPlugin）
enum CordisPatch {
    /// 受保护插件前缀（原文移植，共 19 条）
    static let protectedPrefixes = [
        "cordis:",
        "@deepseek-ai/cordis-plugin-",
        "@deepseek-ai/dsh-host-",
        "@deepseek-ai/dsh-client-",
        "@deepseek-ai/dsh-web",
        "@deepseek-ai/dsh-settings",
        "@deepseek-ai/dsh-credentials",
        "@deepseek-ai/dsh-session",
        "@deepseek-ai/dsh-storage",
        "@deepseek-ai/dsh-tools",
        "@deepseek-ai/dsh-system-prompt",
        "@deepseek-ai/dsh-agent",
        "@deepseek-ai/dsh-llm",
        "@deepseek-ai/dsh-shell",
        "@deepseek-ai/dsh-fs",
        "@deepseek-ai/dsh-sandbox",
        "@deepseek-ai/dsh-jobs",
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
    ]

    static func isProtectedPlugin(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return protectedPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - 文件读写（fnos 为 yaml.Marshal 全量写回，不保留注释）

    static func read(path: String) throws -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let obj = try Yams.load(yaml: text) else { return [] }
        if let arr = obj as? [[String: Any]] { return arr }
        if obj is NSNull { return [] }
        throw NSError(domain: "cordis-patch", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "解析 \(URL(fileURLWithPath: path).lastPathComponent) 失败"])
    }

    static func write(path: String, rows: [[String: Any]]) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = rows.isEmpty ? "[]\n" : try Yams.dump(object: rows)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func readDisabledEntryMap(_ rows: [[String: Any]]) -> Set<String> {
        var result = Set<String>()
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty,
                  (row["disabled"] as? Bool) == true else { continue }
            result.insert(id)
        }
        return result
    }

    // MARK: - Entry IDs 提取（插件包 dsh.bundle.patch 声明）

    static func extractPluginEntryIDs(profileDir: String, packageName: String) -> [String] {
        let pkgJSON = (profileDir as NSString).appendingPathComponent("node_modules/\(packageName)/package.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkgJSON)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = obj["dsh"] as? [String: Any],
              let bundle = dsh["bundle"] as? [String: Any],
              let patchRel = bundle["patch"] as? String, !patchRel.isEmpty else {
            return [packageName]
        }
        let patchPath = ((pkgJSON as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(patchRel.replacingOccurrences(of: "/", with: "/"))
        guard let patchText = try? String(contentsOfFile: patchPath, encoding: .utf8),
              let loaded = try? Yams.load(yaml: patchText),
              let rows = loaded as? [[String: Any]] else {
            return [packageName]
        }
        var candidates: [String] = []
        for row in rows {
            if let inserts = row["insert"] as? [[String: Any]] {
                for ins in inserts {
                    if let id = ins["id"] as? String, !id.isEmpty { candidates.append(id) }
                }
            } else if let id = row["id"] as? String, !id.isEmpty {
                candidates.append(id)
            }
        }
        return candidates.isEmpty ? [packageName] : candidates
    }

    // MARK: - 启停（热启停核心）

    /// 返回 (错误信息, entryIDs)；成功时错误为 nil
    static func setPluginDisabled(patchPath: String, profileDir: String,
                                  packageName: String, disabled: Bool) -> (error: String?, entryIDs: [String]) {
        if isProtectedPlugin(packageName) {
            return ("核心基础设施插件「\(packageName)」受到保护，禁止更改启停状态", [])
        }
        var entryIDs = extractPluginEntryIDs(profileDir: profileDir, packageName: packageName)
        if entryIDs.isEmpty { entryIDs = [packageName] }
        var rows: [[String: Any]]
        do {
            rows = try read(path: patchPath)
        } catch {
            return (error.localizedDescription, entryIDs)
        }
        for targetID in entryIDs {
            var matched = false
            for (i, row) in rows.enumerated() {
                guard let rowID = row["id"] as? String, rowID == targetID else { continue }
                matched = true
                if disabled {
                    rows[i]["disabled"] = true
                } else {
                    let configEmpty = (row["config"] as? [String: Any])?.isEmpty ?? true
                    let nameEmpty = (row["name"] as? String).map { $0.isEmpty } ?? true
                    let insertEmpty = (row["insert"] as? [[String: Any]])?.isEmpty ?? true
                    if configEmpty && nameEmpty && insertEmpty {
                        rows.remove(at: i)
                    } else {
                        rows[i]["disabled"] = nil
                    }
                }
                break
            }
            if !matched && disabled {
                rows.append(["id": targetID, "disabled": true])
            }
        }
        do {
            try write(path: patchPath, rows: rows)
        } catch {
            return (error.localizedDescription, entryIDs)
        }
        return (nil, entryIDs)
    }

    // MARK: - 卸载后清理 patch 条目

    static func removePluginEntries(patchPath: String, packageName: String, entryIDs: [String]) throws {
        guard FileManager.default.fileExists(atPath: patchPath) else { return }
        var idSet = Set(entryIDs.filter { !$0.isEmpty })
        idSet.insert(packageName)
        let rows = try read(path: patchPath)
        let kept = rows.filter { row in
            let id = (row["id"] as? String) ?? ""
            let name = (row["name"] as? String) ?? ""
            return !idSet.contains(id) && !idSet.contains(name)
        }
        try write(path: patchPath, rows: kept)
    }
}
