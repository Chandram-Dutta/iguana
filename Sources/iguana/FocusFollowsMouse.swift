import AppKit
import ApplicationServices
import IguanaCore

/// `focus-follows-mouse`: the window the pointer comes to rest on gets the focus.
///
/// While the setting is off, nothing is installed and nothing runs. While it is on, an event
/// monitor hears the pointer move. Each event only notes where the pointer is and when; the
/// looking is done once, after the pointer has lain still for `PointerFocus.dwell`, and most of
/// the time that is one question to the window server, because the pointer rests on the window
/// that already has the focus.
///
/// Which window gets the focus is decided in IguanaCore (`PointerFocus`). This file hears the
/// events, keeps the timer and gathers what is on screen.
final class FocusFollowsMouse {
    private weak var wm: WindowManager?
    private var monitors: [Any] = []
    private var tracker = PointerFocus()
    /// When the pointer last moved, on the clock of `ProcessInfo.systemUptime`. The time an
    /// event carries is not used: nothing promises that it is counted on the same clock.
    private var lastMove: TimeInterval = 0
    /// A look is already due, so that a stream of events starts one timer and not hundreds.
    private var waiting = false

    /// Whether the pointer is being listened to. Never while the setting is off.
    var isListening: Bool { !monitors.isEmpty }

    /// Called after every refresh of the window manager, which is also how a changed setting
    /// arrives.
    func changed(_ wm: WindowManager) {
        listen(wm.config.focusFollowsMouse, wm)
    }

    /// Installs the monitors when the setting is switched on, removes them when it is
    /// switched off.
    func listen(_ on: Bool, _ wm: WindowManager) {
        self.wm = wm
        guard on != isListening else { return }
        if on {
            tracker = PointerFocus()
            // Events meant for other apps arrive through the global monitor, events meant for
            // one of Iguana's own windows through the local one.
            let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in self?.moved(event) }
            let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.moved(event)
                return event
            }
            monitors = [global, local].compactMap { $0 }
            wm.onPointerWarp = { [weak self] point in self?.tracker.warped(to: point) }
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            wm.onPointerWarp = nil
        }
    }

    /// Runs for every movement of the mouse, so it does next to nothing.
    private func moved(_ event: NSEvent) {
        guard let wm else { return }
        let appKit = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        let point = CGPoint(x: appKit.x, y: (NSScreen.screens.first?.frame.height ?? 0) - appKit.y)
        guard tracker.moved(to: point, focused: wm.focusedWindow) else { return }
        lastMove = ProcessInfo.processInfo.systemUptime
        guard !waiting else { return }
        waiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PointerFocus.dwell) { [weak self] in self?.dwellEnded() }
    }

    private func dwellEnded() {
        waiting = false
        guard !monitors.isEmpty else { return }
        // The pointer moved again in the meantime: wait out the rest of its dwell.
        let remaining = min(PointerFocus.dwell, PointerFocus.dwell - (ProcessInfo.processInfo.systemUptime - lastMove))
        if remaining > 0.005 {
            waiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in self?.dwellEnded() }
            return
        }
        rested()
    }

    private func rested() {
        guard let wm, let pointer = CGEvent(source: nil)?.location else { return }
        // The quick look, which usually settles it: the window a click here would land on is
        // not one Iguana knows, or it is the one that has the focus already.
        guard let hit = Self.windowUnderPointer(), hit != wm.focusedWindow, wm.facts().windows[hit] != nil else {
            tracker.stay()
            return
        }
        // The pointer rests on another window. Look properly, with the focus as it is right
        // now, not as it was at the last refresh.
        let facts = wm.facts(fresh: true)
        let scene = PointerFocus.Scene(surfaces: Self.surfaces(under: pointer, facts), areas: wm.displays.map(\.visibleFrame), hit: hit,
                                       buttonsDown: NSEvent.pressedMouseButtons != 0, focused: wm.focusedWindow)
        if let target = tracker.rested(at: pointer, scene: scene) { wm.focusFromPointer(target) }
    }

    /// The window a click at the pointer would land on, whichever app it belongs to. The
    /// window server answers by its own rules for clicks, so a window that lets clicks through
    /// is passed over, and a menu, a popover or Mission Control is what it says when one of
    /// those is under the pointer.
    private static func windowUnderPointer() -> CGWindowID? {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return number > 0 ? CGWindowID(number) : nil
    }

    /// The ordinary windows on screen and the open menus, front to back.
    private static func surfaces(under pointer: CGPoint, _ facts: WindowManager.Facts) -> [PointerFocus.Surface] {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let own = getpid()
        // Windows of Iguana's own that let clicks through (the focus ring) are not in the way.
        let seeThrough = Set(NSApp.windows.filter(\.ignoresMouseEvents).map(\.windowNumber))
        let screens = NSScreen.screens.map(\.frame.width)
        var surfaces: [PointerFocus.Surface] = []
        for info in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            if layer == menuLevel {
                // A menu is never as wide as a display. Something that is, at this level, is
                // another app's overlay and not a menu.
                if !screens.contains(where: { frame.width >= $0 }) { surfaces.append(.init(id: id, frame: frame, kind: .menu)) }
                continue
            }
            // Everything else that floats above ordinary windows is left to the window
            // server's answer: the list cannot tell which of it takes clicks.
            guard layer == 0 else { continue }
            if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == own, seeThrough.contains(Int(id)) { continue }
            var kind = PointerFocus.Surface.Kind.other
            if let w = facts.windows[id] {
                // A window that can be tiled is a standard one. One that cannot (a fixed size,
                // a dialog) is only asked what it is when the pointer is on it.
                if w.tileable || (frame.contains(pointer) && w.element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole) { kind = .window }
            }
            surfaces.append(.init(id: id, frame: frame, kind: kind))
        }
        return surfaces
    }
}
