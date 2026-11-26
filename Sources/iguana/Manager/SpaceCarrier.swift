import ApplicationServices
import CoreGraphics
import Foundation

/// Carries a window to another Space by hand.
///
/// macOS has no supported way to send another app's window to a Space. Before the system's
/// window-management bridge existed, what worked without turning off System Integrity
/// Protection is what a person does by hand: hold the window by its title bar and switch
/// Space. This is that, for the systems and the windows the bridge does not serve.
final class SpaceCarrier {
    private let system: WindowSystem
    private let scheduler: Scheduler

    /// A window is being carried. The frames it reports on the way are not the user's doing,
    /// and a second window must wait.
    private(set) var isCarrying = false

    init(system: WindowSystem, scheduler: Scheduler) {
        self.system = system
        self.scheduler = scheduler
    }

    /// Hold the window by its title bar, press the shortcut that switches Space, and let go
    /// when the switch is over. `destination` is the Space the shortcut goes to. `done` is
    /// called once the button is up again, whether or not the window went.
    func carry(_ id: CGWindowID, _ element: UIElement, _ frame: CGRect, shortcutID: Int32, to destination: UInt64, done: @escaping () -> Void) {
        // The mouse takes hold of whatever is in front at the spot it is pressed on, and a
        // window named by its id need not be that.
        element.perform(kAXRaiseAction)
        let points = grabPoints(element, frame)
        let cursor = system.pointerLocation
        isCarrying = true
        let system = self.system, scheduler = self.scheduler
        let finish: (String?) -> Void = { [weak self] problem in
            if let cursor { system.warpPointer(to: cursor) }
            if let problem { Log.write("move-to-space: \(problem)") }
            guard let self else { return }
            self.isCarrying = false
            done()
        }

        grab(id, at: points[...]) { [weak self] held in
            guard let self else { return }
            // Only switch Space once the window is really following the cursor.
            guard let held else { return finish("could not take hold of window \(id) by its title bar, so it stays where it is") }
            // If the desktop is not going to change, let go at once rather than hold the button.
            guard system.press(shortcut: shortcutID) else {
                system.postMouse(.leftMouseUp, at: held)
                return finish("could not trigger the system shortcut, so window \(id) stays where it is")
            }
            let pressed = scheduler.now
            self.whenSpaceShows(destination, timeout: 8) { shown in
                guard shown else {
                    system.postMouse(.leftMouseUp, at: held)
                    return finish("the desktop did not change, so window \(id) stays where it is")
                }
                // The Space id flips part-way through the system's animation. Hold on for the rest
                // of it, scaled to how long the first part took: with Shift held (as in the default
                // shortcut) macOS may play the transition in slow motion.
                let rest = max(0.6, 3 * scheduler.now.timeIntervalSince(pressed))
                scheduler.after(rest) {
                    system.postMouse(.leftMouseUp, at: held)
                    finish(nil)
                    scheduler.after(0.5) {
                        let showing = system.displays().map(\.spaceID)
                        if !system.spaces(of: id).contains(where: { showing.contains($0) }) {
                            Log.write("move-to-space: window \(id) did not come along to the new Space")
                        }
                    }
                }
            }
        }
    }

    /// Call `body` with true as soon as a display shows `space`, or with false when none does
    /// after `timeout` seconds.
    ///
    /// The Space to watch is the one being gone to, not the one being left. A shortcut for a
    /// desktop of another display changes that display, and the display the window started on
    /// goes on showing what it showed. A desktop another display shows already is there at once.
    func whenSpaceShows(_ space: UInt64, timeout: TimeInterval, _ body: @escaping (Bool) -> Void) {
        if system.displays().contains(where: { $0.spaceID == space }) { return body(true) }
        guard timeout > 0 else { return body(false) }
        scheduler.after(0.05) { [weak self] in
            self?.whenSpaceShows(space, timeout: timeout - 0.05, body)
        }
    }

    /// Spots to hold a window by, safest first. Apps that draw their own title bar put buttons
    /// in it, so the usual "just right of the traffic lights" is not safe everywhere.
    private func grabPoints(_ element: UIElement, _ frame: CGRect) -> [CGPoint] {
        let close = element.element(kAXCloseButtonAttribute)?.frame
        let mini = element.element(kAXMinimizeButtonAttribute)?.frame
        let zoom = element.element(kAXZoomButtonAttribute)?.frame
        var points: [CGPoint] = []
        // The gaps between the traffic lights belong to the title bar and never hold a control.
        if let close, let mini, mini.minX - close.maxX >= 3 { points.append(CGPoint(x: (close.maxX + mini.minX) / 2, y: close.midY)) }
        if let mini, let zoom, zoom.minX - mini.maxX >= 3 { points.append(CGPoint(x: (mini.maxX + zoom.minX) / 2, y: mini.midY)) }
        points.append(CGPoint(x: frame.midX, y: frame.minY + 6))
        if let zoom { points.append(CGPoint(x: zoom.maxX + 10, y: zoom.midY)) }
        points.append(CGPoint(x: frame.minX + 100, y: frame.minY + 14))
        return points
    }

    /// Press the mouse on the first spot that makes the window follow the cursor. Calls back with
    /// the point the button is held at, or nil when no spot worked (the button is up again then).
    private func grab(_ id: CGWindowID, at points: ArraySlice<CGPoint>, _ done: @escaping (CGPoint?) -> Void) {
        guard let p = points.first, let start = system.serverOrigin(of: id) else { return done(nil) }
        system.postMouse(.mouseMoved, at: p)
        system.postMouse(.leftMouseDown, at: p)
        for k in 1...4 {
            scheduler.after(0.02 * Double(k)) { [system] in
                system.postMouse(.leftMouseDragged, at: CGPoint(x: p.x + CGFloat(2 * k), y: p.y + CGFloat(2 * k)))
            }
        }
        scheduler.after(0.2) { [weak self, system, scheduler] in
            if let now = system.serverOrigin(of: id), abs(now.x - start.x) + abs(now.y - start.y) >= 3 {
                return done(CGPoint(x: p.x + 8, y: p.y + 8))
            }
            // Not a spot the window can be dragged by. Let go well away from it so nothing is
            // clicked, then try the next one.
            let away = CGPoint(x: p.x + 60, y: p.y + 60)
            system.postMouse(.leftMouseDragged, at: away)
            system.postMouse(.leftMouseUp, at: away)
            scheduler.after(0.08) { self?.grab(id, at: points.dropFirst(), done) }
        }
    }
}
