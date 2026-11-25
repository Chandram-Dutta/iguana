import Foundation

/// `iguana subscribe`: the events of `[hooks]` as a stream of lines of JSON, for a status bar
/// that stays connected instead of having a shell started for every change.
public enum EventStream {
    /// One event as one line of JSON, with the keys sorted. It says what the hook of the event
    /// is told: each variable becomes a key, so a variable the hooks gain reaches the stream too.
    public static func line(_ variables: [String: String]) -> String {
        let pairs = variables.map { v -> (String, String) in let k = key(v.key); return (k, value(k, v.value)) }.sorted { $0.0 < $1.0 }
        return "{" + pairs.map { quoted($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    /// The key for a variable: `IGUANA_WINDOW_ID` is `window-id`.
    public static func key(_ variable: String) -> String {
        let name = variable.hasPrefix("IGUANA_") ? String(variable.dropFirst("IGUANA_".count)) : variable
        return name.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// A variable is only ever text, so its JSON type is read off it: a whole number is a
    /// number — but only the keys that are one get that type: `desktop` and `window-id` may be
    /// numbers, `paused` may be a boolean, and an empty value is `null` for every key. Anything
    /// else is always a string, so a window titled `42` or an app called `true` stays text.
    public static func value(_ key: String, _ text: String) -> String {
        if text.isEmpty { return "null" }
        if numberKeys.contains(key), isNumber(text) { return text }
        if booleanKeys.contains(key), text == "true" || text == "false" { return text }
        return quoted(text)
    }

    /// The keys whose value is a JSON number when it is all digits, and the one that is a boolean.
    private static let numberKeys: Set<String> = [key("IGUANA_DESKTOP"), key("IGUANA_WINDOW_ID")]
    private static let booleanKeys: Set<String> = [key("IGUANA_PAUSED")]

    /// Digits that every JSON reader takes back as the same number: without a leading zero,
    /// which JSON does not allow, and few enough for a double to hold exactly.
    private static func isNumber(_ text: String) -> Bool {
        let digits = text.utf8
        guard (1...15).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
        return digits.count == 1 || digits.first != 0x30
    }

    /// Text as a JSON string. Quotes, backslashes and control characters are escaped, and so are
    /// the two characters that some readers take for the end of a line, so an event is always
    /// one line. Everything else, emoji included, is written as it is.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{0}"..."\u{1F}", "\u{2028}", "\u{2029}": out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
