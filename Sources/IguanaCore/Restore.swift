import CoreGraphics
import Foundation

/// What is kept of a window so that it can be known again after the Mac restarts, when every
/// window comes back with a new id.
public struct WindowDescriptor: Codable, Equatable {
    public var bundleID: String?
    /// The app's name, for the log.
    public var app: String?
    public var title: String?
    /// Where the window was, in top-left coordinates.
    public var frame: CGRect

    public init(bundleID: String?, app: String?, title: String?, frame: CGRect) {
        self.bundleID = bundleID
        self.app = app
        self.title = title
        self.frame = frame
    }
}

/// Knowing windows again after a restart of the Mac.
public enum Restore {
    /// Pair windows with the saved windows they most likely are. A window only pairs with a saved
    /// window of the same app: one with the same title first, then the nearest by the centre of
    /// its frame. Each window and each saved window is used once, and ties go to the lowest ids,
    /// so the same windows always pair the same way.
    ///
    /// Returns, for each window that paired, the id of the saved window it is.
    public static func match(_ windows: [WindowID: WindowDescriptor], to saved: [WindowID: WindowDescriptor]) -> [WindowID: WindowID] {
        var result: [WindowID: WindowID] = [:]
        var used = Set<WindowID>()
        func pair(_ ws: [WindowID], _ ss: [WindowID]) {
            var pairs: [(distance: Double, window: WindowID, saved: WindowID)] = []
            for w in ws where result[w] == nil {
                for s in ss where !used.contains(s) {
                    let a = windows[w]!.frame, b = saved[s]!.frame
                    pairs.append((Double(hypot(a.midX - b.midX, a.midY - b.midY)), w, s))
                }
            }
            pairs.sort { ($0.distance, $0.window, $0.saved) < ($1.distance, $1.window, $1.saved) }
            for p in pairs where result[p.window] == nil && !used.contains(p.saved) {
                result[p.window] = p.saved
                used.insert(p.saved)
            }
        }
        for app in Set(windows.values.compactMap(\.bundleID)).sorted() {
            let ws = windows.keys.filter { windows[$0]!.bundleID == app }.sorted()
            let ss = saved.keys.filter { saved[$0]!.bundleID == app }.sorted()
            let titles = Set(ws.compactMap { windows[$0]!.title }).filter { !$0.isEmpty }
            // Two windows can have the same title; where they are tells them apart.
            for title in titles.sorted() {
                pair(ws.filter { windows[$0]!.title == title }, ss.filter { saved[$0]!.title == title })
            }
            pair(ws, ss)
        }
        return result
    }

    /// The saved layout with each saved window that paired replaced by its window, as `match`
    /// gives them. Saved windows that did not pair are left out, and the containers around them
    /// close up; directions, shares and stacks stay as they were.
    public static func tree(from layout: NodeSnapshot, matched: [WindowID: WindowID]) -> Tree {
        var window: [WindowID: WindowID] = [:]
        for (w, s) in matched { window[s] = w }
        func keep(_ s: NodeSnapshot) -> NodeSnapshot? {
            var s = s
            if let id = s.window {
                guard let w = window[id] else { return nil }
                s.window = w
                return s
            }
            s.children = s.children?.compactMap(keep)
            return s
        }
        guard layout.window == nil, let kept = keep(layout) else { return Tree() }
        return Tree(snapshot: kept)
    }

    /// Which new windows are windows the user had floated by hand. A window takes a saved one of
    /// its app with the same title. Failing that, an app that has a single window and a single
    /// saved one pairs those two.
    /// - windows: windows seen for the first time.
    /// - appWindows: how many windows each app has now, these included, by bundle id.
    ///
    /// Returns, for each window that floats again, the index in `saved` it took.
    public static func floating(_ windows: [WindowID: WindowDescriptor], appWindows: [String: Int], saved: [WindowDescriptor]) -> [WindowID: Int] {
        var result: [WindowID: Int] = [:]
        var used = Set<Int>()
        for id in windows.keys.sorted() {
            guard let w = windows[id], w.bundleID != nil, let title = w.title, !title.isEmpty,
                  let i = saved.indices.first(where: { !used.contains($0) && saved[$0].bundleID == w.bundleID && saved[$0].title == title }) else { continue }
            result[id] = i
            used.insert(i)
        }
        for (app, count) in appWindows where count == 1 {
            let ws = windows.keys.filter { windows[$0]!.bundleID == app && result[$0] == nil }
            let ss = saved.indices.filter { saved[$0].bundleID == app && !used.contains($0) }
            guard ws.count == 1, ss.count == 1 else { continue }
            result[ws[0]] = ss[0]
            used.insert(ss[0])
        }
        return result
    }
}

