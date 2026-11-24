import Foundation

/// Changes single values in a TOML file and leaves everything else exactly as it was written:
/// comments, blank lines, key order and spacing. This is what lets the settings window and a text
/// editor share one config file.
public struct TOMLEditor {
    public private(set) var lines: [String]

    public init(_ text: String) {
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    // MARK: Reading the structure

    private enum Kind: Equatable {
        case table([String])
        case arrayTable([String])
        /// `key` is the full dotted path as written on the line.
        case pair(key: [String], valueStart: Int, endLine: Int, valueEnd: Int)

        var isPair: Bool {
            if case .pair = self { return true }
            return false
        }
    }

    private struct Item {
        let line: Int
        let kind: Kind
    }

    private func scan() -> [Item] {
        var items: [Item] = []
        var i = 0
        while i < lines.count {
            let chars = Array(lines[i])
            var c = 0
            while c < chars.count, chars[c] == " " || chars[c] == "\t" { c += 1 }
            guard c < chars.count, chars[c] != "#" else {
                i += 1
                continue
            }
            if chars[c] == "[" {
                let isArray = c + 1 < chars.count && chars[c + 1] == "["
                var p = c + (isArray ? 2 : 1)
                if let path = Self.readKey(chars, &p) {
                    items.append(Item(line: i, kind: isArray ? .arrayTable(path) : .table(path)))
                }
                i += 1
                continue
            }
            var p = c
            if let key = Self.readKey(chars, &p) {
                while p < chars.count, chars[p] == " " || chars[p] == "\t" { p += 1 }
                if p < chars.count, chars[p] == "=" {
                    p += 1
                    while p < chars.count, chars[p] == " " || chars[p] == "\t" { p += 1 }
                    let (endLine, valueEnd) = valueEnd(fromLine: i, column: p)
                    items.append(Item(line: i, kind: .pair(key: key, valueStart: p, endLine: endLine, valueEnd: valueEnd)))
                    i = endLine + 1
                    continue
                }
            }
            i += 1
        }
        return items
    }

    /// Read a possibly dotted, possibly quoted key starting at `p`.
    private static func readKey(_ chars: [Character], _ p: inout Int) -> [String]? {
        var parts: [String] = []
        while true {
            while p < chars.count, chars[p] == " " || chars[p] == "\t" { p += 1 }
            guard p < chars.count else { return nil }
            var part = ""
            if chars[p] == "\"" || chars[p] == "'" {
                let quote = chars[p]
                p += 1
                while p < chars.count, chars[p] != quote {
                    if chars[p] == "\\", quote == "\"", p + 1 < chars.count { p += 1 }
                    part.append(chars[p])
                    p += 1
                }
                guard p < chars.count else { return nil }
                p += 1
            } else {
                while p < chars.count, chars[p].isLetter || chars[p].isNumber || chars[p] == "_" || chars[p] == "-" {
                    part.append(chars[p])
                    p += 1
                }
                guard !part.isEmpty else { return nil }
            }
            parts.append(part)
            var q = p
            while q < chars.count, chars[q] == " " || chars[q] == "\t" { q += 1 }
            if q < chars.count, chars[q] == "." {
                p = q + 1
            } else {
                return parts
            }
        }
    }

    /// Where the value that starts at (line, column) ends: the line and the column just past its
    /// last character. Follows arrays and inline tables across lines and ignores `#` inside strings.
    private func valueEnd(fromLine start: Int, column: Int) -> (Int, Int) {
        var depth = 0
        var line = start
        var col = column
        var last = (start, column)
        while line < lines.count {
            let chars = Array(lines[line])
            var quote: Character?
            while col < chars.count {
                let ch = chars[col]
                if let q = quote {
                    if ch == "\\", q == "\"" {
                        col += 1
                    } else if ch == q {
                        quote = nil
                    }
                    last = (line, min(col + 1, chars.count))
                } else if ch == "#" {
                    break
                } else {
                    if ch == "\"" || ch == "'" { quote = ch }
                    if ch == "[" || ch == "{" { depth += 1 }
                    if ch == "]" || ch == "}" { depth -= 1 }
                    if ch != " ", ch != "\t" { last = (line, col + 1) }
                }
                col += 1
            }
            if depth <= 0 { break }
            line += 1
            col = 0
        }
        return last
    }

    // MARK: Writing

    public static func format(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s):
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(format: "%.1f", d) }
            var s = String(format: "%.4f", d)
            while s.hasSuffix("0") { s.removeLast() }
            return s
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return "[" + a.map(format).joined(separator: ", ") + "]"
        case .table(let t):
            return "{ " + t.keys.sorted().map { "\(formatKey($0)) = \(format(t[$0]!))" }.joined(separator: ", ") + " }"
        }
    }

    public static func formatKey(_ key: String) -> String {
        let bare = !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return bare ? key : format(.string(key))
    }

    /// The table each item belongs to, nil inside an array of tables.
    private func owners(_ items: [Item]) -> [[String]?] {
        var current: [String]? = []
        return items.map { item in
            switch item.kind {
            case .table(let path): current = path
            case .arrayTable: current = nil
            case .pair: break
            }
            return current
        }
    }

    private func find(_ path: [String], in items: [Item]) -> Item? {
        let owner = owners(items)
        for (i, item) in items.enumerated() {
            if case .pair(let key, _, _, _) = item.kind, let table = owner[i], table + key == path { return item }
        }
        return nil
    }

    /// Set `path` (table names followed by the key) to a value. An existing line keeps its place
    /// and its trailing comment; a new key goes to the end of its table; a missing table is added
    /// at the end of the file.
    public mutating func set(_ path: [String], to value: TOMLValue) {
        guard let key = path.last else { return }
        // The same setting written as a section of its own ([gaps.outer] with top, left, ...)
        // would stay in the file beside the new line, and the file would then define it twice.
        if removeTable(path) { return set(path, to: value) }
        let items = scan()
        let formatted = Self.format(value)

        if let item = find(path, in: items), case .pair(_, let valueStart, let endLine, let valueEnd) = item.kind {
            let head = String(Array(lines[item.line]).prefix(valueStart))
            let tail = String(Array(lines[endLine]).dropFirst(valueEnd))
            lines.replaceSubrange(item.line...endLine, with: [head + formatted + tail])
            return
        }

        let tablePath = Array(path.dropLast())
        let newLine = "\(Self.formatKey(key)) = \(formatted)"
        let owner = owners(items)

        func endLine(of item: Item) -> Int {
            if case .pair(_, _, let end, _) = item.kind { return end }
            return item.line
        }

        if tablePath.isEmpty {
            // Root keys live above the first table.
            let rootPairs = items.enumerated().filter { owner[$0.offset] == [] && $0.element.kind.isPair }.map(\.element)
            if let last = rootPairs.last {
                lines.insert(newLine, at: endLine(of: last) + 1)
            } else if let firstHeader = items.first(where: { !$0.kind.isPair }) {
                lines.insert(contentsOf: [newLine, ""], at: firstHeader.line)
            } else {
                appendBlock([newLine])
            }
            return
        }

        if let headerIndex = items.lastIndex(where: { $0.kind == .table(tablePath) }) {
            // The last line that belongs to this table: its header or its last key.
            var last = items[headerIndex]
            for item in items[(headerIndex + 1)...] {
                guard item.kind.isPair else { break }
                last = item
            }
            lines.insert(newLine, at: endLine(of: last) + 1)
            return
        }

        appendBlock(["[\(tablePath.map(Self.formatKey).joined(separator: "."))]", newLine])
    }

    /// Delete a whole `[table]` section: its header, its keys and the comments between them.
    /// Returns false when there is no such section.
    @discardableResult
    private mutating func removeTable(_ path: [String]) -> Bool {
        let items = scan()
        guard let headerIndex = items.firstIndex(where: { $0.kind == .table(path) }) else { return false }
        var last = items[headerIndex].line
        for item in items[(headerIndex + 1)...] {
            guard case .pair(_, _, let end, _) = item.kind else { break }
            last = end
        }
        let first = items[headerIndex].line
        lines.removeSubrange(first...last)
        // Leave one blank line where the section was, not two.
        if first < lines.count, lines[first].trimmingCharacters(in: .whitespaces).isEmpty,
           first == 0 || lines[first - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: first)
        }
        return true
    }

    /// Delete a key. Returns false when it was not in the file.
    @discardableResult
    public mutating func remove(_ path: [String]) -> Bool {
        guard let item = find(path, in: scan()), case .pair(_, _, let endLine, _) = item.kind else { return false }
        lines.removeSubrange(item.line...endLine)
        return true
    }

    /// Replace every `[[name]]` section with the given entries (each a list of key/value pairs in
    /// the order they should be written). The new sections go where the first old one was.
    public mutating func replaceArrayOfTables(_ name: String, with entries: [[(String, TOMLValue)]]) {
        let items = scan()
        var removals: [ClosedRange<Int>] = []
        for (i, item) in items.enumerated() where item.kind == .arrayTable([name]) {
            // The section runs up to the next header; trailing blank and comment lines stay.
            var end = item.line
            for next in items[(i + 1)...] {
                guard case .pair(_, _, let pairEnd, _) = next.kind else { break }
                end = pairEnd
            }
            removals.append(item.line...end)
        }
        var insertAt = removals.first?.lowerBound
        for range in removals.reversed() {
            lines.removeSubrange(range)
            // Drop one blank line that separated this section from the next, to avoid gaps piling up.
            if range.lowerBound < lines.count, lines[range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty,
               range.lowerBound > 0 {
                lines.remove(at: range.lowerBound)
            }
        }
        var block: [String] = []
        for entry in entries {
            block.append("[[\(Self.formatKey(name))]]")
            for (key, value) in entry { block.append("\(Self.formatKey(key)) = \(Self.format(value))") }
            block.append("")
        }
        guard !block.isEmpty else { return }
        if let at = insertAt, at <= lines.count {
            insertAt = at
            lines.insert(contentsOf: block, at: at)
        } else {
            block.removeLast()
            appendBlock(block)
        }
    }

    private mutating func appendBlock(_ block: [String]) {
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(contentsOf: block)
        lines.append("")
    }
}
