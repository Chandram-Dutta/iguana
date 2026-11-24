import CoreGraphics
import Foundation

/// The colour of the focus ring: the system's accent colour, or one written in the config file.
public enum RingColor: Equatable {
    /// Whatever accent colour is chosen in System Settings, followed as it changes.
    case accent
    /// Red, green, blue and opacity, each from 0 to 1, in sRGB.
    case custom(red: Double, green: Double, blue: Double, alpha: Double)

    /// Reads `accent`, or a colour as the web writes it: `#rgb`, `#rrggbb` or `#rrggbbaa`.
    /// Capitals and spaces around it do not matter. Anything else is nil.
    public init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "accent" {
            self = .accent
            return
        }
        guard text.hasPrefix("#") else { return nil }
        // Plain digits and letters only, as a config file is typed.
        var digits = text.dropFirst().map { $0.isASCII ? $0.hexDigitValue : nil }
        guard [3, 6, 8].contains(digits.count), !digits.contains(nil) else { return nil }
        // `#8d3` is short for `#88dd33`.
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        let bytes = stride(from: 0, to: digits.count, by: 2).map { Double((digits[$0] ?? 0) * 16 + (digits[$0 + 1] ?? 0)) / 255 }
        self = .custom(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] : 1)
    }

    /// How the config file writes it. The opacity is left out when the colour is solid.
    public var text: String {
        switch self {
        case .accent: return "accent"
        case .custom(let red, let green, let blue, let alpha):
            let parts = alpha < 1 ? [red, green, blue, alpha] : [red, green, blue]
            return "#" + parts.map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
        }
    }
}

/// `[focus-ring]`: the ring around the window that has the focus.
public struct FocusRingSettings: Equatable {
    public var enabled = false
    /// Thickness of the line, in points.
    public var width: Double = 3
    public var color = RingColor.accent

    public init() {}
}

/// How round the corners of a standard window are. macOS has no call that tells one app the
/// corners of another app's window, so this goes by the version of the system.
public enum WindowCorners {
    /// - macOS 26 and later: 16 points. Measured on macOS 27.2: AppKit and the window server
    ///   both give 16 for a titled window, with or without a toolbar.
    /// - Before that (Big Sur to Sequoia): 10 points.
    ///
    /// A program built with an older SDK is told that macOS 26 is "16", so 16 and up counts
    /// as the newer look; there never was a macOS 16 to 25.
    public static func radius(macOSMajor: Int) -> CGFloat {
        macOSMajor >= 16 ? 16 : 10
    }
}

/// A rounded line drawn around a rectangle on screen. The line lies wholly outside the
/// rectangle, so it never covers what is inside.
public struct Outline: Equatable {
    /// What is outlined, in the coordinates of the window list: measured from the top-left
    /// corner of the primary display, y growing downwards.
    public var rect: CGRect
    public var lineWidth: CGFloat
    /// The radius of the rectangle's own corners. The line follows them.
    public var cornerRadius: CGFloat

    public init(rect: CGRect, lineWidth: CGFloat, cornerRadius: CGFloat) {
        self.rect = rect
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
    }

    /// Everything the line covers: the rectangle grown by the width of the line.
    public var bounds: CGRect { rect.insetBy(dx: -lineWidth, dy: -lineWidth) }

    /// The radius of the outer edge of the line. It shares its centre with the corner of the
    /// rectangle, which is what makes the line the same thickness all the way round.
    public var outerRadius: CGFloat { cornerRadius + lineWidth }

    /// `bounds` as AppKit places a window: measured from the bottom-left corner of the
    /// primary display, y growing upwards.
    public func appKitFrame(primaryHeight: CGFloat) -> CGRect {
        let b = bounds
        return CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
    }
}

