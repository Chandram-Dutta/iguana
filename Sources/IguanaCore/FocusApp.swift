import Foundation

/// `focus-app`: which running app the text names, which of its windows gets the focus, and
/// which app to open when none is running.
///
/// Iguana never hides a window, so it has no scratchpad. This is what it has instead: one key
/// that brings an app forward, or opens it.
public enum FocusApp {
    /// A running regular app, as far as choosing one goes.
    public struct App: Equatable {
        public var pid: Int32
        public var bundleID: String?
        /// The name the app gives itself, and the name of its bundle where that differs:
        /// Visual Studio Code calls itself "Code".
        public var names: [String]
        /// When it last had the focus, in any unit that grows with time. 0 for never.
        public var lastActive: Double

        public init(pid: Int32, bundleID: String?, names: [String], lastActive: Double) {
            self.pid = pid
            self.bundleID = bundleID
            self.names = names
            self.lastActive = lastActive
        }
    }

    /// How well the text names an app, best first. Nil when it does not name it at all.
    static func rank(_ text: String, _ app: App) -> Int? {
        let text = text.lowercased()
        let names = app.names.map { $0.lowercased() }
        if app.bundleID?.lowercased() == text { return 0 }
        if names.contains(text) { return 1 }
        if names.contains(where: { $0.hasPrefix(text) }) { return 2 }
        if names.contains(where: { $0.contains(text) }) { return 3 }
        return nil
    }

    /// The app the text names: by exact bundle id, then exact name, then a name that starts with
    /// the text, then one that contains it, so `code` is Code and not Xcode. Of two that match
    /// equally well, the one used last wins; of two never used, the first in the list.
    public static func choose(_ text: String, among apps: [App]) -> App? {
        var best: (app: App, rank: Int)?
        for app in apps {
            guard let rank = rank(text, app) else { continue }
            if let b = best, b.rank < rank || (b.rank == rank && b.app.lastActive >= app.lastActive) { continue }
            best = (app, rank)
        }
        return best?.app
    }

    public enum Pick: Equatable {
        case window(WindowID)
        /// The app's only window on screen has the focus already.
        case stay
        /// None of its windows is on a desktop being shown: the app is brought forward instead,
        /// and macOS picks the window, which may mean going to another desktop.
        case activate
    }

    /// Which of the app's windows to focus.
    /// - Parameters:
    ///   - showing: the app's windows on a desktop being shown now, on any display, front to back.
    ///   - remembered: the app's window that had the focus last.
    ///   - focused: the window that has the focus now.
    public static func pick(showing: [WindowID], remembered: WindowID?, focused: WindowID?) -> Pick {
        guard let front = showing.first else { return .activate }
        // The app has the focus already: each press goes on to its next window, in an order
        // that does not change as the focus moves.
        let ids = showing.sorted()
        if let focused, let i = ids.firstIndex(of: focused) {
            let next = ids[(i + 1) % ids.count]
            return next == focused ? .stay : .window(next)
        }
        if let remembered, showing.contains(remembered) { return .window(remembered) }
        return .window(front)
    }

    /// The folders an app that is not running is looked for in, in this order.
    public static func folders(home: String) -> [String] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"]
    }

    /// The app bundle called exactly `text`, ignoring case and the `.app`, among `paths`, in
    /// the order of the folders they are in. The first one wins.
    public static func bundle(named text: String, among paths: [String]) -> String? {
        let wanted = text.lowercased() + ".app"
        return paths.first { ($0 as NSString).lastPathComponent.lowercased() == wanted }
    }
}
