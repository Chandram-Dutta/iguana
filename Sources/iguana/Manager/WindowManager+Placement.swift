import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    // MARK: Placing floating windows

    /// `place`: put the window it acts on in a part of its display's area.
    func place(_ placement: Placement, _ named: CGWindowID? = nil) -> String {
        guard let w = targetWindow(named) else { return "error: no focused window" }
        let id = w.id
        guard w.element.isSettable(kAXPositionAttribute) else { return "error: this window cannot be moved" }
        guard let display = display(holding: w) ?? activeDisplay else { return "error: no display" }
        guard display.isDesktop else { return "error: a fullscreen window cannot be placed" }
        // A tiled window is floated first, as `float` does.
        let floated = w.tileable && !w.floating
        if floated {
            if let key = treeEntry(containing: id)?.0 { restore.stop(key) }
            w.userFloat = true
            for tree in trees.values { tree.remove(id) }
            refresh()
        }
        guard let frame = mover.destination(of: id) ?? w.element.frame else { return "error: cannot read the window's position" }
        let area = display.usableFrame(config)
        let target = placement.frame(in: area, gap: display.settings(config).inner, size: frame.size)
        place(w, at: target, glide: true) { placement.fit($0, to: target, in: area) }
        return floated ? "ok: floating" : "ok"
    }

    /// Take a window that is in no layout to `target`. It glides there as tiled windows do, unless
    /// `glide` is false or the move is tiny. `fit` says where the window goes if it will not take the size.
    func place(_ w: WindowState, at target: CGRect, glide: Bool, fit: @escaping (CGSize) -> CGRect) {
        let current = w.element.frame ?? target
        let change = max(abs(current.minX - target.minX), abs(current.minY - target.minY),
                         abs(current.width - target.width), abs(current.height - target.height))
        let glides = glide && config.animate && !system.reduceMotion && change > 12
        placing[w.id] = (target, fit)
        mover.move(w.id, pid: w.pid, element: w.element, app: apps[w.pid]?.element,
                      from: current, to: target, duration: glides ? config.animationDuration : 0, easing: config.animationEasing)
    }

    /// A placed window has been given its frame. One that did not take the size (a minimum, a
    /// fixed size) is moved to where `fit` puts it at the size it has. A busy window can answer
    /// with the size it had before, so it is asked once more and looked at again a moment later.
    ///
    /// Only a window that is in no layout is touched: one that floats, or one that cannot be
    /// tiled, which `place` takes as it is and no rule need float. A tiled window belongs to
    /// its tile, and it can have become one since it was placed.
    func placedLanded(_ id: CGWindowID, asked: CGRect, actual: CGSize?, fit: @escaping (CGSize) -> CGRect) {
        func refused(_ size: CGSize) -> Bool { abs(size.width - asked.width) > 2 || abs(size.height - asked.height) > 2 }
        func untiled(_ w: WindowState) -> Bool { w.floating || !w.tileable }
        guard let w = windows[id], untiled(w), actual.map(refused) != false else { return }
        w.element.setSize(asked.size)
        scheduler.after(0.15) { [weak self] in
            // Unless something has moved the window since: the user, another placement, or a layout it joined.
            guard let self, self.placing[id] == nil, !self.mover.isMoving(id), self.windows[id].map(untiled) == true,
                  let now = w.element.frame, abs(now.minX - asked.minX) <= 2, abs(now.minY - asked.minY) <= 2, refused(now.size) else { return }
            w.element.setPosition(fit(now.size).origin)
        }
    }

    /// A rule can give the windows it floats a size and a position. A new window it matches is
    /// placed once, when it opens, at once rather than gliding: like a window that joins a layout.
    func applyPlacementRules() {
        guard placementRules.hasLooked else { return placementRules.firstLook(existing: system.snapshot().all) }
        let due = placementRules.due(at: scheduler.now, paused: paused) { id in
            guard let w = windows[id], w.floating else { return nil }
            // A window that cannot be resized is still placed; one that cannot be moved is not.
            guard w.tileable || isMovableStandardWindow(w.element), let frame = w.element.frame else { return false }
            return isTab(w, frame) ? nil : true
        }
        guard !due.isEmpty else { return }
        lookAtDisplays()
        for entry in due {
            guard let w = windows[entry.window], let frame = w.element.frame, let display = display(holding: w), display.isDesktop else { continue }
            let area = display.usableFrame(config)
            guard let target = entry.rule.frame(for: frame, in: area, gap: display.settings(config).inner) else { continue }
            place(w, at: target, glide: false) { entry.rule.fit($0, to: target, in: area) }
            Log.write("rule: placed window \(entry.window) of \(entry.app)")
        }
    }

    func isMovableStandardWindow(_ el: UIElement) -> Bool {
        el.string(kAXRoleAttribute) == kAXWindowRole && el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && el.isSettable(kAXPositionAttribute)
    }
}
