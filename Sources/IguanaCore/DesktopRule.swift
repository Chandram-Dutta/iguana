import Foundation

/// What a rule's `desktop` comes to for one window that has just appeared.
public enum DesktopRuleAction: Equatable {
    /// Nothing to do: no desktop is named, the window is not a standard one, or it is there already.
    case leave
    /// Send the window to this desktop, and stay on the one being used.
    case send(Int)
    /// The rule names a desktop that does not exist.
    case missing
    /// This system can only take a window to a desktop by going there with it, and a rule
    /// never takes the user anywhere.
    case cannotStay

    /// - Parameters:
    ///   - wanted: the desktop the window's rule names, if it names one.
    ///   - standardWindow: false for dialogs, sheets and everything else that is never tiled.
    ///   - windowDesktops: the desktops the window is on now (every one, for a window assigned to all desktops).
    ///   - desktopCount: how many desktops there are.
    ///   - canStay: whether a window can be sent away without following it.
    public static func decide(wanted: Int?, standardWindow: Bool, windowDesktops: [Int], desktopCount: Int, canStay: Bool) -> DesktopRuleAction {
        guard let wanted, standardWindow else { return .leave }
        guard wanted >= 1, wanted <= desktopCount else { return .missing }
        if windowDesktops.contains(wanted) { return .leave }
        return canStay ? .send(wanted) : .cannotStay
    }
}

/// The new windows a rule names a desktop for. A rule sends a window once, when it first
/// appears. This is the memory that keeps it to once, and keeps out every window that was
/// already open: those stay where the user has them.
public struct DesktopRuleQueue {
    public struct Entry: Equatable {
        public let window: WindowID
        public let desktop: Int
        /// The app's name, for the log.
        public let app: String
    }

    /// A window can be reported a moment before it settles into its final role. One that is
    /// not a standard window yet gets this long to become one. Later than that the user may
    /// be working in it, and it stays.
    public static let patience: TimeInterval = 2

    /// Windows the system already had at the first look, or when the config was last read.
    /// Some of them are on other desktops and only come into view when their desktop is shown.
    private var old = Set<WindowID>()
    private var waiting: [WindowID: (entry: Entry, since: Date)] = [:]
    /// False until the windows that were open before Iguana have been counted as old.
    public private(set) var hasLooked = false

    public init() {}

    /// The first look at the windows: all that exist were open before Iguana, so none is new.
    public mutating func firstLook(existing: Set<WindowID>) {
        markExisting(existing)
        hasLooked = true
    }

    /// Everything that exists now was here first. Done when the config is read, so that a rule
    /// only acts on windows that open after it was written.
    public mutating func markExisting(_ existing: Set<WindowID>) {
        old = existing
        waiting.removeAll()
    }

    /// A window seen for the first time, matched by a rule that names a desktop.
    public mutating func note(_ window: WindowID, desktop: Int, app: String, at now: Date) {
        guard hasLooked, !old.contains(window) else { return }
        waiting[window] = (Entry(window: window, desktop: desktop, app: app), now)
    }

    /// The windows to act on now. Each is handed out once and then forgotten.
    ///
    /// `standard` says whether a window is a standard one yet: false keeps it waiting, as long
    /// as patience lasts, and nil drops it (it is gone, or is not one to send at all).
    public mutating func due(at now: Date, paused: Bool, standard: (WindowID) -> Bool?) -> [Entry] {
        guard !waiting.isEmpty else { return [] }
        // While tiling is paused every window is left where it is, and stays there afterwards.
        guard !paused else {
            waiting.removeAll()
            return []
        }
        var due: [Entry] = []
        for (id, item) in waiting {
            guard now.timeIntervalSince(item.since) <= Self.patience, let isStandard = standard(id) else {
                waiting[id] = nil
                continue
            }
            guard isStandard else { continue }
            waiting[id] = nil
            due.append(item.entry)
        }
        return due.sorted { $0.window < $1.window }
    }
}
