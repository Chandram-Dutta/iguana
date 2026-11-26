import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    // MARK: Native Spaces

    var activeDisplay: DisplayInfo? {
        if let id = focusedWindow, let f = lastFrames[id], let i = displayIndex(for: f) { return displays[i] }
        if let p = system.pointerLocation, let d = displays.first(where: { $0.frame.contains(p) }) { return d }
        return displays.first { $0.isMain } ?? displays.first
    }

    func shortcut(for target: SpaceTarget) -> (id: Int32?, message: String) {
        lookAtDisplays()
        guard let d = activeDisplay else { return (nil, "error: no display") }
        switch target {
        case .next: return (Private.SystemShortcut.spaceRight, "ok")
        case .prev: return (Private.SystemShortcut.spaceLeft, "ok")
        case .recent:
            guard let desktop = recentDesktop(on: d) else { return (nil, "ok: no previous desktop") }
            return (Private.SystemShortcut.desktop(desktop.number), "ok")
        case .index(let n):
            // Desktops are numbered across all displays, exactly as Mission Control names them.
            let total = d.totalDesktops
            guard n <= total else { return (nil, "error: there are only \(total) desktops") }
            if let i = d.spaceIndex, d.desktopOffset + i == n { return (nil, "ok: already on desktop \(n)") }
            return (Private.SystemShortcut.desktop(n), "ok")
        }
    }

    /// Remembered for `space recent`, however the desktop changed. A fullscreen Space is not a
    /// desktop and is left out.
    func noteDesktops() {
        for d in displays where d.isDesktop { desktopHistory.record(display: d.uuid, space: d.spaceID) }
    }

    /// The desktop `display` showed before the one it shows now, while that desktop still exists.
    /// It is found by its Space id and gets its number now, as numbers shift when desktops come and go.
    func recentDesktop(on display: DisplayInfo) -> Desktop? {
        noteDesktops()
        guard let id = desktopHistory.previous(display: display.uuid, showing: display.spaceID) else { return nil }
        return system.desktops().first { $0.id == id }
    }

    func switchSpace(_ target: SpaceTarget) -> String {
        let (id, message) = shortcut(for: target)
        guard let id else { return message }
        return system.press(shortcut: id) ? "ok" : "error: could not trigger the system shortcut"
    }

    /// `ruled` is the window a rule sends, in place of the focused one. It starts from the display
    /// it is on, and it is never carried across by hand, because that takes the user along.
    /// `named` is a window a request named with `--window`. It starts from where it is too, which
    /// can be a desktop that is not being shown, and takes the keyboard along only if it has it.
    func moveToSpace(_ target: SpaceTarget, follow: Bool, window named: CGWindowID? = nil, ruled: CGWindowID? = nil) -> String {
        guard let id = ruled ?? targetWindow(named)?.id, let w = windows[id] else { return "error: no focused window" }
        guard !carrier.isCarrying else { return "error: a move is already in progress" }
        lookAtDisplays()
        guard let here = (ruled == nil && named == nil ? nil : display(holding: w)) ?? activeDisplay else { return "error: no display" }
        let desktops = system.desktops()
        let on = system.spaces(of: id)
        // The desktop the window is on. Only a named or ruled window can be on one that is not being shown.
        let spaces = (named == nil && ruled == nil) ? [] : on
        let from = spaces.isEmpty || spaces.contains(here.spaceID) ? here.spaceID : spaces[0]
        guard from == here.spaceID ? here.isDesktop : desktops.contains(where: { $0.id == from }) else {
            return "error: a fullscreen window cannot be sent to another desktop"
        }

        let destination: Desktop
        switch target {
        case .index(let n):
            guard n <= desktops.count else { return "error: there are only \(desktops.count) desktops" }
            destination = desktops[n - 1]
        case .next, .prev:
            let onThisDisplay = desktops.filter { $0.displayID == here.managedID }
            guard let i = onThisDisplay.firstIndex(where: { $0.id == from }) else { return "error: cannot tell which desktop is showing" }
            let j = target == .next ? i + 1 : i - 1
            guard onThisDisplay.indices.contains(j) else { return "ok: no desktop in that direction" }
            destination = onThisDisplay[j]
        case .recent:
            guard let previous = recentDesktop(on: here) else { return "ok: no previous desktop" }
            destination = previous
        }
        // A window assigned to all desktops is on the destination already, whichever way it was named.
        guard destination.id != from, !(on.count > 1 && on.contains(destination.id)) else {
            return "ok: already on desktop \(destination.number)"
        }
        if ruled == nil { restore.stop(treeEntry(containing: id)?.0 ?? here.treeKey) }

        // A window has to sit on the display its Space belongs to.
        if destination.displayID != here.managedID, let there = displays.first(where: { $0.managedID == destination.displayID }) {
            w.element.setPosition(there.usableFrame(config).origin)
        }

        // The quick way: ask the system's window-management bridge. It takes a few milliseconds
        // and does not switch Space.
        let oldSlot = slots[id]
        if system.requestMove(window: id, toSpace: destination.id), arrived(id, on: destination.id) {
            for tree in trees.values { tree.remove(id) }
            // The window joins the destination's layout when that Space is next on screen, by the
            // same rule as a newly opened window: it splits the window that was last focused there.
            w.lastSetFrame = nil
            if follow, destination.id == here.spaceID {
                // Brought to the desktop being shown, so there is no desktop to go to.
                focus(window: id)
            } else if follow {
                // The desktop may belong to another display, so it is the one waited for: this
                // display does not leave its own then.
                _ = system.press(shortcut: Private.SystemShortcut.desktop(destination.number))
                carrier.whenSpaceShows(destination.id, timeout: 3) { [weak self] _ in self?.focus(window: id) }
            } else if ruled == nil, id == focusedWindow {
                // Hand the keyboard to the window that is left nearest to where this one was.
                // A ruled window leaves it alone: applyDesktopRules gives it back itself.
                let remaining = slots.filter { $0.key != id }
                if let oldSlot, let next = remaining.min(by: { distance($0.value, oldSlot) < distance($1.value, oldSlot) })?.key {
                    focus(window: next)
                }
            }
            // A rule's window is sent from inside a refresh, which lays out when this returns.
            if ruled == nil { refresh() }
            return "ok"
        }
        // Carrying it by hand needs it on screen.
        guard ruled == nil, named == nil || isShowing(id, system.snapshot()) else { return "error: the system did not move the window" }

        // Older systems, or a window the bridge refuses: carry it across by hand. This always
        // ends on the destination desktop.
        Log.write("move-to-space: the quick route did not move window \(id), falling back to dragging it")
        guard let frame = w.element.frame else { return "error: cannot read the window's position" }
        carrier.carry(id, w.element, frame, shortcutID: Private.SystemShortcut.desktop(destination.number), to: destination.id) { [weak self] in
            guard let self else { return }
            self.windows[id]?.lastSetFrame = nil
            self.allDirty = true
            self.scheduleRefresh(after: 0.1)
        }
        return "ok"
    }

    func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }

    /// The bridge answers asynchronously, normally within 20 ms.
    func arrived(_ id: CGWindowID, on space: UInt64) -> Bool {
        let deadline = scheduler.now.addingTimeInterval(0.4)
        repeat {
            if system.spaces(of: id).contains(space) { return true }
            scheduler.sleep(0.004)
        } while scheduler.now < deadline
        return false
    }
}
