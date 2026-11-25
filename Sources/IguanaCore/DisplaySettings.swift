import CoreGraphics
import Foundation

/// Settings for one display, from a `[[display]]` table. A key left out falls back to `[gaps]`,
/// so a wide monitor can have room of its own while every other display keeps the usual gaps.
public struct DisplaySettings: Equatable {
    /// Part of the display's name, case-insensitive.
    public var name: String?
    /// The display's number, as `DisplayOrder` counts them: from 1, left to right.
    public var number: Int?
    public var inner: Double?
    /// A side an `outer` table leaves out already holds the `[gaps]` value for it.
    public var outer: Edges?
    /// The layout is at most this wide, centred.
    public var maxWidth: Double?

    public init(name: String? = nil, number: Int? = nil, inner: Double? = nil, outer: Edges? = nil, maxWidth: Double? = nil) {
        self.name = name
        self.number = number
        self.inner = inner
        self.outer = outer
        self.maxWidth = maxWidth
    }

    /// The display numbers a table can name, the same range as the desktop numbers.
    public static let numbers = 1...16

    public func matches(name displayName: String, number displayNumber: Int) -> Bool {
        if let name { return displayName.lowercased().contains(name.lowercased()) }
        return number == displayNumber
    }

    /// What one display is laid out with.
    public struct Effective: Equatable {
        public var inner: Double
        public var outer: Edges
        public var maxWidth: Double?
    }

    /// `area` narrowed to `maxWidth` and centred in it, when it is wider. On a narrower display
    /// the area stays as it is.
    public static func narrow(_ area: CGRect, maxWidth: Double?) -> CGRect {
        guard let maxWidth, area.width > maxWidth else { return area }
        return CGRect(x: (area.minX + (area.width - maxWidth) / 2).rounded(), y: area.minY, width: maxWidth, height: area.height)
    }

    /// Read the `[[display]]` tables. `gaps` is the outer gap of `[gaps]`, for the sides an
    /// `outer` table leaves out.
    static func parse(_ value: TOMLValue, gaps: Edges, warnings: inout [String]) -> [DisplaySettings] {
        guard let list = value.arrayValue, list.allSatisfy({ $0.tableValue != nil }) else {
            warnings.append("display settings are written as [[display]] sections")
            return []
        }
        var result: [DisplaySettings] = []
        for (i, entry) in list.enumerated() {
            guard let t = entry.tableValue else { continue }
            let label = "display \(i + 1)"
            func number(_ v: TOMLValue?, _ key: String, min: Double, max: Double) -> Double? {
                guard let v else { return nil }
                guard let d = v.doubleValue, d >= min, d <= max else {
                    warnings.append("\(label): \(key) must be a number from \(Int(min)) to \(Int(max)); ignoring it")
                    return nil
                }
                return d
            }
            func checkKeys(_ table: [String: TOMLValue], _ known: [String], _ section: String) {
                for k in table.keys.sorted() where !known.contains(k) {
                    warnings.append("unknown key '\(k)' in \(section)")
                }
            }
            checkKeys(t, ["name", "number", "inner", "outer", "max-width"], label)

            // A table that cannot say which display it is for is skipped whole.
            var s = DisplaySettings()
            switch (t["name"], t["number"]) {
            case (nil, nil):
                warnings.append("\(label) needs 'name' or 'number'")
                continue
            case (.some, .some):
                warnings.append("\(label) needs 'name' or 'number', not both")
                continue
            case (let name?, nil):
                guard let text = name.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                    warnings.append("\(label): name must be part of the display's name, such as \"LG\"; skipping this [[display]]")
                    continue
                }
                s.name = text
            case (nil, let number?):
                guard case .int(let n) = number, numbers.contains(n) else {
                    warnings.append("\(label): number must be a whole number from \(numbers.lowerBound) to \(numbers.upperBound); skipping this [[display]]")
                    continue
                }
                s.number = n
            }

            s.inner = number(t["inner"], "inner", min: 0, max: 200)
            if let outer = t["outer"] {
                if let sides = outer.tableValue {
                    checkKeys(sides, ["top", "left", "bottom", "right"], "outer of \(label)")
                    var e = gaps
                    if let v = number(sides["top"], "outer.top", min: 0, max: 500) { e.top = v }
                    if let v = number(sides["left"], "outer.left", min: 0, max: 500) { e.left = v }
                    if let v = number(sides["bottom"], "outer.bottom", min: 0, max: 500) { e.bottom = v }
                    if let v = number(sides["right"], "outer.right", min: 0, max: 500) { e.right = v }
                    s.outer = e
                } else if let v = number(outer, "outer", min: 0, max: 500) {
                    s.outer = Edges(all: v)
                }
            }
            s.maxWidth = number(t["max-width"], "max-width", min: 400, max: 10000)
            result.append(s)
        }
        return result
    }
}

extension Config {
    /// What a display is laid out with: the first `[[display]]` that matches it, and `[gaps]`
    /// for every key that one leaves out.
    public func displaySettings(name: String, number: Int) -> DisplaySettings.Effective {
        let s = displays.first { $0.matches(name: name, number: number) }
        return DisplaySettings.Effective(inner: s?.inner ?? gapInner, outer: s?.outer ?? gapOuter, maxWidth: s?.maxWidth)
    }
}
