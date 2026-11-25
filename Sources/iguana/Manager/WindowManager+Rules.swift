import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    func matchesFloatRule(_ w: WindowState, app: RunningApp) -> Bool {
        rule(for: w, app: app)?.floats ?? false
    }

    func rule(for w: WindowState, app: RunningApp) -> Rule? {
        guard !config.rules.isEmpty else { return nil }
        let title = config.rules.contains { $0.title != nil } ? w.element.string(kAXTitleAttribute) : nil
        // The first rule that matches decides, so `float = false` can carve an exception out of a later rule.
        return config.rule(bundleID: app.bundleIdentifier, appName: app.localizedName, title: title)
    }

    /// A rule can name a desktop. A new window it matches is sent there once, exactly as
    /// `move-to-space N --stay` sends the focused window, and the user stays where they are.
    func applyDesktopRules() {
        desktopRules.settle(paused: paused, standard: ruleStandard) { id, n in
            guard let w = windows[id] else { return "error: the window is gone" }
            let front = systemFocusedWindow()
            let hadKeyboard = front == id || (front == nil && system.frontmostPID == w.pid)
            let before = focusedWindow
            let position = w.element.position
            let reply = moveToSpace(.index(n), follow: false, ruled: id)
            if reply == "ok", hadKeyboard {
                // The keyboard goes back to the window that had it before this one opened.
                let snap = system.snapshot()
                let candidates = [before].compactMap { $0 } + snap.order
                if let next = candidates.first(where: { $0 != id && windows[$0] != nil && isShowing($0, snap) }) { focus(window: next) }
            } else if reply.hasPrefix("error"), let position {
                // Aiming at a desktop on another display moves the window there first. It did not go, so put it back.
                w.element.setPosition(position)
            }
            return reply
        }
    }

    /// A rule can name a display. A new window it matches is moved there once, onto the desktop
    /// that display is showing, and the user stays on the desktop they are using.
    func applyDisplayRules() {
        displayRules.settle(paused: paused, standard: ruleStandard, displays: {
            lookAtDisplays()
            return displays
        }, location: { id in windows[id]?.element.frame.flatMap(displayIndex(for:)) }) { id, index in
            sendWindow(id, toDisplay: index)
        }
    }

    /// Whether a new window a rule waits for is a standard one yet. Nil when it is gone, or is a
    /// tab, which stays with its window.
    func ruleStandard(_ id: CGWindowID) -> Bool? {
        guard let w = windows[id] else { return nil }
        guard w.tileable, let frame = w.element.frame else { return false }
        return isTab(w, frame) ? nil : true
    }

    /// Ask every window again whether a rule floats it, as when the config is read. A window
    /// floated or tiled by hand keeps that: the user's choice wins over a rule.
    func applyFloatRules() {
        for (pid, state) in apps {
            for w in windows.values where w.pid == pid { w.ruleFloat = matchesFloatRule(w, app: state.app) }
        }
        for w in windows.values where w.floating { for tree in trees.values { tree.remove(w.id) } }
    }

    /// `apply-rules`: what the rules say, done now to the windows that are open. Otherwise a rule
    /// only sends a window as it opens. Each standard window goes to the desktop or the display
    /// its rule names, by the same routes as a new one, and the user stays where they are.
    func applyRules() -> String {
        guard !paused else { return "error: tiling is paused" }
        applyFloatRules()
        let snap = system.snapshot()
        let desktops = system.desktops()
        var moved = 0, cannotStay = false
        for w in windows.values.sorted(by: { $0.id < $1.id }) {
            guard let app = apps[w.pid]?.app, let rule = rule(for: w, app: app), rule.desktop != nil || rule.display != nil,
                  w.tileable, w.element.bool(kAXMinimizedAttribute) != true, w.element.bool("AXFullScreen") != true,
                  let frame = w.element.frame,
                  // Of the tabs of one window, the one in front stands for all of them.
                  snap.onScreen[w.id] != nil || !isTab(w, frame) else { continue }
            let window = "window \(w.id) of \(app.localizedName ?? "an app")"
            var reply = ""
            if let n = rule.desktop {
                let on = system.spaces(of: w.id)
                switch DesktopRuleAction.decide(wanted: n, standardWindow: true, windowDesktops: desktops.filter { on.contains($0.id) }.map(\.number),
                                                desktopCount: desktops.count, canStay: system.hasMoveBridge) {
                case .send:
                    let position = w.element.position
                    reply = moveToSpace(.index(n), follow: false, ruled: w.id)
                    // Aiming at a desktop on another display moves the window there first. It did not go, so put it back.
                    if reply.hasPrefix("error"), let position { w.element.setPosition(position) }
                case .missing: Log.write("apply-rules: \(window) was not sent to desktop \(n): there are only \(desktops.count) desktops")
                case .cannotStay: cannotStay = true
                case .leave: break
                }
            } else if let d = rule.display, isShowing(w.id, snap) {
                // A window on a desktop that is not being shown stays on it.
                switch DisplayRuleAction.decide(wanted: d, standardWindow: true, windowDisplay: displayIndex(for: frame),
                                                names: displays.map(\.name), frames: displays.map(\.frame)) {
                case .send(let i): reply = sendWindow(w.id, toDisplay: i)
                case .missing: Log.write("apply-rules: \(window) was not sent to display \(d): no such display is connected")
                case .leave: break
                }
            }
            if reply == "ok" { moved += 1 }
            if reply.hasPrefix("error: ") { Log.write("apply-rules: \(window) was not moved: \(reply.dropFirst(7))") }
        }
        if cannotStay { Log.write("apply-rules: this macOS can only take a window to another desktop by going there with it, so desktops in rules were not applied") }
        refresh()
        return moved == 0 ? "ok: nothing to move" : "ok: \(moved) window(s) moved"
    }
}