/// The layouts saved before a restart of the Mac, waiting for their windows to come back.
///
/// Apps reopen their windows over the first minutes after login, each with a new id. Each time
/// more of a desktop's windows appear, the desktop is laid out in its saved shape again. This
/// stops for a desktop once all its windows are back or the user changes its layout, and for
/// every desktop when the grace period is over.
public struct RestoreSession {
    public static let gracePeriod: TimeInterval = 180

    private struct Template {
        let layout: NodeSnapshot
        let leaves: [WindowID: WindowDescriptor]
        /// The windows that have taken a place, and the saved window each one is.
        var matched: [WindowID: WindowID] = [:]
    }

    private var templates: [String: Template] = [:]
    private var floating: [WindowDescriptor] = []
    private let deadline: Date

    /// Nothing to restore.
    public init() {
        deadline = .distantPast
    }

    /// - trees: the saved layout of each desktop, by tree key.
    /// - floating: the windows that were floated by hand.
    /// - windows: what each saved window was.
    /// - start: when tiling starts; the grace period runs from here.
    public init(trees: [String: NodeSnapshot], floating: [WindowID], windows: [WindowID: WindowDescriptor], from start: Date) {
        for (key, layout) in trees {
            var leaves: [WindowID: WindowDescriptor] = [:]
            for id in Tree(snapshot: layout).windows { if let d = windows[id], d.bundleID != nil { leaves[id] = d } }
            if !leaves.isEmpty { templates[key] = Template(layout: layout, leaves: leaves) }
        }
        self.floating = floating.compactMap { windows[$0] }.filter { $0.bundleID != nil }
        deadline = start.addingTimeInterval(Self.gracePeriod)
    }

    /// The desktops whose layout is still waiting for windows.
    public var waiting: Set<String> { Set(templates.keys) }

    /// Everything is forgotten once the grace period is over.
    private mutating func expire(at now: Date) {
        guard now > deadline else { return }
        templates.removeAll()
        floating.removeAll()
    }

    /// The apps whose windows can still take a place on this desktop, so that only their
    /// windows need looking at.
    public mutating func apps(waitingOn key: String, at now: Date) -> Set<String> {
        expire(at: now)
        guard let t = templates[key] else { return [] }
        let free = Set(t.leaves.keys).subtracting(t.matched.values)
        return Set(free.compactMap { t.leaves[$0]?.bundleID })
    }

    /// Look at a desktop that is being shown. When one of its windows takes a place in the
    /// desktop's saved layout, the layout is built again with every window that has taken one
    /// and is still there, and returned; otherwise nil.
    /// - windows: the windows on screen on the desktop, as they are now.
    /// - kept: the windows in the desktop's layout now. A window that took a place and is in
    ///   neither has closed or gone to another desktop, and leaves a gap.
    public mutating func rebuild(_ key: String, windows: [WindowID: WindowDescriptor], kept: Set<WindowID>, at now: Date) -> Tree? {
        expire(at: now)
        guard var t = templates[key] else { return nil }
        let elsewhere = Set(templates.values.flatMap(\.matched.keys))
        let free = t.leaves.filter { !t.matched.values.contains($0.key) }
        let new = Restore.match(windows.filter { !elsewhere.contains($0.key) }, to: free)
        guard !new.isEmpty else { return nil }
        t.matched.merge(new) { old, _ in old }
        templates[key] = t.matched.count == t.leaves.count ? nil : t
        return Restore.tree(from: t.layout, matched: t.matched.filter { windows[$0.key] != nil || kept.contains($0.key) })
    }

    /// The user changed this desktop's layout. What they did stands, and the saved layout no
    /// longer takes the desktop over.
    public mutating func stop(_ key: String) {
        templates[key] = nil
    }

    /// Whether a window of this app may be one the user had floated by hand.
    public mutating func mayFloat(_ bundleID: String, at now: Date) -> Bool {
        expire(at: now)
        return floating.contains { $0.bundleID == bundleID }
    }

    /// Windows seen for the first time, and how many windows each app has now. Returns the
    /// windows that were floated by hand before the restart, so that they float again.
    public mutating func refloat(_ windows: [WindowID: WindowDescriptor], appWindows: [String: Int], at now: Date) -> [WindowID] {
        expire(at: now)
        let taken = Restore.floating(windows, appWindows: appWindows, saved: floating)
        let used = Set(taken.values)
        floating = floating.indices.filter { !used.contains($0) }.map { floating[$0] }
        return taken.keys.sorted()
    }
}
