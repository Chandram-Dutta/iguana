import Foundation

/// The subset of TOML that a config file needs: tables, arrays of tables, dotted keys, strings,
/// numbers, booleans, arrays and inline tables. No dates and no multi-line strings.
public indirect enum TOMLValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }
    public var tableValue: [String: TOMLValue]? { if case .table(let t) = self { return t }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
}

public struct TOMLError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var parser = Parser(text)
        return try parser.parseDocument()
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0
        var line = 1

        /// Characters that end a bare value. A set, because "\r\n" written in one string literal is a single Character.
        static let wordEnd: Set<Character> = [" ", "\t", "\r", "\n", ",", "]", "}", "#"]

        init(_ text: String) { chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")) }

        var peek: Character? { pos < chars.count ? chars[pos] : nil }

        mutating func advance() {
            if chars[pos] == "\n" { line += 1 }
            pos += 1
        }

        func fail(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" || c == "\r" { advance() }
        }

        mutating func skipComment() {
            if peek == "#" { while let c = peek, c != "\n" { advance() } }
        }

        /// Skip whitespace, comments and newlines (used between statements and inside arrays).
        mutating func skipBlank() {
            while true {
                skipSpaces()
                skipComment()
                if peek == "\n" { advance() } else { break }
            }
        }

        mutating func endOfLine() throws {
            skipSpaces()
            skipComment()
            if let c = peek {
                guard c == "\n" else { throw fail("unexpected '\(c)'") }
                advance()
            }
        }

        mutating func parseDocument() throws -> [String: TOMLValue] {
            var root = TOMLValue.table([:])
            var current: [String] = []
            while true {
                skipBlank()
                guard let c = peek else { break }
                if c == "[" {
                    advance()
                    let isArray = peek == "["
                    if isArray { advance() }
                    skipSpaces()
                    let path = try parseKey()
                    skipSpaces()
                    guard peek == "]" else { throw fail("expected ']'") }
                    advance()
                    if isArray {
                        guard peek == "]" else { throw fail("expected ']]'") }
                        advance()
                        let name = path[path.count - 1]
                        try update(&root, Array(path.dropLast())[...]) { t in
                            var arr: [TOMLValue] = []
                            if let existing = t[name] {
                                guard let a = existing.arrayValue else { throw self.fail("'\(name)' is not an array of tables") }
                                arr = a
                            }
                            arr.append(.table([:]))
                            t[name] = .array(arr)
                        }
                    } else {
                        try update(&root, path[...]) { _ in }
                    }
                    current = path
                    try endOfLine()
                } else {
                    let key = try parseKey()
                    skipSpaces()
                    guard peek == "=" else { throw fail("expected '=' after key") }
                    advance()
                    skipSpaces()
                    let value = try parseValue()
                    let name = key[key.count - 1]
                    try update(&root, (current + key.dropLast())[...]) { $0[name] = value }
                    try endOfLine()
                }
            }
            return root.tableValue ?? [:]
        }

        /// Walk `path` from `value`, creating tables on the way, and run `body` on the table found there.
        /// An array of tables is entered through its last element.
        func update(_ value: inout TOMLValue, _ path: ArraySlice<String>, _ body: (inout [String: TOMLValue]) throws -> Void) throws {
            switch value {
            case .table(var t):
                if let key = path.first {
                    var child = t[key] ?? .table([:])
                    try update(&child, path.dropFirst(), body)
                    t[key] = child
                } else {
                    try body(&t)
                }
                value = .table(t)
            case .array(var a):
                guard var last = a.last else { throw fail("empty array of tables") }
                try update(&last, path, body)
                a[a.count - 1] = last
                value = .array(a)
            default:
                throw fail("key is already set to a value, it cannot be used as a table")
            }
        }

        mutating func parseKey() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                if peek == "\"" || peek == "'" {
                    parts.append(try parseString())
                } else {
                    var s = ""
                    while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" {
                        s.append(c)
                        advance()
                    }
                    guard !s.isEmpty else { throw fail("expected a key") }
                    parts.append(s)
                }
                skipSpaces()
                if peek == "." { advance() } else { break }
            }
            return parts
        }

        mutating func parseString() throws -> String {
            guard let quote = peek else { throw fail("expected a string") }
            advance()
            var s = ""
            while let c = peek {
                if c == "\n" { throw fail("string is not closed") }
                advance()
                if c == quote { return s }
                if c == "\\" && quote == "\"" {
                    guard let e = peek else { break }
                    advance()
                    switch e {
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    case "\\": s.append("\\")
                    case "\"": s.append("\"")
                    default: throw fail("unknown escape '\\\(e)'")
                    }
                } else {
                    s.append(c)
                }
            }
            throw fail("string is not closed")
        }

        mutating func parseValue() throws -> TOMLValue {
            guard let c = peek else { throw fail("expected a value") }
            if c == "\"" || c == "'" { return .string(try parseString()) }
            if c == "[" {
                advance()
                var items: [TOMLValue] = []
                while true {
                    skipBlank()
                    if peek == "]" {
                        advance()
                        return .array(items)
                    }
                    items.append(try parseValue())
                    skipBlank()
                    if peek == "," {
                        advance()
                    } else if peek != "]" {
                        throw fail("expected ',' or ']' in array")
                    }
                }
            }
            if c == "{" {
                advance()
                var table = TOMLValue.table([:])
                skipSpaces()
                if peek == "}" {
                    advance()
                    return table
                }
                while true {
                    let key = try parseKey()
                    skipSpaces()
                    guard peek == "=" else { throw fail("expected '=' in inline table") }
                    advance()
                    skipSpaces()
                    let v = try parseValue()
                    let name = key[key.count - 1]
                    try update(&table, key.dropLast()) { $0[name] = v }
                    skipSpaces()
                    if peek == "," {
                        advance()
                        skipSpaces()
                    } else if peek == "}" {
                        advance()
                        return table
                    } else {
                        throw fail("expected ',' or '}' in inline table")
                    }
                }
            }
            var word = ""
            while let ch = peek, !Parser.wordEnd.contains(ch) {
                word.append(ch)
                advance()
            }
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
            let digits = word.replacingOccurrences(of: "_", with: "")
            if let i = Int(digits) { return .int(i) }
            if let d = Double(digits) { return .double(d) }
            throw fail("cannot read value '\(word)' (strings need quotes)")
        }
    }
}
