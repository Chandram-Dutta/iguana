import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    func displayIndex(for rect: CGRect) -> Int? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let i = displays.firstIndex(where: { $0.frame.contains(center) }) { return i }
        var best: (Int, CGFloat)?
        for (i, d) in displays.enumerated() {
            let overlap = d.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.1 ?? 0) { best = (i, area) }
        }
        return best?.0
    }

    func move(_ dir: Direction, _ named: CGWindowID?) -> String {
        guard let w = targetWindow(named), let frame = lastFrames[w.id],
              let (key, tree) = treeEntry(containing: w.id) else { return notTiled(named) }
        let id = w.id
        restore.stop(key)
        if tree.move(id, dir, visible: lastVisible) {
            refresh()
            return "ok"
        }
        // At the edge of this display: carry on to the display in that direction, if there is one.
        guard let here = displayIndex(for: frame), let there = neighbourDisplay(of: here, dir) else {
            return "ok: already at the edge"
        }
        carry(id, w, frame, from: tree, to: there)
        return "ok"
    }

    /// Take a tiled window out of its layout and put it on another display. A layout is made of
    /// the windows on its display, so the next refresh adds it to the layout of the desktop shown
    /// there, as it adds a window that has just opened: beside the window last focused there.
    func carry(_ id: CGWindowID, _ w: WindowState, _ frame: CGRect, from tree: Tree, to display: Int) {
        let area = displays[display].usableFrame(config)
        w.element.setSize(CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height)))
        w.element.setPosition(area.origin)
        w.lastSetFrame = nil
        tree.remove(id)
        restore.stop(displays[display].treeKey)
        // The window joins the layout over there in this refresh, and that is part of the move.
        scheduler.after(0.05) { [weak self] in
            guard let self else { return }
            self.recording { self.refresh() }
        }
    }

    func neighbourDisplay(of index: Int, _ dir: Direction) -> Int? {
        var frames: [WindowID: CGRect] = [:]
        for (i, d) in displays.enumerated() { frames[WindowID(i)] = d.frame }
        return nearestWindow(from: displays[index].frame, direction: dir, among: frames, excluding: WindowID(index)).map(Int.init)
    }

    // MARK: Displays by number

    /// Where `next` and `prev` count from: the display holding the focused window, floating or
    /// tiled, so that a display with only floating windows on it cannot hold on to the focus.
    var displayWithFocus: Int? {
        if let id = focusedWindow, let w = windows[id], let f = lastFrames[id] ?? w.element.frame, let i = displayIndex(for: f) { return i }
        return activeDisplay.flatMap { a in displays.firstIndex { $0.uuid == a.uuid } }
    }

    /// The display a command names, as an index into `displays`, and its number.
    func display(_ target: DisplayTarget, from here: Int?) -> Result<(index: Int, number: Int), DisplayTarget.Refusal> {
        let order = displays.enumerated().sorted { $0.element.number < $1.element.number }.map(\.offset)
        return target.resolve(active: here.flatMap { order.firstIndex(of: $0) }, count: order.count).map { (order[$0], $0 + 1) }
    }

    func focusDisplay(_ target: DisplayTarget) -> String {
        let there: Int
        switch display(target, from: displayWithFocus) {
        case .failure(let refusal): return refusal.reply
        case .success(let found): there = found.index
        }
        let d = displays[there]
        let snap = system.snapshot()
        let tree = trees[d.treeKey]
        var tiles: [CGWindowID: CGRect] = [:]
        for id in tree?.windows ?? [] where snap.onScreen[id] != nil { tiles[id] = lastFrames[id] }
        let others = snap.order.filter { id in
            guard tiles[id] == nil, windows[id] != nil, isShowing(id, snap), let f = snap.onScreen[id] else { return false }
            return displayIndex(for: f) == there
        }
        let usable = d.usableFrame(config)
        let centre = CGPoint(x: usable.midX, y: usable.midY)
        guard let id = DisplayTarget.windowToFocus(remembered: tree?.focused, tiles: tiles, others: others, centre: centre) else {
            if config.mouseFollowsFocus {
                system.warpPointer(to: centre)
                onPointerWarp?(centre)
            }
            return "ok: no window on that display"
        }
        focus(window: id)
        return "ok"
    }

    /// The focus stays with the window, wherever it goes. A window `move-to-display` names with
    /// `--window` is taken instead of the focused one, and the focus stays where it is.
    func moveToDisplay(_ target: DisplayTarget, _ named: CGWindowID? = nil) -> String {
        guard let w = targetWindow(named) else { return "error: no focused window" }
        let id = w.id
        let tile = lastFrames[id]
        guard let frame = tile ?? w.element.frame, let here = displayIndex(for: frame) else { return "error: cannot read the window's position" }
        guard displays[here].isDesktop else { return "error: a fullscreen window cannot be sent to another display" }
        let there: Int, number: Int
        switch display(target, from: here) {
        case .failure(let refusal): return refusal.reply
        case .success(let found): (there, number) = found
        }
        guard there != here else { return "ok: already on display \(number)" }
        guard displays[there].isDesktop else { return "error: display \(number) is showing a fullscreen app" }
        if let tile, let (key, tree) = treeEntry(containing: id) {
            restore.stop(key)
            restore.stop(displays[there].treeKey)
            carry(id, w, tile, from: tree, to: there)
        } else {
            let f = DisplayTarget.floatingFrame(frame, from: displays[here].usableFrame(config), to: displays[there].usableFrame(config))
            if f.size != frame.size { w.element.setSize(f.size) }
            w.element.setPosition(f.origin)
            scheduleRefresh(after: 0.05)
        }
        return "ok"
    }

    /// Put a window on another display, onto the desktop that display is showing, as `move`
    /// carries one across at the edge. A tiled window joins the layout there beside the window
    /// focused in it, as a new window would. A floating one keeps its size, as far as it fits, and
    /// is centred. The desktop being used and the focus stay as they are.
    func sendWindow(_ id: CGWindowID, toDisplay index: Int) -> String {
        guard let w = windows[id] else { return "error: the window is gone" }
        guard displays.indices.contains(index) else { return "error: no such display" }
        guard displays[index].isDesktop else { return "error: that display is showing a fullscreen Space" }
        guard let frame = w.element.frame else { return "error: cannot read the window's position" }
        let area = displays[index].usableFrame(config)
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        mover.cancel(id)
        for tree in trees.values { tree.remove(id) }
        w.element.setSize(size)
        w.element.setPosition(CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        w.lastSetFrame = nil
        // The window server reports the move a moment later. A layout that runs before it shows
        // must not adopt the window where it still is, so it is kept out until the poll sees it
        // on the target display or gives up.
        inTransit[id] = (display: index, deadline: scheduler.now.addingTimeInterval(0.3))
        pollTransit(id, number: displays[index].number)
        scheduleRefresh(after: 0.1)
        return "ok"
    }

    /// Look again in a moment whether the window reached its display; give up after the deadline.
    /// `number` is the display's number from left to right, as a rule and every other line of
    /// the log name it. It is taken when the window is sent, as the displays can change meanwhile.
    func pollTransit(_ id: CGWindowID, number: Int) {
        scheduler.after(0.02) { [weak self] in
            guard let self, let transit = inTransit[id] else { return }
            let arrived = system.serverOrigin(of: id).map { origin in
                self.windows[id].flatMap { w in w.element.frame.map { self.displayIndex(for: CGRect(origin: origin, size: $0.size)) } } == transit.display
            } ?? false
            if arrived || scheduler.now >= transit.deadline {
                inTransit[id] = nil
                if !arrived { Log.write("rule: window \(id) did not move to display \(number)") }
                scheduleRefresh()
            } else {
                pollTransit(id, number: number)
            }
        }
    }
}
