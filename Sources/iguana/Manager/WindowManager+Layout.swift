import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    /// The windows of a stack overlap, and which of them is above which decides whether each one
    /// still shows its strip. Raise the ones that are out of order, the focused window last.
    /// Nothing is hidden or moved for this; the windows only change places front to back.
    func orderStack(_ snap: ScreenSnapshot) {
        guard drag == nil, let id = focusedWindow, lastFrames[id] != nil, let (_, tree) = treeEntry(containing: id) else { return }
        let raise = tree.stackRaiseOrder(focused: id, frontToBack: snap.order, visible: lastVisible)
        guard !raise.isEmpty else {
            stackOrderTries = 0
            return
        }
        // Raising a window can itself cause a refresh, and an app can answer a raise in ways of
        // its own. Three tries without the stack coming right, and it is left alone until the
        // user does something, so that this can never go round in circles.
        guard stackOrderTries < 3 else { return }
        stackOrderTries += 1
        if stackOrderTries == 3 { Log.write("stack: raising \(raise) twice did not put the stack around window \(id) in order; trying once more, then leaving it") }
        for other in raise { if let w = windows[other] { w.element.perform(kAXRaiseAction) } }
        // Raising another window of the same app can make that one the app's main window.
        windows[id]?.element.set(kAXMainAttribute, true)
    }

    func treeEntry(containing id: CGWindowID) -> (String, Tree)? {
        // Prefer the tree of a Space that is showing.
        for d in displays { if let t = trees[d.treeKey], t.contains(id) { return (d.treeKey, t) } }
        for (key, t) in trees where t.contains(id) { return (key, t) }
        return nil
    }

    var minSizes: [CGWindowID: CGSize] {
        var m: [CGWindowID: CGSize] = [:]
        for (id, w) in windows { if let s = w.minSize { m[id] = s } }
        return m
    }

    func layoutAll(_ snap: ScreenSnapshot) -> (frames: [CGWindowID: CGRect], slots: [CGWindowID: CGRect]) {
        var frames: [CGWindowID: CGRect] = [:]
        var allSlots: [CGWindowID: CGRect] = [:]
        var byDisplay: [Int: [WindowState]] = [:]
        for w in windows.values where w.tileable && !w.floating {
            // A window a rule just sent to another display is still where it was, briefly:
            // it is not adopted anywhere until the move shows.
            guard inTransit[w.id] == nil else { continue }
            guard let rect = snap.onScreen[w.id], let i = displayIndex(for: rect) else { continue }
            // While macOS slides from one Space to the next, the windows of both are on screen.
            // Only the ones that really live on the Space being shown belong in its layout.
            let spaces = system.spaces(of: w.id)
            guard spaces.isEmpty || spaces.contains(displays[i].spaceID) else { continue }
            byDisplay[i, default: []].append(w)
        }
        for (i, d) in displays.enumerated() where d.isDesktop {
            let here = (byDisplay[i] ?? []).sorted { $0.id < $1.id }
            let ids = Set(here.map(\.id))
            let usable = d.usableFrame(config), gap = d.settings(config).inner
            let key = d.treeKey
            // After a restart of the Mac, the desktop takes its saved shape again as its windows come back.
            restoreLayout(d, here, snap, usable: usable, gap: gap)
            let tree: Tree
            if let t = trees[key] {
                tree = t
            } else {
                tree = Tree(orientation: usable.width >= usable.height ? .horizontal : .vertical)
                trees[key] = tree
            }
            for w in here where !tree.contains(w.id) {
                adopt(w, into: tree, key: key, visible: ids, usable: usable, gap: gap)
            }
            if let z = zoomed[key], !ids.contains(z) { zoomed[key] = nil }
            // A minimum remembered from the last run is checked the first time it would shape a layout.
            let doubtful = ids.intersection(unverifiedMinimums)
            if !doubtful.isEmpty {
                unverifiedMinimums.subtract(doubtful)
                recheckMinimums(in: tree, key: key, visible: ids, usable: usable, gap: gap, only: doubtful)
            }
            let computed = computeLayout(tree, in: usable, gap: gap, visible: ids, minSizes: minSizes, peek: config.stackPeek)
            allSlots.merge(computed) { a, _ in a }
            var applied = computed
            if let z = zoomed[key] { applied[z] = usable }
            frames.merge(applied) { a, _ in a }
        }
        return (frames, allSlots)
    }

    func adopt(_ w: WindowState, into tree: Tree, key: String, visible: Set<CGWindowID>, usable: CGRect, gap: Double) {
        for (k, other) in trees where k != key { other.remove(w.id) }
        justAdopted.insert(w.id)
        splitHints[w.id] = nil

        // A window that takes the place of another window of the same app (a native tab coming
        // forward) inherits its slot instead of opening a new one.
        if let twin = tree.windows.first(where: { lastVisible.contains($0) && !visible.contains($0) && windows[$0]?.pid == w.pid }) {
            tree.insert(w.id, after: twin, sameSlot: true)
            return
        }

        let preferred = [tree.focused, focusedWindow].compactMap { $0 }
        let anchor = preferred.first { $0 != w.id && visible.contains($0) && tree.contains($0) }
            ?? tree.windows.last { visible.contains($0) }
        var split: Orientation?
        if let anchor, let hint = splitHints.removeValue(forKey: anchor) {
            split = hint
        } else if config.autoSplit, let anchor,
                  let f = computeLayout(tree, in: usable, gap: gap, visible: visible)[anchor] {
            split = f.width >= f.height ? .horizontal : .vertical
        }
        tree.insert(w.id, after: anchor, split: split)
        tree.focused = w.id
    }

    /// Send every window to its frame. Windows glide there unless the change is tiny, the window
    /// has only just joined the layout, or motion is switched off.
    func apply(_ frames: [CGWindowID: CGRect], _ snap: ScreenSnapshot, animated: Bool) {
        let glide = animated && config.animate && !system.reduceMotion
        for (id, target) in frames {
            guard let w = windows[id], drag?.id != id else { continue }
            w.lastSetFrame = target
            if let heading = mover.destination(of: id), nearlyEqual(heading, target, tolerance: 0.5) { continue }
            let current = snap.onScreen[id]
            if let current, nearlyEqual(current, target), !mover.isMoving(id) { continue }
            var duration = 0.0
            if glide, let current, !justAdopted.contains(id) {
                let change = max(abs(current.minX - target.minX), abs(current.minY - target.minY),
                                 abs(current.width - target.width), abs(current.height - target.height))
                if change > 12 { duration = config.animationDuration }
            }
            mover.move(id, pid: w.pid, element: w.element, app: apps[w.pid]?.element,
                          from: current ?? target, to: target, duration: duration, easing: config.animationEasing)
        }
        justAdopted.removeAll()
    }
}
