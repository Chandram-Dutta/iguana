import AppKit
import IguanaCore

/// A see-through window of Iguana's own that draws one rounded outline, and nothing else.
///
/// It is made to lie among other apps' windows without ever getting in their way. Every click
/// goes through it, it cannot take the keyboard, it is left out of Mission Control and of the
/// window cycle, and it sits at the level of ordinary windows, so it can be slipped in directly
/// above one of them instead of floating over everything.
///
/// It knows nothing about focus. Give it an outline and a colour, and say which window it
/// goes above. The focus ring is its first user.
final class OutlineOverlay {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        // The line may run past the edge of the screen, as the window it surrounds may.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// The whole window is one layer: its border is the line, its background the fill.
    private final class OutlineView: NSView {
        var outline = Outline(rect: .zero, lineWidth: 0, cornerRadius: 0) {
            didSet {
                layer?.borderWidth = outline.lineWidth
                layer?.cornerRadius = outline.outerRadius
            }
        }
        var color = NSColor.clear
        var fill: NSColor?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            // Windows have had the smoother corner since macOS 26.
            if #available(macOS 26.0, *) { layer?.cornerCurve = .continuous }
            // The accent colour, or light and dark, was changed in System Settings.
            NotificationCenter.default.addObserver(self, selector: #selector(coloursChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func coloursChanged() { needsDisplay = true }

        override var wantsUpdateLayer: Bool { true }

        /// AppKit calls this with the current appearance in force, which is what turns a
        /// colour such as the accent colour into the one to draw with right now.
        override func updateLayer() {
            layer?.borderColor = color.cgColor
            layer?.backgroundColor = fill?.cgColor
        }
    }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let view = OutlineView()
    /// Ordered in, on the desktop that was showing when it was.
    private(set) var isShown = false

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Among ordinary windows, so that a window lying over the outlined one covers the line too.
        panel.level = .normal
        panel.isFloatingPanel = false
        // A panel hides when its app is not in front, which Iguana hardly ever is.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        // Not a window to Mission Control, the window cycle or Stage Manager's stages.
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone, .canJoinAllApplications]
        panel.setAccessibilityElement(false)
        panel.contentView = view
    }

    /// The window itself, for tests.
    var window: NSWindow { panel }

    /// Give the outline its place and its look. The line lies outside `outline.rect`. This
    /// does not put the overlay on screen; `order(above:)` does.
    func draw(_ outline: Outline, color: NSColor, fill: NSColor? = nil) {
        let frame = outline.appKitFrame(primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        guard view.outline != outline || view.color != color || view.fill != fill else { return }
        view.outline = outline
        view.color = color
        view.fill = fill
        view.needsDisplay = true
    }

    /// Put the overlay on screen directly above another window, which may belong to any app, or
    /// in front of the ordinary windows when none is given. It lands on the desktop being shown.
    func order(above window: CGWindowID?) {
        panel.displayIfNeeded()
        if let window {
            panel.order(.above, relativeTo: Int(window))
        } else {
            panel.orderFrontRegardless()
        }
        isShown = true
    }

    /// Put the overlay on screen directly below another window: above everything that window
    /// is in front of. The outline of a landing place goes under the window being dragged.
    func order(below window: CGWindowID) {
        // A window that is not on screen yet is not drawn by asking the window. The view is
        // asked, so that the colours are in place before the first frame is shown.
        view.displayIfNeeded()
        panel.order(.below, relativeTo: Int(window))
        isShown = true
    }

    func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        isShown = false
    }
}
