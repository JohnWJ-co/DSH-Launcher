import Foundation

/// allowBuilds 管理（逐字移植 fnos profile.go 的 mergeAllowBuildsEntries / removeAllowBuildsEntries /
/// parseBlockedPackages / sidecar allowbuilds.json）
enum AllowBuilds {
    static let blockedBuildsRe = try! NSRegularExpression(pattern: #"(?i)Ignored build scripts:\s*(.+)"#)
    static let pkgNameRe = try! NSRegularExpression(pattern: #"^(@?[a-zA-Z0-9][\w.-]*(?:/[@a-zA-Z0-9][\w.-]*)?)@[0-9]"#)

    /// 从 pnpm 输出提取被拦截的包名
    static func parseBlockedPackages(_ tail: String) -> [String] {
        guard let m = blockedBuildsRe.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let r = Range(m.range(at: 1), in: tail) else { return [] }
        var pkgs: [String] = []
        for part in tail[r].components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let nameMatch = pkgNameRe.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let nr = Range(nameMatch.range(at: 1), in: trimmed) {
                pkgs.append(String(trimmed[nr]))
            } else {
                pkgs.append(trimmed)
            }
        }
        return pkgs
    }

    /// 块内条目名提取：注释行 / 列表项行不识别
    static func yamlEntryName(_ trimmed: String) -> String {
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("-") { return "" }
        let name = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// 逐行合并（保留注释与顺序；缺失条目插在 allowBuilds: 头行紧后）
    static func mergeEntries(yamlPath: String, pkgs: [String]) throws {
        let fm = FileManager.default
        var content = (try? String(contentsOfFile: yamlPath, encoding: .utf8)) ?? ""
        var lines = content.components(separatedBy: "\n")

        var blockIdx = -1
        var entryLines: [String: Int] = [:]
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if blockIdx < 0 {
                if trimmed == "allowBuilds:" || trimmed.hasPrefix("allowBuilds: ") {
                    blockIdx = i
                }
                continue
            }
            // 块内：空行 / 缩进行继续；遇到新顶级键结束
            if trimmed.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") {
                let name = yamlEntryName(trimmed)
                if !name.isEmpty {
                    entryLines[name] = i
                }
            } else {
                break
            }
        }

        var missing: [String] = []
        var fix: [(index: Int, name: String)] = []
        for p in pkgs {
            if let idx = entryLines[p] {
                let line = lines[idx]
                if let colon = line.firstIndex(of: ":") {
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if value != "true" && value != "false" {
                        fix.append((idx, p))
                    }
                }
            } else {
                missing.append(p)
            }
        }
        if missing.isEmpty && fix.isEmpty { return }
        missing.sort()

        if blockIdx < 0 {
            var newContent = String(content.drop { $0 == "\n" || $0 == "\r" })
            if !newContent.isEmpty && !newContent.hasSuffix("\n") { newContent += "\n" }
            newContent += "\nallowBuilds:\n"
            for p in missing { newContent += "  " + p + ": true\n" }
            content = newContent
        } else {
            for f in fix {
                lines[f.index] = "  " + f.name + ": true"
            }
            var out = Array(lines[0...blockIdx])
            for p in missing { out.append("  " + p + ": true") }
            out += Array(lines[(blockIdx + 1)...])
            content = out.joined(separator: "\n")
        }
        try fm.createDirectory(atPath: (yamlPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try content.write(toFile: yamlPath, atomically: true, encoding: .utf8)
    }

    /// 删除条目（显式 false 的行保留）
    static func removeEntries(yamlPath: String, drop: Set<String>) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: yamlPath) else { return }
        guard let content = try? String(contentsOfFile: yamlPath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            let shouldDrop: Bool
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let name = yamlEntryName(trimmed)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("-")
                    && !name.isEmpty && drop.contains(name) {
                    let value = line.contains(":")
                        ? String(line[line.index(after: line.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces)
                        : ""
                    shouldDrop = value != "false"
                } else {
                    shouldDrop = false
                }
            } else {
                shouldDrop = false
            }
            if !shouldDrop { out.append(line) }
        }
        try out.joined(separator: "\n").write(toFile: yamlPath, atomically: true, encoding: .utf8)
    }

    // MARK: - sidecar allowbuilds.json（{被放行包名: [插件 key 列表]}）

    static func loadSidecar(_ path: String) -> [String: [String]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
        return obj
    }

    static func saveSidecar(_ map: [String: [String]], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// 确保放行：workspace.yaml 合并 + sidecar 记录归属
    static func ensureAllowed(profileWorkspaceYaml: String, sidecarPath: String,
                              pluginKey: String, pkgs: [String]) throws {
        try mergeEntries(yamlPath: profileWorkspaceYaml, pkgs: pkgs)
        var sidecar = loadSidecar(sidecarPath)
        var changed = false
        for pkg in pkgs {
            if !(sidecar[pkg] ?? []).contains(pluginKey) {
                sidecar[pkg, default: []].append(pluginKey)
                changed = true
            }
        }
        if changed { try saveSidecar(sidecar, to: sidecarPath) }
    }

    /// 卸载后清理孤儿（显式 false 行保留）
    static func cleanup(profileWorkspaceYaml: String, sidecarPath: String, pluginKey: String) throws {
        var sidecar = loadSidecar(sidecarPath)
        var orphans: [String] = []
        for (pkg, keys) in sidecar {
            let keep = keys.filter { $0 != pluginKey }
            if keep.isEmpty {
                sidecar[pkg] = nil
                orphans.append(pkg)
            } else if keep.count != keys.count {
                sidecar[pkg] = keep
            }
        }
        if !orphans.isEmpty {
            do {
                try removeEntries(yamlPath: profileWorkspaceYaml, drop: Set(orphans))
            } catch {
                throw NSError(domain: "allowbuilds", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "清理 allowBuilds 失败: \(error.localizedDescription)"])
            }
        }
        try saveSidecar(sidecar, to: sidecarPath)
    }
}
