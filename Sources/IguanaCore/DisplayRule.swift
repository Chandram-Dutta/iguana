import CoreGraphics
import Foundation

/// A display as a rule names it: part of its name, or its number in `DisplayOrder`.
public enum DisplayRef: Hashable, CustomStringConvertible {
    case name(String)
    case number(Int)

    /// The numbers a rule can give, the same range as the desktops.
    public static let numbers = 1...16

    /// What a rule's `display` says, or nil when it says nothing that can be used: an empty
    /// name, a number out of range, or a value of another type.
    public init?(_ value: TOMLValue) {
        switch value {
        case .string(let s) where !s.trimmingCharacters(in: .whitespaces).isEmpty: self = .name(s)
        case .int(let n) where Self.numbers.contains(n): self = .number(n)
        default: return nil
        }
    }

    /// As the config file writes it.
    public var toml: TOMLValue {
        switch self {
        case .name(let s): return .string(s)
        case .number(let n): return .int(n)
        }
    }

    public var description: String {
        switch self {
        case .name(let s): return "\"\(s)\""
        case .number(let n): return "\(n)"
        }
    }

    /// Which of the connected displays this is, as a position in `names` and `frames` (one
    /// entry for each display, in the same order). A name matches a display whose name is it,
    /// ignoring case, or else the first display in display order whose name contains it.
    public func resolve(names: [String], frames: [CGRect]) -> Int? {
        let order = DisplayOrder.order(frames)
        switch self {
        case .number(let n):
            return order.indices.contains(n - 1) ? order[n - 1] : nil
        case .name(let s):
            let wanted = s.trimmingCharacters(in: .whitespaces).lowercased()
            return order.first { names[$0].lowercased() == wanted } ?? order.first { names[$0].lowercased().contains(wanted) }
        }
    }
}

/// What a rule's `display` comes to for one window.
public enum DisplayRuleAction: Equatable {
    /// Nothing to do: no display is named, the window is not a standard one, or it is there already.
    case leave
    /// Move the window to the display at this position in the list of displays.
    case send(Int)
    /// No connected display is the one the rule names.
    case missing

    /// - Parameters:
    ///   - wanted: the display the window's rule names, if it names one.
    ///   - standardWindow: false for dialogs, sheets and everything else that is never tiled.
    ///   - windowDisplay: the position of the display the window is on now, nil when not known.
    ///   - names: the names of the connected displays.
    ///   - frames: their frames, in the same order, in top-left coordinates.
    public static func decide(wanted: DisplayRef?, standardWindow: Bool, windowDisplay: Int?, names: [String], frames: [CGRect]) -> DisplayRuleAction {
        guard let wanted, standardWindow else { return .leave }
        guard let index = wanted.resolve(names: names, frames: frames) else { return .missing }
        return index == windowDisplay ? .leave : .send(index)
    }
}

/// The new windows a rule names a display for. It keeps the same memory as `DesktopRuleQueue`:
/// a window is sent once, when it first appears, and every window that was already open stays.
public struct DisplayRuleQueue {
    public struct Entry: Equatable {
        public let window: WindowID
        public let display: DisplayRef
        /// The rule's number in the file, so that a display that is not there is reported once for each rule.
        public let rule: Int
        /// The app's name, for the log.
        public let app: String
    }

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

    /// Everything that exists now was here first. Done when the config is read.
    public mutating func markExisting(_ existing: Set<WindowID>) {
        old = existing
        waiting.removeAll()
    }

    /// A window seen for the first time, matched by a rule that names a display.
    public mutating func note(_ window: WindowID, display: DisplayRef, rule: Int, app: String, at now: Date) {
        guard hasLooked, !old.contains(window) else { return }
        waiting[window] = (Entry(window: window, display: display, rule: rule, app: app), now)
    }

    /// The windows to act on now, each handed out once. `standard` is read as in
    /// `DesktopRuleQueue.due`: false keeps a window waiting while patience lasts, nil drops it.
    public mutating func due(at now: Date, paused: Bool, standard: (WindowID) -> Bool?) -> [Entry] {
        guard !waiting.isEmpty else { return [] }
        guard !paused else {
            waiting.removeAll()
            return []
        }
        var due: [Entry] = []
        for (id, item) in waiting {
            guard now.timeIntervalSince(item.since) <= DesktopRuleQueue.patience, let isStandard = standard(id) else {
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
