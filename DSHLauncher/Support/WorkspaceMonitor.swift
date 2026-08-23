import Foundation
import AppKit

struct WorkspaceInfo: Identifiable, Equatable {
    let id: String
    var title: String
    var path: String
    var sessionCount: Int
    var createdAt: Date?
    var updatedAt: Date?
    var rawUpdatedAt: String
}

/// 工作区只读监视（对齐 fnos workspace.go）：每秒检查
/// $DSH_HOME/storages/workspace.json 的 mtime，变更后重新解析并推送。
final class WorkspaceMonitor {
    private(set) var workspaces: [WorkspaceInfo] = []
    var onWorkspaces: (([WorkspaceInfo]) -> Void)?
    private var timer: DispatchSourceTimer?
    private var lastMtime: Double = 0
    private let queue = DispatchQueue(label: "dsh.launcher.workspace", qos: .utility)

    func storageFile(dshHome: String) -> URL {
        Paths.dshHome(dshHome).appendingPathComponent("storages/workspace.json")
    }

    func start(dshHomeProvider: @escaping () -> String) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let file = self.storageFile(dshHome: dshHomeProvider())
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let mtime = attrs[.modificationDate] as? Date else {
                if !self.workspaces.isEmpty {
                    self.workspaces = []
                    self.publish([])
                }
                return
            }
            let stamp = mtime.timeIntervalSince1970
            guard stamp != self.lastMtime else { return }
            self.lastMtime = stamp
            guard let data = try? Data(contentsOf: file) else { return }
            let list = Self.parse(data: data)
            self.workspaces = list
            self.publish(list)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func publish(_ list: [WorkspaceInfo]) {
        let copy = list
        DispatchQueue.main.async { [weak self] in
            self?.onWorkspaces?(copy)
        }
    }

    // MARK: - 解析（DSH workspace 存储 v1/v2，>2 拒绝）

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoFormatterNoFraction = ISO8601DateFormatter()

    static func parse(data: Data) -> [WorkspaceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let unit = root["unit"] as? [String: Any] ?? [:]
        guard (unit["name"] as? String) == "workspace" else { return [] }
        if let version = unit["version"] as? Int, version > 2 { return [] }

        let global = root["global"] as? [String: Any] ?? [:]
        let tables = root["tables"] as? [String: Any] ?? [:]
        let workspaceMap = (tables["workspaces"] as? [String: [String: Any]]) ?? [:]
        let archived = Set((global["archivedSessionIds"] as? [String]) ?? [])

        var result: [WorkspaceInfo] = []
        var seen = Set<String>()
        // 注册表顺序优先
        for id in (global["workspaceIds"] as? [String]) ?? [] {
            guard let record = workspaceMap[id], !seen.contains(id) else { continue }
            result.append(build(id: id, dict: record, archived: archived))
            seen.insert(id)
        }
        // 兜底：注册表未列出但表里存在的，按 updatedAt 字符串倒序
        let leftovers = workspaceMap
            .filter { !seen.contains($0.key) }
            .map { build(id: $0.key, dict: $0.value, archived: archived) }
            .sorted { $0.rawUpdatedAt > $1.rawUpdatedAt }
        return result + leftovers
    }

    private static func build(id: String, dict: [String: Any], archived: Set<String>) -> WorkspaceInfo {
        let title = (dict["title"] as? String) ?? ""
        let path = (dict["path"] as? String) ?? ""
        let sessions = (dict["sessionIds"] as? [String]) ?? []
        let activeCount = sessions.filter { !archived.contains($0) }.count
        let createdRaw = (dict["createdAt"] as? String) ?? ""
        let updatedRaw = (dict["updatedAt"] as? String) ?? ""
        return WorkspaceInfo(
            id: id,
            title: title,
            path: path,
            sessionCount: activeCount,
            createdAt: parseISO(createdRaw),
            updatedAt: parseISO(updatedRaw),
            rawUpdatedAt: updatedRaw)
    }

    static func parseISO(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw) ?? isoFormatterNoFraction.date(from: raw)
    }

    // MARK: - Finder 定位（替代飞牛的 trimSdk.openFileManager）

    static func revealInFinder(_ path: String) {
        let expanded = Paths.expand(path)
        guard !expanded.isEmpty else { return }
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: expanded) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func openInFinder(_ path: String) {
        let expanded = Paths.expand(path)
        guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded, isDirectory: true))
    }
}
