import AppKit
import ApplicationServices
import IguanaCore

extension RingColor {
    var nsColor: NSColor {
        switch self {
        case .accent: return .controlAccentColor
        case .custom(let red, let green, let blue, let alpha): return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }
}

/// Draws the ring of `[focus-ring]` around the window that has the focus.
///
/// Like `Hooks`, it only observes. `changed` is called after every refresh of the window
/// manager, by the same `onChange` that redraws the menu bar item, so it hears of a new focus,
/// a new layout, another desktop, a pause and a changed setting. `moved` is called when a
/// window says it moved, which is all there is to go by while the user drags one.
///
/// Where the ring goes is decided in IguanaCore (`FocusRingPlan`, `FocusRingTracker`); the
/// drawing is `OutlineOverlay`. This file gathers the facts and passes them on.
///
/// "The window that has the focus" is the window manager's: the one its commands act on. With
/// the desktop clicked, or a window of Iguana's own in front, that is still the window in front.
final class FocusRing {
    private static let cornerRadius = WindowCorners.radius(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

    private weak var wm: WindowManager?
    /// Made the first time a ring is drawn, so that it costs nothing while the setting is off.
    private var overlay: OutlineOverlay?
    private var tracker = FocusRingTracker()
    /// The window being followed, to pick its own notifications out of everybody's.
    private var watched: (id: CGWindowID, element: UIElement)?
    /// The window the ring is around, and the Space it was put on screen on.
    private var shown: (id: CGWindowID, space: UInt64)?
    /// The last window that was asked whether it is a standard one, and was.
    private var knownStandard: CGWindowID?
    /// Runs only while the window is on its way somewhere.
    private var timer: Timer?

    func changed(_ wm: WindowManager) {
        self.wm = wm
        // The order of the windows may have changed as well, so the ring is put back in its place.
        update(reorder: true)
    }

    func moved(_ element: UIElement) {
        guard let watched, element.isSame(as: watched.element) else { return }
        update(reorder: false)
    }

    private func update(reorder: Bool) {
        guard let wm else { return }
        let settings = wm.config.focusRing
        guard settings.enabled, let id = wm.focusedWindow, let w = wm.facts().windows[id], isStandard(w),
              let frame = Self.frameOnScreen(id),
              let index = FocusRingPlan.screen(for: frame, among: wm.displays.map(\.frame)) else { return clear() }
        let display = wm.displays[index]
        func outline(around frame: CGRect) -> Outline? {
            FocusRingPlan.outline(settings: settings, frame: frame, standard: true, onDesktop: display.isDesktop, cornerRadius: Self.cornerRadius)
        }
        guard outline(around: frame) != nil else { return clear() }

        watched = (id, w.element)
        let motion = wm.motion(of: id)
        let verdict = tracker.look(FocusRingTracker.Look(
            window: id, frame: frame, gliding: motion?.gliding ?? false, heading: motion?.to,
            mouseDown: CGEventSource.buttonState(.combinedSessionState, button: .left), time: ProcessInfo.processInfo.systemUptime))
        watch(verdict.lookAgain)
        guard let around = verdict.frame, let ring = outline(around: around) else { return hide() }

        let overlay = self.overlay ?? OutlineOverlay()
        self.overlay = overlay
        overlay.draw(ring, color: settings.color.nsColor)
        // A window belongs to the desktop it was put on screen on. To follow the focus to
        // another desktop, the overlay leaves the one it is on and is put on screen again.
        if overlay.isShown, shown?.space != display.spaceID { overlay.hide() }
        if reorder || !overlay.isShown || shown?.id != id { overlay.order(above: id) }
        shown = (id, display.spaceID)
    }

    /// No window gets a ring now.
    private func clear() {
        watched = nil
        _ = tracker.look(nil)
        watch(false)
        hide()
    }

    private func hide() {
        overlay?.hide()
        shown = nil
    }

    /// Look again thirty times a second for as long as the window is on its way. Nothing tells
    /// Iguana that a glide has landed or that a drag has ended where this could hear it.
    private func watch(_ on: Bool) {
        if on, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.update(reorder: false) }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    /// A window that can be tiled is a standard one. A standard window of a fixed size, such as
    /// Calculator, is not tileable, so it is asked what it is.
    private func isStandard(_ w: WindowState) -> Bool {
        if w.tileable || knownStandard == w.id { return true }
        guard w.element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole else { return false }
        knownStandard = w.id
        return true
    }

    /// Where the window server has a window, if it is on screen. One call, about one window.
    private static func frameOnScreen(_ id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
}
