import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    // MARK: Saved layouts

    typealias SavedState = iguana.SavedState

    func loadState() {
        guard let saved = store.load() else { return }
        var described: [CGWindowID: WindowDescriptor] = [:]
        for (key, d) in saved.windows ?? [:] { if let id = CGWindowID(key) { described[id] = d } }
        guard saved.boot == store.bootTime() else {
            // Every window comes back with a new id. The layouts wait for windows that look like theirs.
            restore = RestoreSession(trees: saved.trees, floating: saved.floating, windows: described, from: scheduler.now)
            if !restore.waiting.isEmpty {
                Log.write("restore: the Mac has restarted; for \(Int(RestoreSession.gracePeriod / 60)) minutes, windows that come back take their places in \(restore.waiting.count) saved layout(s)")
            }
            return
        }
        savedWindows = described
        for (key, snapshot) in saved.trees { trees[key] = Tree(snapshot: snapshot) }
        restoredFloating = Set(saved.floating)
        for (key, size) in saved.minSizes ?? [:] where size.count == 2 {
            if let id = CGWindowID(key) { restoredMinSizes[id] = CGSize(width: size[0], height: size[1]) }
        }
    }

    func scheduleSave() {
        // Only the last of a run of changes is written.
        saveRequests += 1
        let request = saveRequests
        scheduler.after(1) { [weak self] in
            guard let self, self.saveRequests == request else { return }
            self.saveState()
        }
    }

    func saveState() {
        // Before tiling has started there is nothing to save, and saving would wipe what was kept.
        guard started else { return }
        var snapshots: [String: NodeSnapshot] = [:]
        for (key, tree) in trees where !tree.isEmpty { snapshots[key] = tree.snapshot }
        var mins: [String: [Double]] = [:]
        for w in windows.values { if let m = w.minSize { mins["\(w.id)"] = [Double(m.width), Double(m.height)] } }
        let floating = windows.values.filter { $0.userFloat == true }.map(\.id)
        // A window that is not on screen is kept as it was last seen, without asking its app.
        var described: [CGWindowID: WindowDescriptor] = [:]
        for id in Set(trees.values.flatMap(\.windows) + floating) {
            let ask = lastVisible.contains(id) || savedWindows[id] == nil
            described[id] = (ask ? windows[id].flatMap { describe($0, frame: lastFrames[id]) } : nil) ?? savedWindows[id]
        }
        savedWindows = described
        store.save(SavedState(boot: store.bootTime(), trees: snapshots, floating: floating, minSizes: mins,
                              windows: Dictionary(uniqueKeysWithValues: described.map { ("\($0.key)", $0.value) })))
    }

    // MARK: After a restart of the Mac

    /// What a window is, to know it again after a restart of the Mac. `frame` is where it is,
    /// when that is known already.
    func describe(_ w: WindowState, frame: CGRect?) -> WindowDescriptor? {
        guard let app = apps[w.pid]?.app, let frame = frame ?? w.element.frame else { return nil }
        return WindowDescriptor(bundleID: app.bundleIdentifier, app: app.localizedName, title: w.element.string(kAXTitleAttribute), frame: frame)
    }

    /// Lay a desktop out in its saved shape again when more of its windows have come back. This
    /// comes before the layout is computed, so the windows go straight to their places: the ones
    /// that have just come back at once, the others gliding as usual.
    func restoreLayout(_ display: DisplayInfo, _ here: [WindowState], _ snap: ScreenSnapshot, usable: CGRect, gap: Double) {
        // Never while a window is being dragged by hand.
        guard drag == nil else { return }
        let key = display.treeKey
        let wanted = restore.apps(waitingOn: key, at: scheduler.now)
        guard !wanted.isEmpty else { return }
        var seen: [CGWindowID: WindowDescriptor] = [:]
        for w in here {
            guard let bundle = apps[w.pid]?.app.bundleIdentifier, wanted.contains(bundle) else { continue }
            seen[w.id] = describe(w, frame: snap.onScreen[w.id])
        }
        let old = trees[key]
        let kept = Set(old?.windows ?? [])
        guard let tree = restore.rebuild(key, windows: seen, kept: kept, at: scheduler.now) else { return }
        trees[key] = tree
        let back = tree.windows
        for id in back {
            for (k, other) in trees where k != key { other.remove(id) }
            if !kept.contains(id) { justAdopted.insert(id) }
        }
        // The windows that were here already and have no place in the saved layout go in as new
        // windows do, and glide there. Those not on screen keep a place at the end.
        tree.focused = old?.focused
        let ids = Set(here.map(\.id))
        for w in here where kept.contains(w.id) && !tree.contains(w.id) {
            adopt(w, into: tree, key: key, visible: ids, usable: usable, gap: gap)
            justAdopted.remove(w.id)
        }
        for id in old?.windows ?? [] where !tree.contains(id) { tree.insert(id) }
        let desktop = display.spaceIndex.map { "desktop \(display.desktopOffset + $0)" } ?? "a desktop"
        Log.write("restore: \(desktop) has \(back.count) window(s) back in its saved layout\(restore.waiting.contains(key) ? "" : ", which is complete")")
    }

    /// A window the user had floated by hand before a restart of the Mac floats again when it comes back.
    func refloat(_ fresh: [WindowState], app: RunningApp) {
        guard !fresh.isEmpty, let bundle = app.bundleIdentifier, restore.mayFloat(bundle, at: scheduler.now) else { return }
        var seen: [CGWindowID: WindowDescriptor] = [:]
        // Where the window is does not matter here.
        for w in fresh where w.tileable {
            seen[w.id] = WindowDescriptor(bundleID: bundle, app: app.localizedName, title: w.element.string(kAXTitleAttribute), frame: .zero)
        }
        let count = windows.values.filter { $0.pid == app.processIdentifier && $0.tileable }.count
        for id in restore.refloat(seen, appWindows: [bundle: count], at: scheduler.now) { windows[id]?.userFloat = true }
    }
}
