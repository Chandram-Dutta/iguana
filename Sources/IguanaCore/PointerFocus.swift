import CoreGraphics
import Foundation

/// Focus follows mouse: decides which window gets the focus when the pointer comes to rest.
///
/// The rule it keeps is that the pointer only ever speaks for itself. A window gets the focus
/// because the user moved the pointer onto it and left it there, never because the focus was
/// moved with the keyboard while the pointer happened to lie somewhere else, and never because
/// Iguana itself put the pointer somewhere.
public struct PointerFocus {
    /// How long the pointer rests on a window before the window gets the focus, in seconds.
    public static let dwell = 0.08

    /// After the focus changed without the pointer, the pointer has to travel this far, in
    /// points, before it counts as moved. A mouse that is bumped, or a sensor that twitches,
    /// must not take the focus back from the keyboard.
    public static let slack: CGFloat = 3

    /// Something on screen that the pointer can be over.
    public struct Surface: Equatable {
        public enum Kind: Equatable {
            /// A standard window that Iguana knows: one that may get the focus.
            case window
            /// Any other ordinary window: a dialog, a panel, a window of Iguana's own.
            case other
            /// An open menu. While one is open the pointer belongs to it, wherever it is.
            case menu
        }

        public var id: WindowID
        /// Top-left coordinates, like the window list.
        public var frame: CGRect
        public var kind: Kind

        public init(id: WindowID, frame: CGRect, kind: Kind) {
            self.id = id
            self.frame = frame
            self.kind = kind
        }
    }

    /// What there is on screen at the moment the pointer comes to rest.
    public struct Scene: Equatable {
        /// Front to back.
        public var surfaces: [Surface]
        /// Each display without its menu bar and its Dock.
        public var areas: [CGRect]
        /// The window a click at the pointer would land on, as the window server answers it.
        /// The window list cannot tell a menu bar item, a popover, Mission Control or a
        /// window that lets clicks through from the window under them; this can.
        public var hit: WindowID?
        /// Any mouse button is held: the user is dragging, resizing or selecting.
        public var buttonsDown: Bool
        public var focused: WindowID?

        public init(surfaces: [Surface], areas: [CGRect], hit: WindowID?, buttonsDown: Bool, focused: WindowID?) {
            self.surfaces = surfaces
            self.areas = areas
            self.hit = hit
            self.buttonsDown = buttonsDown
            self.focused = focused
        }
    }

    /// The pointer moved, as the user moves it, since the last time it came to rest.
    private var armed = false
    /// The window that had the focus when the pointer last moved.
    private var focusWhenMoved: WindowID?
    /// The focus as it was last seen or last asked for. `.some(nil)` is "no window".
    private var knownFocus: WindowID??
    /// Where the pointer was last seen.
    private var last: CGPoint?
    /// Where the pointer lay when the focus changed without it. It counts as moved again
    /// once it is `slack` away from here.
    private var anchor: CGPoint?
    /// Where Iguana itself last put the pointer.
    private var warp: CGPoint?

    public init() {}

    /// The pointer is reported at `point`. Returns whether that counts as the user moving it,
    /// which is what starts the wait for it to rest.
    public mutating func moved(to point: CGPoint, focused: WindowID?) -> Bool {
        if let warp {
            // Still exactly where Iguana put it: that was not the user.
            if Self.distance(point, warp) < 1 { return false }
            self.warp = nil
        }
        if knownFocus != .some(focused) {
            // The focus changed while the pointer lay still: a shortcut, a click, another app
            // coming forward. The pointer says nothing until it is moved in earnest.
            knownFocus = .some(focused)
            anchor = last ?? point
            armed = false
        }
        last = point
        if let anchor {
            if Self.distance(point, anchor) < Self.slack { return false }
            self.anchor = nil
        }
        armed = true
        focusWhenMoved = focused
        return true
    }

    /// Iguana moved the pointer itself (`mouse-follows-focus`). That is not the user moving it.
    public mutating func warped(to point: CGPoint) {
        warp = point
        last = point
        anchor = point
        armed = false
    }

    /// The pointer has come to rest and there is nothing for it to do, as when it lies on
    /// the window that already has the focus. It says no more until it moves again.
    public mutating func stay() {
        armed = false
    }

    /// The pointer has rested at `point` for `dwell`. The window that gets the focus, if any.
    public mutating func rested(at point: CGPoint, scene: Scene) -> WindowID? {
        guard armed else { return nil }
        armed = false
        last = point
        guard scene.focused == focusWhenMoved else {
            // The focus changed after the pointer last moved: the keyboard was the last to speak.
            knownFocus = .some(scene.focused)
            anchor = point
            return nil
        }
        guard let target = Self.target(at: point, in: scene) else { return nil }
        knownFocus = .some(target)
        return target
    }

    /// The window under the pointer that may be given the focus. This part has no memory.
    public static func target(at point: CGPoint, in scene: Scene) -> WindowID? {
        // Dragging, resizing, selecting text: the pointer is busy.
        guard !scene.buttonsDown else { return nil }
        // A menu is open. Focusing another window would close it under the user's hand.
        guard !scene.surfaces.contains(where: { $0.kind == .menu }) else { return nil }
        // Over the menu bar or the Dock, or on no display at all.
        guard scene.areas.contains(where: { $0.contains(point) }) else { return nil }
        // The frontmost thing at that point decides. A window that is covered there by
        // another one is not under the pointer, however much of it shows elsewhere.
        guard let top = scene.surfaces.first(where: { $0.frame.contains(point) }), top.kind == .window else { return nil }
        guard top.id != scene.focused else { return nil }
        // And a click there has to land on that same window.
        guard scene.hit == top.id else { return nil }
        return top.id
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        max(abs(a.x - b.x), abs(a.y - b.y))
    }
}
