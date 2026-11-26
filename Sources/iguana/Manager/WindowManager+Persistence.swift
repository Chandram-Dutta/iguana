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
            restore = RestoreSession(trees: saved.trees, floating: saved.floating, tiled: saved.tiled ?? [], windows: described, from: scheduler.now)
            if !restore.waiting.isEmpty {
                Log.write("restore: the Mac has restarted; for \(Int(RestoreSession.gracePeriod / 60)) minutes, windows that come back take their places in \(restore.waiting.count) saved layout(s)")
            }
            return
        }
        savedWindows = described
        for (key, snapshot) in saved.trees { trees[key] = Tree(snapshot: snapshot) }
        restoredFloating = Set(saved.floating)
        restoredTiled = Set(saved.tiled ?? [])
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
        // What the last run kept for a window that this run has not seen yet stays in the file
        // for as long as the window exists: its app may only be too busy to say what windows it
        // has. Until the screen has been looked at once, no window is known to be gone.
        let existing = lastExisting
        let waits = { (id: CGWindowID) in existing.isEmpty || existing.contains(id) }
        var mins: [String: [Double]] = [:]
        for (id, m) in restoredMinSizes where waits(id) { mins["\(id)"] = [Double(m.width), Double(m.height)] }
        for w in windows.values { if let m = w.minSize { mins["\(w.id)"] = [Double(m.width), Double(m.height)] } }
        let floating = (windows.values.filter { $0.userFloat == true }.map(\.id) + restoredFloating.filter(waits)).sorted()
        let tiled = (windows.values.filter { $0.userFloat == false }.map(\.id) + restoredTiled.filter(waits)).sorted()
        // A window that is not on screen is kept as it was last seen, without asking its app.
        // A floating window has no tile to show that it is on screen, so the window server says.
        var described: [CGWindowID: WindowDescriptor] = [:]
        var snap: ScreenSnapshot?
        for id in Set(trees.values.flatMap(\.windows) + floating + tiled) {
            var ask = lastVisible.contains(id) || savedWindows[id] == nil
            if !ask, windows[id]?.floating == true {
                let screen = snap ?? system.snapshot()
                snap = screen
                ask = isShowing(id, screen)
            }
            described[id] = (ask ? windows[id].flatMap { describe($0, frame: lastFrames[id]) } : nil) ?? savedWindows[id]
        }
        savedWindows = described
        store.save(SavedState(boot: store.bootTime(), trees: snapshots, floating: floating, tiled: tiled, minSizes: mins,
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

    /// A window the user had floated by hand before a restart of the Mac floats again when it
    /// comes back, and one that was tiled by hand is tiled again where a rule would float it.
    func refloat(_ fresh: [WindowState], app: RunningApp) {
        guard !fresh.isEmpty, let bundle = app.bundleIdentifier else { return }
        // Where the window is does not matter here.
        func seen(floatedByRule: Bool) -> [CGWindowID: WindowDescriptor] {
            var seen: [CGWindowID: WindowDescriptor] = [:]
            for w in fresh where w.tileable && w.ruleFloat == floatedByRule {
                seen[w.id] = WindowDescriptor(bundleID: bundle, app: app.localizedName, title: w.element.string(kAXTitleAttribute), frame: .zero)
            }
            return seen
        }
        if restore.mayFloat(bundle, at: scheduler.now) {
            // A window that a rule floats is in the saved layouts only if the user had tiled it,
            // so it is neither looked at nor counted here. Looked at, it could take the place of
            // the window that was floated by hand; counted, it would keep the app's only saved
            // window from being known by anything but its title.
            let count = windows.values.filter { $0.pid == app.processIdentifier && $0.tileable && !$0.ruleFloat }.count
            for id in restore.refloat(seen(floatedByRule: false), appWindows: [bundle: count], at: scheduler.now) { windows[id]?.userFloat = true }
        }
        if restore.mayTile(bundle, at: scheduler.now) {
            for id in restore.retile(seen(floatedByRule: true), at: scheduler.now) { windows[id]?.userFloat = false }
        }
    }
}
