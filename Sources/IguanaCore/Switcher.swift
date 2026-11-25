import Foundation

/// The window switcher (`switcher`): which windows it lists for what has been typed, and in
/// what order. The macOS layer gathers the windows and draws the list.
public enum Switcher {
    /// Whether a window can be seen right now, and if not, why not.
    public enum Visibility: Equatable {
        case onScreen
        case minimised
        /// Its app is hidden.
        case hidden
        /// On a desktop being shown, in a Stage Manager stage that is not.
        case otherStage
        /// On another desktop, or somewhere Iguana cannot tell.
        case elsewhere
    }

    public struct Window: Equatable {
        public var id: WindowID
        public var app: String
        public var title: String
        /// Numbered as Mission Control numbers desktops. Nil when Iguana cannot tell.
        public var desktop: Int?
        public var visibility: Visibility
        public var focused: Bool
        /// When the window last had the focus. Nil when it has not had it since Iguana started.
        public var lastFocused: Date?

        public init(id: WindowID, app: String, title: String, desktop: Int? = nil, visibility: Visibility = .onScreen,
                    focused: Bool = false, lastFocused: Date? = nil) {
            self.id = id
            self.app = app
            self.title = title
            self.desktop = desktop
            self.visibility = visibility
            self.focused = focused
            self.lastFocused = lastFocused
        }
    }

    /// How well a window matches what was typed, best first.
    public enum Rank: Int, Comparable {
        /// What was typed is the start of the app's name.
        case appPrefix
        /// What was typed is made of pieces that each start a word, in order: "inbox", "vsc".
        case wordStarts
        /// The letters of what was typed appear in order, anywhere.
        case subsequence

        public static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Match: Equatable {
        public var window: Window
        public var rank: Rank
        /// The characters that matched, as offsets into the app name and into the title.
        public var appHits: [Int]
        public var titleHits: [Int]
    }

    /// Most recently focused first and the focused window last, so that the first row is the
    /// window that had the focus before this one, as with Command-Tab. Windows that have not had
    /// the focus keep the order they came in, after the others.
    public static func ordered(_ windows: [Window]) -> [Window] {
        windows.enumerated().sorted { a, b in
            if a.element.focused != b.element.focused { return b.element.focused }
            switch (a.element.lastFocused, b.element.lastFocused) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The windows that match `query`, best first. Windows that match equally well keep the
    /// order they came in, which is the order of recency. An empty query matches every window.
    public static func filter(_ windows: [Window], query: String) -> [Match] {
        windows.enumerated()
            .compactMap { i, w in match(w, query: query).map { (i, $0) } }
            .sorted { ($0.1.rank, $0.0) < ($1.1.rank, $1.0) }
            .map(\.1)
    }

    /// How one window matches `query`, ignoring case, accents and spaces in the query; nil
    /// when it does not. The text searched is the app name, a space, then the title.
    public static func match(_ window: Window, query: String) -> Match? {
        let q = query.filter { !$0.isWhitespace }.map(fold)
        let app = Array(window.app), title = Array(window.title)
        let text = app + [" "] + title
        let folded = text.map(fold)
        let rank: Rank, hits: [Int]
        if let found = appPrefix(q, app) {
            (rank, hits) = (.appPrefix, found)
        } else if let found = wordStarts(q, folded, starts(text)) {
            (rank, hits) = (.wordStarts, found)
        } else if let found = subsequence(q, folded) {
            (rank, hits) = (.subsequence, found)
        } else {
            return nil
        }
        return Match(window: window, rank: rank, appHits: hits.filter { $0 < app.count },
                     titleHits: hits.filter { $0 > app.count }.map { $0 - app.count - 1 })
    }

    private static func fold(_ c: Character) -> String {
        String(c).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The query is the start of the app name, which may have spaces the query leaves out.
    private static func appPrefix(_ q: [String], _ app: [Character]) -> [Int]? {
        var hits: [Int] = []
        for (i, c) in app.enumerated() where hits.count < q.count && !c.isWhitespace {
            guard fold(c) == q[hits.count] else { return nil }
            hits.append(i)
        }
        return hits.count == q.count ? hits : nil
    }

    /// Where the words start: after anything that is not a letter or a digit, and where a
    /// lower-case letter is followed by a capital, as in "GitHub".
    private static func starts(_ text: [Character]) -> [Int] {
        text.indices.filter { i in
            let c = text[i]
            guard c.isLetter || c.isNumber else { return false }
            guard i > 0 else { return true }
            let before = text[i - 1]
            return !(before.isLetter || before.isNumber) || (before.isLowercase && c.isUppercase)
        }
    }

    /// The query cut into pieces that each begin at a word start, the words in order.
    private static func wordStarts(_ q: [String], _ text: [String], _ starts: [Int]) -> [Int]? {
        var failed = Set<Int>()
        func search(_ qi: Int, _ from: Int) -> [Int]? {
            if qi == q.count { return [] }
            let key = qi * (starts.count + 1) + from
            if failed.contains(key) { return nil }
            for j in from..<starts.count {
                let s = starts[j]
                var run = 0
                while qi + run < q.count, s + run < text.count, text[s + run] == q[qi + run] { run += 1 }
                // The longest piece first: a word typed out reads better highlighted whole.
                for length in stride(from: run, to: 0, by: -1) {
                    let next = starts[(j + 1)...].firstIndex { $0 >= s + length } ?? starts.count
                    if let rest = search(qi + length, next) { return Array(s..<(s + length)) + rest }
                }
            }
            failed.insert(key)
            return nil
        }
        return search(0, 0)
    }

    private static func subsequence(_ q: [String], _ text: [String]) -> [Int]? {
        var hits: [Int] = []
        for (i, c) in text.enumerated() where hits.count < q.count && c == q[hits.count] { hits.append(i) }
        return hits.count == q.count ? hits : nil
    }
}
