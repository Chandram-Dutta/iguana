import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    var mouseIsDown: Bool { system.leftMouseIsDown }

    func frameChanged(_ element: UIElement) {
        guard !carrier.isCarrying, !paused, let id = element.windowID, let w = windows[id],
              let slot = lastFrames[id] else { return }
        // Frames reported while Iguana itself is moving the window are its own.
        if mover.isMoving(id), !mouseIsDown { return }
        guard let now = element.frame else { return }
        if let asked = w.lastSetFrame, nearlyEqual(now, asked) { return }
        if mouseIsDown, !mover.isMoving(id) {
            // The user is dragging or resizing. Leave the window alone until they let go.
            if drag == nil {
                // What the window started from is its tile, at the size it really had there: a
                // window that will not get as small as its tile is bigger than it, and that
                // difference is not the user resizing it.
                var start = slot
                if let least = w.minSize {
                    start.size.width = max(start.width, least.width)
                    start.size.height = max(start.height, least.height)
                }
                drag = (id, start, false)
                onDrag?(true)
            }
            if drag?.id == id, drag?.carried == false, let start = drag?.start, DragDrop.isMove(from: start, to: now) { drag?.carried = true }
            return
        }
        if mouseIsDown { return }
        scheduleRefresh(after: 0.1)
    }

    func mouseUp() {
        stackOrderTries = 0
        guard let d = drag else { return }
        drag = nil
        onDrag?(false)
        var wait = 0.0
        defer { scheduleRefresh(after: wait) }
        guard let w = windows[d.id], let now = w.element.frame, let (key, tree) = treeEntry(containing: d.id) else { return }
        w.lastSetFrame = nil
        let dw = now.width - d.start.width, dh = now.height - d.start.height
        // A window that was carried somewhere can come back from the drag with another size:
        // macOS's own tiling resizes a window let go at a screen edge. That is not the user
        // resizing it, so it must not change the proportions of the layout.
        if !d.carried, abs(dw) > 3 || abs(dh) > 3 {
            // Resized by hand: keep the new proportions.
            recording {
                if abs(dw) > 3 { tree.changeShare(of: d.id, along: .horizontal, .ratio(Double(now.width / d.start.width)), visible: lastVisible) }
                if abs(dh) > 3 { tree.changeShare(of: d.id, along: .vertical, .ratio(Double(now.height / d.start.height)), visible: lastVisible) }
            }
            restore.stop(key)
        } else if let cursor = system.pointerLocation,
                  // The same question the outline asked all through the drag (DragPreview.swift),
                  // so what it showed is what is done: trade places, take half of a tile, join a stack.
                  let plan = dropPlan(dragging: d.id, from: d.start, now: d.carried ? CGRect(origin: now.origin, size: d.start.size) : now, at: cursor) {
            recording { DragDrop.carryOut(plan.drop, of: d.id, in: displays.compactMap { trees[$0.treeKey] }, visible: lastVisible) }
            restore.stop(key)
            if let there = treeEntry(containing: d.id)?.0 { restore.stop(there) }
            if displayIndex(for: now) != displayIndex(for: plan.rect) {
                // Let go with most of itself on another display than the one it lands on. A
                // layout is made of the windows on its display, so the window is put there first.
                w.element.setSize(plan.rect.size)
                w.element.setPosition(plan.rect.origin)
                wait = 0.05
            }
        }
    }

    /// The window the user is dragging or resizing by hand, and the tile it started from.
    var dragging: (id: CGWindowID, start: CGRect)? { drag.map { ($0.id, $0.start) } }

    /// The tile of every tiled window on screen. A zoomed window is not on its tile, and has none here.
    var tileFrames: [CGWindowID: CGRect] { lastFrames.filter { !zoomed.values.contains($0.key) } }
}
