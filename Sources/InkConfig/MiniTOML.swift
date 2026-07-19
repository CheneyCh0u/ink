import Foundation

/// 极小 TOML 子集解析器：`[section]`、`key = value`、`#` 注释；
/// 值支持字符串（双引号）、整数、浮点、布尔。
///
/// 终端配置用不到数组表、内联表、多行字符串——为一个配置文件引一个
/// 第三方解析库不符合依赖纪律（CLAUDE.md），这个子集够用且可控。
/// 遇到不认识的行**跳过而不是报错**：配置文件手写，容错优先。
public enum MiniTOML {

    public enum Value: Equatable, Sendable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
    }

    /// 解析为扁平字典，键是 `section.key` 形式（无节的键原样）。
    public static func parse(_ text: String) -> [String: Value] {
        var result: [String: Value] = [:]
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseValue(rawValue) else { continue }

            result[section.isEmpty ? key : "\(section).\(key)"] = value
        }
        return result
    }

    private static func parseValue(_ raw: String) -> Value? {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            let inner = String(raw.dropFirst().dropLast())
            // 只处理常用转义，其余原样。
            let unescaped = inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
            return .string(unescaped)
        }
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        // TOML 允许数字里的下划线分隔（100_000）。
        let numeric = raw.replacingOccurrences(of: "_", with: "")
        if let int = Int(numeric) { return .int(int) }
        if let double = Double(numeric) { return .double(double) }
        return nil
    }

    /// 去掉注释，但不动引号内的 `#`。
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var previous: Character = " "
        for (offset, ch) in line.enumerated() {
            if ch == "\"", previous != "\\" {
                inString.toggle()
            } else if ch == "#", !inString {
                return String(line.prefix(offset))
            }
            previous = ch
        }
        return line
    }
}

extension [String: MiniTOML.Value] {
    public func string(_ key: String) -> String? {
        if case .string(let v)? = self[key] { return v }
        return nil
    }

    public func int(_ key: String) -> Int? {
        if case .int(let v)? = self[key] { return v }
        return nil
    }

    public func double(_ key: String) -> Double? {
        switch self[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let v)? = self[key] { return v }
        return nil
    }
}
