import Foundation

/// 语义化版本比较（对齐飞牛版 CompareSemver：含 pre-release 逐段比较）
struct SemVer: Equatable, Comparable {
    var major: Int
    var minor: Int
    var patch: Int
    var preRelease: [String]

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // 截断 npm 范围符号，仅用于单版本解析
        for prefix in ["^", "~", ">=", "<=", ">", "<", "="] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        let parts = s.split(separator: "+").first.map(String.init) ?? s
        let mainAndPre = parts.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = mainAndPre[0].split(separator: ".").map(String.init)
        guard numbers.count >= 1,
              let major = Int(numbers[0]),
              numbers.count >= 2, let minor = Int(numbers[1]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = numbers.count >= 3 ? (Int(numbers[2]) ?? 0) : 0
        self.preRelease = mainAndPre.count > 1
            ? mainAndPre[1].split(separator: ".").map(String.init)
            : []
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // pre-release 优先级低于正式版
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, false): return false
        case (false, true): return true
        case (false, false):
            for (a, b) in zip(lhs.preRelease, rhs.preRelease) {
                if a == b { continue }
                let aNum = Int(a), bNum = Int(b)
                if let aNum, let bNum { return aNum < bNum }
                if aNum != nil { return true }   // 数字段 < 字母段
                if bNum != nil { return false }
                return a < b
            }
            return lhs.preRelease.count < rhs.preRelease.count
        case (true, true): return false
        }
    }

    /// dsh 的 engines 要求：^22.19.0 || >=24.0.0
    static func satisfiesNode(_ v: SemVer) -> Bool {
        if v.major == 22 {
            if v.minor > 19 { return true }
            if v.minor == 19 && v.patch >= 0 { return v.preRelease.isEmpty }
        }
        if v.major >= 24 { return true }
        return false
    }
}
