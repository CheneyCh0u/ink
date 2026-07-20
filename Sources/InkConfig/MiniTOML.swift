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

    /// 只更新指定键，保留原始排版、注释与未知内容。
    ///
    /// `values` 的顺序同时决定新文件及缺失键的稳定输出顺序。
    static func updating(
        _ text: String,
        values: [(key: String, value: String)]
    ) -> String {
        let replacements = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) })
        var present = Set<String>()
        var existingSections = Set<String>()
        var section = ""

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if let parsedSection = sectionName(in: line) {
                section = parsedSection
                existingSections.insert(section)
                continue
            }
            guard let key = assignmentKey(in: line) else { continue }
            present.insert(section.isEmpty ? key : "\(section).\(key)")
        }

        let missing = values.filter { !present.contains($0.key) }
        var missingBySection: [String: [(key: String, value: String)]] = [:]
        for entry in missing {
            let split = splitPath(entry.key)
            missingBySection[split.section, default: []].append((split.key, entry.value))
        }

        var output: [String] = []
        section = ""

        func appendMissing(for section: String) {
            guard let entries = missingBySection.removeValue(forKey: section) else { return }
            if !output.isEmpty, output.last?.isEmpty == false {
                output.append("")
            }
            output.append(contentsOf: entries.map { "\($0.key) = \($0.value)" })
        }

        for line in lines {
            if let nextSection = sectionName(in: line) {
                appendMissing(for: section)
                section = nextSection
                output.append(line)
                continue
            }

            guard let key = assignmentKey(in: line) else {
                output.append(line)
                continue
            }
            let path = section.isEmpty ? key : "\(section).\(key)"
            guard let value = replacements[path] else {
                output.append(line)
                continue
            }
            output.append(replacingValue(in: line, with: value))
        }
        appendMissing(for: section)

        let orderedSections = values.map { splitPath($0.key).section }
        for missingSection in orderedSections where !missingSection.isEmpty {
            guard !existingSections.contains(missingSection),
                  let entries = missingBySection.removeValue(forKey: missingSection)
            else { continue }
            if !output.isEmpty, output.last?.isEmpty == false {
                output.append("")
            }
            output.append("[\(missingSection)]")
            output.append(contentsOf: entries.map { "\($0.key) = \($0.value)" })
        }

        if text.isEmpty, output.first?.isEmpty == true {
            output.removeFirst()
        }
        return output.joined(separator: "\n")
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
        guard let index = commentIndex(in: line) else { return line }
        return String(line[..<index])
    }

    private static func commentIndex(in line: String) -> String.Index? {
        var inString = false
        var previous: Character = " "
        for index in line.indices {
            let ch = line[index]
            if ch == "\"", previous != "\\" {
                inString.toggle()
            } else if ch == "#", !inString {
                return index
            }
            previous = ch
        }
        return nil
    }

    private static func sectionName(in line: String) -> String? {
        let content = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard content.hasPrefix("["), content.hasSuffix("]") else { return nil }
        return String(content.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func assignmentKey(in line: String) -> String? {
        let content = stripComment(line)
        guard let equals = content.firstIndex(of: "=") else { return nil }
        let key = content[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func splitPath(_ path: String) -> (section: String, key: String) {
        guard let dot = path.lastIndex(of: ".") else { return ("", path) }
        return (String(path[..<dot]), String(path[path.index(after: dot)...]))
    }

    private static func replacingValue(in line: String, with value: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return line }
        let valueStart = line.index(after: equals)
        let remainder = line[valueStart...]
        let leadingWhitespace = remainder.prefix { $0 == " " || $0 == "\t" }
        let local = String(remainder)
        let comment = commentIndex(in: local).map { index -> String in
            let beforeComment = local[..<index]
            let spacing = beforeComment.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
            return "\(String(spacing))\(local[index...])"
        } ?? ""
        return "\(line[...equals])\(leadingWhitespace)\(value)\(comment)"
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
