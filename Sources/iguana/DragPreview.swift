import AppKit
import ApplicationServices
import IguanaCore

/// The ordinary windows on screen, front to back, as the window server has them. One call,
/// and no permission needed.
struct WindowsOnScreen {
    var order: [CGWindowID] = []
    /// Measured from the top-left corner of the primary display.
    var frames: [CGWindowID: CGRect] = [:]

    static func take() -> WindowsOnScreen {
        var list = WindowsOnScreen()
        for info in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            list.order.append(id)
            list.frames[id] = frame
        }
        return list
    }
}

extension WindowManager {
    /// What letting go of a dragged tile would do with the pointer at `pointer`, and where the
    /// window would land. Nil when it would do nothing.
    ///
    /// The outline drawn during a drag and the drop at the end of it both ask this, and the
    /// deciding is done in IguanaCore (`DragDrop.plan`). This gathers what it decides on.
    ///
    /// - `start`: the tile the window was on when the drag began. `now`: where the window is.
    func dropPlan(dragging id: CGWindowID, from start: CGRect, now: CGRect, at pointer: CGPoint, onScreen: WindowsOnScreen? = nil) -> DropPlan? {
        // Nothing while tiling is paused, nothing for an edge being dragged (a resize), and
        // nothing for a window that has no tile: a floating one, or one that is zoomed.
        guard !paused, DragDrop.isMove(from: start, to: now) else { return nil }
        let tiles = tileFrames
        guard tiles[id] != nil else { return nil }
        let facts = facts()
        let onScreen = onScreen ?? .take()

        // A window Iguana knows that is on screen without a tile lies over the tiles: a
        // floating window, a dialog, a zoomed window. So does a window of Iguana's own, unless
        // it lets clicks through, as the focus ring and this outline do.
        var blockers: [CGWindowID: CGRect] = [:]
        for other in facts.windows.keys where tiles[other] == nil { blockers[other] = onScreen.frames[other] }
        for window in NSApp?.windows ?? [] where window.isVisible && !window.ignoresMouseEvents {
            // Not every window of an app has a number the window server knows: the menu bar
            // item's window is kept by another process and reports one that does not fit.
            guard window.windowNumber > 0, let number = CGWindowID(exactly: window.windowNumber) else { continue }
            blockers[number] = onScreen.frames[number]
        }
        var minSizes: [CGWindowID: CGSize] = [:]
        for (other, w) in facts.windows { if let size = w.minSize { minSizes[other] = size } }
        let desks = displays.compactMap { display in
            facts.trees[display.treeKey].map { DropScene.Desk(tree: $0, area: display.usableFrame(config)) }
        }
        return DragDrop.plan(DropScene(
            dragged: id, pointer: pointer, tiles: tiles, blockers: blockers, frontToBack: onScreen.order, desks: desks,
            visible: facts.visible, gap: config.gapInner, peek: config.stackPeek, minSizes: minSizes))
    }
}

/// Shows where a tiled window that is being dragged will land: an outline with a faint fill,
/// in the accent colour, over the place the window takes if it is let go right now.
///
/// It costs nothing until a drag begins. The window manager says when one does (`onDrag`), and
/// only then is the pointer listened to; the monitor is removed again when the drag ends.
///
/// What a drop does is decided in IguanaCore (`DragDrop.plan`), through the same
/// `WindowManager.dropPlan` that the drop itself asks. The drawing is `OutlineOverlay`.
final class DragPreview {
    private static let cornerRadius = WindowCorners.radius(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    private static let lineWidth: CGFloat = 2
    /// Enough to see the place, little enough to see the windows under it.
    private static let fillOpacity: CGFloat = 0.14
    /// The outline only changes when the pointer crosses into another part of a tile, so
    /// thirty looks a second are plenty, as they are for the focus ring.
    private static let pace = 1.0 / 30

    private weak var wm: WindowManager?
    /// Made the first time an outline is drawn.
    private var overlay: OutlineOverlay?
    private var monitor: Any?
    /// A drag is in progress.
    private var active = false
    /// When the last look was taken, on the clock of `ProcessInfo.systemUptime`.
    private var lastLook: TimeInterval = 0
    /// A look is already due, so that a stream of events starts one timer and not hundreds.
    private var waiting = false
    /// The display the outline was put on screen on, and the desktops that were showing then.
    private var shown: (display: Int?, spaces: [UInt64])?

    /// Whether the pointer is being followed. Only while a window is being dragged.
    var isTracking: Bool { active }
    /// Whether the event monitor is installed. Never outside a drag.
    var hasMonitor: Bool { monitor != nil }

    /// The window manager saw a drag begin, or end.
    func drag(_ on: Bool, _ wm: WindowManager) {
        self.wm = wm
        guard on != active else { return }
        active = on
        if on {
            // The events of a drag go to the app whose window it is, so they arrive through
            // the global monitor. The button coming up is listened for as well, so that the
            // outline is gone at once and never waits for anything else.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                if event.type == .leftMouseUp { self?.hide() } else { self?.pointerMoved() }
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            hide()
        }
    }

    /// A window says it moved or changed size. While one is being dragged that is another
    /// sign that the pointer has moved, should the mouse events not arrive.
    func moved() {
        if active { pointerMoved() }
    }

    /// The window manager has looked at the screen again. The layout may be another one now,
    /// and so may the desktop: a window can be carried to the next one in the middle of a drag.
    func changed(_ wm: WindowManager) {
        self.wm = wm
        if active { look() }
    }

    /// Runs for every movement of the mouse during a drag, so it does next to nothing.
    private func pointerMoved() {
        guard active, !waiting else { return }
        let since = ProcessInfo.processInfo.systemUptime - lastLook
        if since >= Self.pace { return look() }
        waiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.pace - since)) { [weak self] in
            self?.waiting = false
            self?.look()
        }
    }

    private func look() {
        lastLook = ProcessInfo.processInfo.systemUptime
        // The button is asked about as well: the look that was waiting may come after it went up.
        guard active, let wm, let drag = wm.dragging, CGEventSource.buttonState(.combinedSessionState, button: .left),
              let pointer = CGEvent(source: nil)?.location else { return hide() }
        let onScreen = WindowsOnScreen.take()
        guard let frame = onScreen.frames[drag.id],
              let plan = wm.dropPlan(dragging: drag.id, from: drag.start, now: frame, at: pointer, onScreen: onScreen) else { return hide() }

        let overlay = self.overlay ?? OutlineOverlay()
        self.overlay = overlay
        let accent = NSColor.controlAccentColor
        overlay.draw(DragDrop.outline(for: plan.rect, lineWidth: Self.lineWidth, cornerRadius: Self.cornerRadius),
                     color: accent, fill: accent.withAlphaComponent(Self.fillOpacity))
        // A window belongs to the desktop it was put on screen on, so on another display or
        // another desktop the outline is taken off and put on screen again.
        let place = (FocusRingPlan.screen(for: plan.rect, among: wm.displays.map(\.frame)), wm.displays.map(\.spaceID))
        if overlay.isShown, let shown, shown != place { overlay.hide() }
        if !overlay.isShown {
            // Above the tiles and under the window in hand. A window dragged with command held
            // stays behind the others; under it the outline could not be seen, so it goes in front.
            let known = wm.facts().windows
            if onScreen.order.first(where: { known[$0] != nil }) == drag.id {
                overlay.order(below: drag.id)
            } else {
                overlay.order(above: nil)
            }
        }
        shown = place
    }

    private func hide() {
        overlay?.hide()
        shown = nil
    }
}
