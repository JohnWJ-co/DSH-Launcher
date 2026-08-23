import Foundation

enum Format {
    /// 运行时长（对齐 fnos formatDuration：X小时X分X秒 / X分X秒 / X秒）
    static func duration(_ interval: TimeInterval) -> String {
        let s = Int(interval.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)小时\(m)分\(sec)秒" }
        if m > 0 { return "\(m)分\(sec)秒" }
        return "\(sec)秒"
    }

    /// 相对时间（工作区卡片“更新于 …”）
    static func relative(_ date: Date?) -> String {
        guard let date else { return "-" }
        let ti = Date().timeIntervalSince(date)
        if ti < 60 { return "刚刚" }
        if ti < 3600 { return "\(Int(ti / 60))分钟前" }
        if ti < 86400 { return "\(Int(ti / 3600))小时前" }
        if ti < 86400 * 30 { return "\(Int(ti / 86400))天前" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// 创建日期 yyyy-MM-dd
    static func shortDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    static func localDateTime(_ date: Date?) -> String {
        guard let date else { return "-" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}
