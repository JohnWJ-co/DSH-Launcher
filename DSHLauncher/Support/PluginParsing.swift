import Foundation

enum PluginVerb: String, CaseIterable {
    case add, remove, update, list, why, install
}

struct PluginCommand: Equatable {
    var profile: String
    var verb: PluginVerb
    var specs: [String]

    var display: String {
        var parts = ["dsh", "plugin", "--profile", profile, verb.rawValue]
        parts += specs
        return parts.joined(separator: " ")
    }
}

struct PluginPreview {
    var valid: Bool
    var reason: String?
    var command: String?
    var verb: PluginVerb?
    var specs: [String]?
}

/// 插件命令解析（逐字移植 fnos plugins.go 的 splitCommandLine / parsePluginCommand / validatePluginSpec）
enum PluginParsing {
    static let verbAliases: [String: PluginVerb] = [
        "add": .add,
        "install": .install, "i": .install,
        "remove": .remove, "rm": .remove, "uninstall": .remove, "un": .remove,
        "update": .update, "up": .update, "upgrade": .update,
        "list": .list, "ls": .list,
        "why": .why,
    ]
    static let needSpecs: Set<PluginVerb> = [.add, .remove, .update, .why]

    // 校验正则（原文移植；ICU 下 \/ 与 / 等价）
    static let npmSpecRe = try! NSRegularExpression(pattern: #"^(@[a-z0-9-~][\w.-]*\/)?[a-z0-9-~][\w.-]*(@[0-9A-Za-z.*+~^<>=,\- ]+)?$"#)
    static let gitURLRe = try! NSRegularExpression(pattern: #"^(git\+)?(https?:\/\/|ssh:\/\/)[^\s;|`$()]+$"#)
    static let gitShorthandRe = try! NSRegularExpression(pattern: #"^github:[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+(?:#[^\s;|`$()]+)?$"#)
    static let localSpecRe = try! NSRegularExpression(pattern: #"^(file:|\/).+$"#)
    static let profileNameRe = try! NSRegularExpression(pattern: #"^[a-zA-Z0-9_-]+$"#)
    static let specForbiddenRe = try! NSRegularExpression(pattern: #"[;|`$()\r\n]"#)
    static let npmNameStripRe = try! NSRegularExpression(pattern: #"^((?:@[a-z0-9-~][\w.-]*/)?[a-z0-9-~][\w.-]*)@.+$"#)

    // MARK: - 分词器（逐字节，对齐 Go 实现）

    static func splitCommandLine(_ input: String) -> (tokens: [String]?, error: String?) {
        var tokens: [String] = []
        var current: [UInt8] = []
        var inQuote = false
        var quoteChar: UInt8 = 0
        var escaped = false

        for byte in Array(input.utf8) {
            if escaped {
                current.append(byte)
                escaped = false
                continue
            }
            if byte == UInt8(ascii: "\\") {
                escaped = true
                continue
            }
            if inQuote {
                if byte == quoteChar {
                    inQuote = false
                    quoteChar = 0
                } else {
                    current.append(byte)
                }
                continue
            }
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                inQuote = true
                quoteChar = byte
                continue
            }
            if byte == UInt8(ascii: " ") || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                if !current.isEmpty {
                    tokens.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(byte)
        }
        if inQuote {
            return (nil, "引号未闭合")
        }
        if !current.isEmpty {
            tokens.append(String(decoding: current, as: UTF8.self))
        }
        return (tokens, nil)
    }

    // MARK: - spec 校验

    static func validateSpec(_ spec: String) -> String? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "包名为空" }
        if specForbiddenRe.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)) != nil {
            return "包含不允许的字符"
        }
        let range = NSRange(spec.startIndex..., in: spec)
        let ok = npmSpecRe.firstMatch(in: spec, range: range) != nil
            || gitURLRe.firstMatch(in: spec, range: range) != nil
            || gitShorthandRe.firstMatch(in: spec, range: range) != nil
            || localSpecRe.firstMatch(in: spec, range: range) != nil
        if ok { return nil }
        if trimmed.hasPrefix(".") {
            return "不支持相对路径，请输入标准 npm 包名或 Git 仓库地址"
        }
        return "无法识别的包名/地址格式"
    }

    // MARK: - 命令解析

    static func parse(_ input: String) -> (command: PluginCommand?, reason: String?) {
        let trimmedInput = input.trimmingCharacters(in: .whitespaces)
        if trimmedInput.isEmpty {
            return (nil, "请输入插件命令")
        }
        let (fieldsOpt, splitError) = splitCommandLine(trimmedInput)
        if let splitError { return (nil, splitError) }
        guard let fields = fieldsOpt else { return (nil, "引号未闭合") }

        guard fields.count >= 2, fields[0] == "dsh", fields[1] == "plugin" else {
            return (nil, "请输入标准 dsh 命令，例如: dsh plugin --profile web add 包名")
        }

        var profile = "web"
        var rest: [String] = []
        var i = 2
        while i < fields.count {
            let f = fields[i]
            if f == "--profile" {
                guard i + 1 < fields.count else { return (nil, "--profile 缺少参数") }
                i += 1
                let name = fields[i]
                guard profileNameRe.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else {
                    return (nil, "非法的 profile 名称: \(name)")
                }
                profile = name
            } else if f.hasPrefix("--") {
                return (nil, "不支持的参数: \(f)")
            } else {
                rest.append(f)
            }
            i += 1
        }

        guard let verbRaw = rest.first else {
            return (nil, "缺少操作动词（支持 add / remove / update / list / why / install）")
        }
        guard let verb = verbAliases[verbRaw] else {
            return (nil, "未知操作 \"\(verbRaw)\"（支持 add / remove / update / list / why / install）")
        }
        let specs = Array(rest.dropFirst())
        if needSpecs.contains(verb) && specs.isEmpty {
            return (nil, "\(verb.rawValue) 操作需要一个或多个包名")
        }
        if verb == .install && !specs.isEmpty {
            return (nil, "install 操作不接受包名参数")
        }
        for spec in specs {
            if let err = validateSpec(spec) {
                return (nil, "参数 \"\(spec)\": \(err)")
            }
        }
        return (PluginCommand(profile: profile, verb: verb,
                              specs: verb == .list || verb == .install ? [] : specs), nil)
    }

    static func preview(_ input: String, allowOnlyAdd: Bool = true) -> PluginPreview {
        let (cmd, reason) = parse(input)
        guard let cmd else {
            return PluginPreview(valid: false, reason: reason, command: nil, verb: nil, specs: nil)
        }
        if allowOnlyAdd && cmd.verb != .add {
            return PluginPreview(valid: false, reason: "仅支持添加插件指令 (add)", command: nil, verb: nil, specs: nil)
        }
        return PluginPreview(valid: true, reason: nil, command: cmd.display, verb: cmd.verb, specs: cmd.specs)
    }

    // MARK: - 包名归一化

    /// `pkg@1.2.3` → `pkg`；`@scope/pkg@2.0.0` → `@scope/pkg`
    static func normalizePluginKey(_ spec: String) -> String {
        if let m = npmNameStripRe.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)),
           let r = Range(m.range(at: 1), in: spec) {
            return String(spec[r])
        }
        return spec
    }

    static func goQuoted(_ s: String) -> String { "\"\(s)\"" }
}
