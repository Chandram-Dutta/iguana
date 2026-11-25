import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    func updateFocus(_ snap: ScreenSnapshot) {
        // While a focus request is still being confirmed, the request is the truth.
        guard focusIntent == nil else { return }
        var id = systemFocusedWindow()
        // An app whose key window lives on another Space still reports that window as focused.
        // What the user can act on is its frontmost window on the Space being shown.
        if let reported = id, !isShowing(reported, snap) {
            let pid = system.frontmostPID
            id = snap.order.first { windows[$0]?.pid == pid && isShowing($0, snap) }
        }
        // Nothing focused at all (the desktop was clicked, or the front app has no window here):
        // act on the window that is in front.
        if id == nil { id = snap.order.first { windows[$0] != nil && isShowing($0, snap) } }
        guard let id else {
            if let old = focusedWindow, !isShowing(old, snap) { focusedWindow = nil }
            return
        }
        focusedWindow = id
        for tree in trees.values where tree.contains(id) { tree.focused = id }
    }

    func focus(_ dir: Direction) -> String {
        let snap = system.snapshot()
        var frames: [CGWindowID: CGRect] = [:]
        for id in windows.keys { if let f = snap.onScreen[id] { frames[id] = slots[id] ?? f } }
        guard !frames.isEmpty else { return "ok: no windows here" }
        guard let current = focusedWindow, let origin = frames[current] else {
            if let front = snap.order.first(where: { frames[$0] != nil }) { focus(window: front) }
            return "ok"
        }
        // Windows in a stack overlap, so there the layout decides what is next, not the picture.
        guard let target = focusTarget(from: current, at: origin, direction: dir, among: frames,
                                       trees: displays.compactMap { trees[$0.treeKey] }, visible: lastVisible, frontToBack: snap.order) else {
            return "ok: nothing in that direction"
        }
        focus(window: target)
        return "ok"
    }

    /// Back to the window that had the focus before this one. Only a standard window on a
    /// desktop being shown counts, so this never switches desktop.
    func focusRecent() -> String {
        let snap = system.snapshot()
        guard let id = focusHistory.previous(current: focusedWindow, eligible: { id in
            // Dialogs and sheets do not count. A window that can be tiled is a standard one; one
            // that cannot may be a standard window of a fixed size, so it is asked what it is.
            guard let w = windows[id], isShowing(id, snap) else { return false }
            return w.tileable || w.element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
        }) else { return "ok: no other recent window" }
        focus(window: id)
        return "ok"
    }

    func focus(window id: CGWindowID, attempt: Int = 0, warp: Bool = true) {
        guard let w = windows[id] else {
            // The window closed while its focus was being confirmed: stop waiting for it.
            if focusIntent == id { focusIntent = nil }
            return
        }
        // The direct route can lose a race with the app. A retry goes through the app instead.
        if attempt > 0 || !system.focus(pid: w.pid, window: id) { apps[w.pid]?.app.comeForward() }
        w.element.perform(kAXRaiseAction)
        w.element.set(kAXMainAttribute, true)
        focusedWindow = id
        focusIntent = id
        for tree in trees.values where tree.contains(id) { tree.focused = id }
        if config.mouseFollowsFocus, warp, attempt == 0, let f = lastFrames[id] ?? w.element.frame {
            system.warpPointer(to: CGPoint(x: f.midX, y: f.midY))
            onPointerWarp?(CGPoint(x: f.midX, y: f.midY))
        }
        // macOS sometimes reports success and leaves the focus where it was. Check, and try again.
        scheduler.after(0.12) { [weak self] in
            guard let self, self.focusIntent == id else { return }
            if self.systemFocusedWindow() == id || attempt >= 2 {
                self.focusIntent = nil
            } else {
                self.focus(window: id, attempt: attempt + 1)
            }
        }
    }

    func focusApp(_ text: String) -> String {
        // An app's window that had the focus last is the earliest in the focus history, and
        // its recency there stands in for when it was last active.
        func lastFocused(_ pid: pid_t) -> (window: CGWindowID, at: Double)? {
            for (i, id) in focusHistory.windows.enumerated() where windows[id]?.pid == pid {
                return (id, Double(FocusHistory.limit - i))
            }
            return nil
        }
        let running = apps.keys.sorted().compactMap { pid -> FocusApp.App? in
            guard let a = apps[pid]?.app, !a.isTerminated else { return nil }
            let names = [a.localizedName, a.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0 }
            return FocusApp.App(pid: pid, bundleID: a.bundleIdentifier, names: names, lastActive: lastFocused(pid)?.at ?? 0)
        }
        guard let chosen = FocusApp.choose(text, among: running), let app = apps[chosen.pid]?.app else { return openApp(text) }
        let snap = system.snapshot()
        let showing = snap.order.filter { windows[$0]?.pid == chosen.pid && isShowing($0, snap) }
        switch FocusApp.pick(showing: showing, remembered: lastFocused(chosen.pid)?.window, focused: focusedWindow) {
        case .window(let id):
            focus(window: id)
            scheduleRefresh()
            return "ok"
        case .stay:
            return "ok"
        case .activate:
            // Every window minimised: bring the one used most recently back out of the Dock,
            // which activating alone would not do.
            let minimised = Set(windows.filter { $0.value.pid == chosen.pid && $0.value.element.bool(kAXMinimizedAttribute) == true }.keys)
            if let id = FocusApp.minimisedToBringBack(minimised, history: focusHistory.windows) {
                bringForward(id)
                scheduleRefresh()
                return "ok: brought back a minimised window"
            }
            // On another desktop or hidden: macOS knows best which window to show.
            if app.isHidden { app.unhide() }
            app.comeForward()
            return "ok: activated \(app.localizedName ?? text)"
        }
    }

    /// An app that is not running: found by its bundle id, or by the name of its bundle in
    /// the folders apps are kept in.
    func openApp(_ text: String) -> String {
        let url = system.appURL(bundleID: text) ?? {
            let paths = system.contents(ofFolders: FocusApp.folders(home: system.homeDirectory))
            return FocusApp.bundle(named: text, among: paths).map { URL(fileURLWithPath: $0) }
        }()
        guard let url else { return "error: no app called '\(text)'" }
        system.openApp(at: url) { reason in Log.write("focus-app: could not open \(url.path): \(reason)") }
        return "ok: opening \(url.deletingPathExtension().lastPathComponent)"
    }

    func systemFocusedWindow() -> CGWindowID? {
        guard let front = system.frontmostPID, let state = apps[front],
              let el = state.element.element(kAXFocusedWindowAttribute) else { return nil }
        return el.windowID
    }

    /// Bring one window forward, as a click on it in the menu bar item's menu asks.
    func focusWindow(_ id: CGWindowID) {
        guard started, system.isTrusted, windows[id] != nil else { return }
        focus(window: id)
        scheduleRefresh()
    }

    /// Focus the window the pointer rests on (`focus-follows-mouse`). The pointer is already
    /// where the user wants it, so `mouse-follows-focus` does not move it.
    func focusFromPointer(_ id: CGWindowID) {
        guard started, system.isTrusted, windows[id] != nil else { return }
        focus(window: id, warp: false)
        scheduleRefresh()
    }
}
