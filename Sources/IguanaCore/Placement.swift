import CoreGraphics
import Foundation

/// A part of a display's area for a floating window: what `place` takes, and what a rule's
/// `position` names.
public enum Placement: String, CaseIterable {
    case center, left, right, top, bottom
    case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
    case full

    /// Every name, for messages.
    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// Which edge the placement holds a window against on each axis: -1 the left or the top,
    /// 1 the right or the bottom, 0 neither.
    private var edges: (x: Int, y: Int) {
        switch self {
        case .center, .full: return (0, 0)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        case .topLeft: return (-1, -1)
        case .topRight: return (1, -1)
        case .bottomLeft: return (-1, 1)
        case .bottomRight: return (1, 1)
        }
    }

    /// The window's frame in `area`. Halves and quarters leave `gap` between them, half of it on
    /// each side of the edge they share. Only `center` uses `size`, the window's own size: it
    /// keeps it, shrunk to fit the area.
    public func frame(in area: CGRect, gap: Double, size: CGSize) -> CGRect {
        if self == .center {
            let w = min(size.width, area.width), h = min(size.height, area.height)
            return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        }
        let (x, y) = edges
        let w = x == 0 ? area.width : max(0, (area.width - CGFloat(gap)) / 2)
        let h = y == 0 ? area.height : max(0, (area.height - CGFloat(gap)) / 2)
        return CGRect(x: x > 0 ? area.maxX - w : area.minX, y: y > 0 ? area.maxY - h : area.minY, width: w, height: h)
    }

    /// Where a window goes that came out at `size` instead of the size of `asked`, the frame this
    /// placement gave it: an app can have a minimum size or a fixed one. It still keeps to the
    /// placement's edges (a left placement keeps its left edge on the left of the area), is
    /// centred where the placement holds it to neither edge, and never has its top-left corner
    /// outside the area, so its title bar stays within reach.
    public func fit(_ size: CGSize, to asked: CGRect, in area: CGRect) -> CGRect {
        func start(_ edge: Int, _ low: CGFloat, _ high: CGFloat, _ length: CGFloat, _ areaLow: CGFloat, _ areaHigh: CGFloat) -> CGFloat {
            let s = edge < 0 ? low : edge > 0 ? high - length : (low + high - length) / 2
            return max(min(s, areaHigh - length), areaLow)
        }
        let (x, y) = edges
        return CGRect(x: start(x, asked.minX, asked.maxX, size.width, area.minX, area.maxX),
                      y: start(y, asked.minY, asked.maxY, size.height, area.minY, area.maxY),
                      width: size.width, height: size.height)
    }
}

extension Rule {
    /// Whether the rule gives the windows it floats a size or a position when they open.
    public var placesWindows: Bool { floats && (size != nil || position != nil) }

    /// The frame a window this rule floats is given when it opens, from the frame it opened
    /// with. Nil when the rule gives no size or position, or does not float its windows.
    ///
    /// The size comes first and the position is then found for it. A size on its own keeps the
    /// window's top-left corner, moved in as far as it takes to fit the area. Halves, quarters
    /// and `full` have a size of their own, so with them the rule's size counts for nothing.
    public func frame(for window: CGRect, in area: CGRect, gap: Double) -> CGRect? {
        guard placesWindows else { return nil }
        let size = self.size ?? window.size
        if let position { return position.frame(in: area, gap: gap, size: size) }
        let fitted = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        return fit(fitted, to: CGRect(origin: window.origin, size: fitted), in: area)
    }

    /// Where the window goes if it will not take the size `frame(for:in:gap:)` gave it: against
    /// the edges of the rule's position, or at its top-left corner when the rule only gives a size.
    public func fit(_ size: CGSize, to asked: CGRect, in area: CGRect) -> CGRect {
        (position ?? .topLeft).fit(size, to: asked, in: area)
    }
}

/// The new windows a rule gives a size or a position. As with `DesktopRuleQueue`, a rule places
/// a window once, when it first opens, and leaves alone every window that was already open.
public struct PlacementRuleQueue {
    public struct Entry: Equatable {
        public let window: WindowID
        public let rule: Rule
        /// The app's name, for the log.
        public let app: String
    }

    /// Windows the system already had at the first look, or when the config was last read.
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
    /// only places windows that open after it was written.
    public mutating func markExisting(_ existing: Set<WindowID>) {
        old = existing
        waiting.removeAll()
    }

    /// A window seen for the first time, and the rule that decides for it.
    public mutating func note(_ window: WindowID, rule: Rule, app: String, at now: Date) {
        guard hasLooked, rule.placesWindows, !old.contains(window) else { return }
        waiting[window] = (Entry(window: window, rule: rule, app: app), now)
    }

    /// The windows to place now. Each is handed out once and then forgotten.
    ///
    /// `standard` says whether a window is a standard one yet: false keeps it waiting for as
    /// long as `DesktopRuleQueue.patience` lasts, and nil drops it (it is gone, no longer
    /// floats, or is not one to place at all).
    public mutating func due(at now: Date, paused: Bool, standard: (WindowID) -> Bool?) -> [Entry] {
        guard !waiting.isEmpty else { return [] }
        // While tiling is paused Iguana moves no window, and does not catch up afterwards.
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
