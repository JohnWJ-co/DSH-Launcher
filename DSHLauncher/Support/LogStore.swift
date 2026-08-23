import Foundation

/// ANSI 转义码剥离（对齐飞牛版 LineLogWriter 的清理行为）
enum ANSIStripper {
    private static let pattern: String = """
    (?:\\u{1B}\\[[0-9;?]*[ -/]*[@-~])|(?:\\u{1B}\\][^\\u{07}\\u{1B}]*(?:\\u{07}|\\u{1B}\\\\))|(?:\\u{1B}[@-Z\\\\-_])
    """

    private static let regex = try? NSRegularExpression(pattern: pattern)

    static func strip(_ line: String) -> String {
        guard let regex else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
    }
}

/// 运行日志：3MB 轮转、保留 3 份、内存环形缓冲、订阅广播。
/// 对齐飞牛版 logger.go 规格。
final class LogStore {
    static let rotateBytes = 3 * 1024 * 1024
    static let keepRotated = 3
    static let memoryLines = 4000

    let fileURL: URL
    private let queue = DispatchQueue(label: "dsh.launcher.logstore", qos: .utility)
    private var fileHandle: FileHandle?
    private var lines: [String] = []
    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]
    private let lock = NSLock()

    init(fileURL: URL = Paths.logFile) {
        self.fileURL = fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    // MARK: - 写入

    func append(_ rawLine: String) {
        let line = ANSIStripper.strip(rawLine)
        guard !line.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.writeLine(line)
            self.pushRing(line)
            self.broadcast(line)
        }
    }

    func launcherMessage(_ text: String, level: String = "INFO") {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        append("\(fmt.string(from: Date())) [\(level)] \(text)")
    }

    private func writeLine(_ line: String) {
        rotateIfNeeded(adding: line.utf8.count + 1)
        if fileHandle == nil {
            fileHandle = FileHandle(forWritingAtPath: fileURL.path)
        }
        var data = Data(line.utf8)
        data.append(0x0A)
        fileHandle?.write(data)
    }

    private func rotateIfNeeded(adding bytes: Int) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size + bytes > Self.rotateBytes else { return }
        fileHandle?.closeFile()
        fileHandle = nil
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let rotated = fileURL.deletingLastPathComponent()
            .appendingPathComponent("harness-\(fmt.string(from: Date())).log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        pruneRotated()
    }

    private func pruneRotated() {
        let dir = fileURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rotated = names.filter { $0.hasPrefix("harness-") && $0.hasSuffix(".log") }.sorted()
        guard rotated.count > Self.keepRotated else { return }
        for name in rotated.prefix(rotated.count - Self.keepRotated) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - 内存缓冲与订阅

    private func pushRing(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > Self.memoryLines { lines.removeFirst(lines.count - Self.memoryLines) }
        lock.unlock()
    }

    private func broadcast(_ line: String) {
        lock.lock()
        let conts = Array(subscribers.values)
        lock.unlock()
        for c in conts { c.yield(line) }
    }

    func snapshot(limit: Int = 150) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(limit))
    }

    func subscribe() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[id] = nil
                self.lock.unlock()
            }
        }
    }

    // MARK: - 文件操作

    /// 从文件读取尾部 N 行（对齐飞牛版 readLastNLines：≤512KB 全量；否则从尾部取 256KB 丢弃截断半行）
    func lastLinesFromDisk(limit: Int) -> [String] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }

        var data: Data
        if size <= 512 * 1024 {
            data = (try? handle.readToEnd()) ?? Data()
        } else {
            try? handle.seek(toOffset: UInt64(size - 256 * 1024))
            data = (try? handle.readToEnd()) ?? Data()
            // 丢弃截断的半行
            if let idx = data.firstIndex(of: 0x0A) { data = data.advanced(by: idx + 1) }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(all.suffix(limit))
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.fileHandle?.closeFile()
            self.fileHandle = nil
            FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
            self.lock.lock()
            self.lines.removeAll()
            self.lock.unlock()
        }
    }
}
