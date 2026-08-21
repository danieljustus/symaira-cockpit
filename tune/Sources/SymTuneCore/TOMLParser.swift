import Foundation

// MARK: - Value type

/// A single TOML value: string, integer, double, boolean, or array.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .integer(let i) = self { return i }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    /// Array of string values. Supports TOML array syntax `["a","b"]` and
    /// comma-separated bare-string fallback `"a,b,c"`.
    public var stringArrayValue: [String]? {
        if case .array(let vals) = self {
            return vals.compactMap(\.stringValue)
        }
        if case .string(let s) = self {
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.isEmpty ? nil : parts
        }
        return nil
    }
}

// MARK: - Parsed document

/// A parsed TOML document. Sections map to key-value dictionaries. Root-level
/// keys (before any `[section]` header) are stored under the empty-string key.
public struct TOMLTable: Equatable, Sendable {
    public var sections: [String: [String: TOMLValue]]

    public init(sections: [String: [String: TOMLValue]] = [:]) {
        self.sections = sections
    }

    /// Look up a value by section and key.
    public subscript(section: String, key: String) -> TOMLValue? {
        sections[section]?[key]
    }
}

// MARK: - Parser

/// Minimal TOML parser supporting `[section]` headers, `key = value` pairs,
/// `#` comments (including inline), quoted strings, integers, doubles, and
/// booleans. No nested tables, arrays, or multiline strings.
public struct TOMLParser: Sendable {
    public init() {}

    public func parse(_ input: String) -> TOMLTable {
        var sections: [String: [String: TOMLValue]] = [:]
        var currentSection = ""

        for rawLine in input.components(separatedBy: .newlines) {
            let stripped = stripComment(rawLine)
            let line = stripped.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // [section] header
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.hasPrefix("[[") {
                let name = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                currentSection = name
                if sections[name] == nil { sections[name] = [:] }
                continue
            }

            // key = value
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty, let value = parseValue(rawValue) else { continue }

            if sections[currentSection] == nil { sections[currentSection] = [:] }
            sections[currentSection]![key] = value
        }

        return TOMLTable(sections: sections)
    }

    // MARK: - Private helpers

    /// Strip inline comments, respecting quoted strings.
    private func stripComment(_ line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for (i, ch) in line.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" && (inSingleQuote || inDoubleQuote) { escaped = true; continue }
            if ch == "'" && !inDoubleQuote { inSingleQuote.toggle(); continue }
            if ch == "\"" && !inSingleQuote { inDoubleQuote.toggle(); continue }
            if ch == "#" && !inSingleQuote && !inDoubleQuote {
                return String(line.prefix(i))
            }
        }
        return line
    }

    /// Parse a single TOML value from its string representation.
    private func parseValue(_ raw: String) -> TOMLValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        // Boolean
        let lowered = trimmed.lowercased()
        if lowered == "true" { return .boolean(true) }
        if lowered == "false" { return .boolean(false) }

        // Quoted string (double or single)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) {
            let inner = String(trimmed.dropFirst().dropLast())
            return .string(inner)
        }

        // Array — inline only: ["a", "b", 42]
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            let elements = splitArrayElements(inner)
            let values = elements.compactMap { parseValue($0) }
            return .array(values)
        }

        // Integer
        if let i = Int(trimmed) { return .integer(i) }

        // Double
        if let d = Double(trimmed) { return .double(d) }

        // Bare (unquoted) string — not standard TOML but useful for defaults
        return .string(trimmed)
    }

    /// Split a comma-separated array body, respecting nested brackets and quotes.
    private func splitArrayElements(_ body: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for ch in body {
            if escaped { escaped = false; current.append(ch); continue }
            if ch == "\\" && (inSingleQuote || inDoubleQuote) { escaped = true; current.append(ch); continue }
            if ch == "'" && !inDoubleQuote { inSingleQuote.toggle(); current.append(ch); continue }
            if ch == "\"" && !inSingleQuote { inDoubleQuote.toggle(); current.append(ch); continue }

            if !inSingleQuote && !inDoubleQuote {
                if ch == "[" { depth += 1; current.append(ch); continue }
                if ch == "]" { depth -= 1; current.append(ch); continue }
                if ch == "," && depth == 0 {
                    elements.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { elements.append(trimmed) }
        return elements
    }
}