/// Whether the focused window gets a ring, and its shape.
public enum FocusRingPlan {
    /// The display a window is on: the one that holds its centre, or else the one that shows
    /// most of it. Nil when no display shows any of it.
    public static func screen(for frame: CGRect, among screens: [CGRect]) -> Int? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let i = screens.firstIndex(where: { $0.contains(centre) }) { return i }
        var best: (index: Int, area: CGFloat)?
        for (i, screen) in screens.enumerated() {
            let overlap = screen.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (i, area) }
        }
        return best?.index
    }

    /// The ring for a window, or nil when it gets none.
    ///
    /// - Parameters:
    ///   - frame: where the window is, when it is on screen.
    ///   - standard: it is a standard window that Iguana knows. Dialogs and sheets get no ring.
    ///   - onDesktop: its display is showing a desktop. A display that shows a native
    ///     fullscreen Space is showing a window that fills it, and that one gets no ring.
    ///   - cornerRadius: how round a window's corners are on this system.
    public static func outline(settings: FocusRingSettings, frame: CGRect?, standard: Bool, onDesktop: Bool, cornerRadius: CGFloat) -> Outline? {
        guard settings.enabled, standard, onDesktop, let frame, frame.width >= 1, frame.height >= 1 else { return nil }
        // A corner cannot be rounder than half of the shorter side.
        let radius = max(0, min(cornerRadius, min(frame.width, frame.height) / 2))
        return Outline(rect: frame, lineWidth: CGFloat(settings.width), cornerRadius: radius)
    }
}

/// Decides, each time Iguana looks at the focused window, whether the ring is drawn now.
///
/// A window that is travelling has no ring. Iguana cannot move its ring in the same instant
/// that another app moves its window, so a ring that tried to keep up would trail behind. It
/// steps aside while the window is on its way and comes back where the window stops.
public struct FocusRingTracker {
    /// One look at the window that has the focus.
    public struct Look: Equatable {
        public var window: WindowID
        /// Where the window server has the window right now.
        public var frame: CGRect
        /// Iguana is gliding it to a new place.
        public var gliding: Bool
        /// Where Iguana is sending it, gliding or at once. Nil when Iguana is not moving it.
        public var heading: CGRect?
        /// The mouse button is held, as it is while the user drags or resizes a window.
        public var mouseDown: Bool
        /// When this look was taken, in seconds on any steady clock.
        public var time: Double

        public init(window: WindowID, frame: CGRect, gliding: Bool = false, heading: CGRect? = nil, mouseDown: Bool = false, time: Double) {
            self.window = window
            self.frame = frame
            self.gliding = gliding
            self.heading = heading
            self.mouseDown = mouseDown
            self.time = time
        }
    }

    public struct Verdict: Equatable {
        /// The window frame to draw the ring around. Nil for no ring.
        public var frame: CGRect?
        /// The window may still be on its way: look again in a moment.
        public var lookAgain: Bool

        public init(frame: CGRect?, lookAgain: Bool) {
            self.frame = frame
            self.lookAgain = lookAgain
        }
    }

    /// A window that has not moved for this long, in seconds, has come to rest.
    public static let settle = 0.05

    private var window: WindowID?
    /// The frame the ring is drawn around right now.
    private var ringed: CGRect?
    /// Where Iguana last sent the window.
    private var expected: CGRect?
    /// The frame the window was last seen at, and since when it has been there.
    private var seen: (frame: CGRect, since: Double)?

    public init() {}

    /// `nil` says that no window gets a ring now.
    public mutating func look(_ now: Look?) -> Verdict {
        guard let now else {
            self = FocusRingTracker()
            return Verdict(frame: nil, lookAgain: false)
        }
        // The focus went to another window: it gets its ring at once, where it is.
        let fresh = now.window != window
        if fresh {
            self = FocusRingTracker()
            window = now.window
        }
        if seen.map({ !Self.near($0.frame, now.frame) }) ?? true { seen = (now.frame, now.time) }

        if now.gliding {
            expected = now.heading
            ringed = nil
            return Verdict(frame: nil, lookAgain: true)
        }
        if let to = now.heading {
            // Placed at once: the window is there within a few milliseconds, so the ring goes
            // straight to where it was sent. The next look checks where it really ended up.
            expected = to
            ringed = to
            return Verdict(frame: to, lookAgain: true)
        }
        if let ringed, Self.near(ringed, now.frame) {
            expected = nil
            self.ringed = now.frame
            return Verdict(frame: now.frame, lookAgain: false)
        }
        // The window is somewhere the ring is not. It has stopped when it is where Iguana
        // sent it, or when it has been still for a moment with the mouse button up. With the
        // button down the user may only be pausing in the middle of a drag.
        let landed = expected.map { Self.near($0, now.frame) } ?? false
        let still = !now.mouseDown && now.time - (seen?.since ?? now.time) >= Self.settle
        if fresh || landed || still {
            expected = nil
            ringed = now.frame
            return Verdict(frame: now.frame, lookAgain: false)
        }
        ringed = nil
        return Verdict(frame: nil, lookAgain: true)
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
