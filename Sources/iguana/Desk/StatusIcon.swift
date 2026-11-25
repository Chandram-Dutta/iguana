import AppKit
import IguanaCore

/// The menu bar icon: the desktop you are on, drawn small. Each window is a block where the
/// window is, and the focused one is solid. It is laid out by the same code as the real windows,
/// so the icon and the screen never disagree.
///
/// The desktop's number is drawn into the same picture. Left to the menu bar, text sits on its
/// own baseline beside the picture and the two never quite line up; drawn here, the middle of
/// the digits is the middle of the drawing.
enum StatusIcon {
    enum State {
        case layout(NodeSnapshot, windows: Set<WindowID>, focused: WindowID?)
        case paused
        case needsPermission
    }

    /// One desktop of a row of them.
    struct Desk {
        let number: Int
        let isActive: Bool
        let layout: NodeSnapshot
        let windows: Set<WindowID>
        let focused: WindowID?
    }

    /// Where a desktop sits in the row, so that a click can be told apart.
    struct Slot: Equatable {
        let number: Int
        let range: ClosedRange<CGFloat>
    }

    /// Every picture has this height, and everything in it is centred on the middle of it.
    static let height: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private static let labelGap: CGFloat = 5

    /// The text after the drawing: the desktop's number, and beside it the mode while one is on.
    static func label(desktop: String, mode: String) -> String {
        mode == Config.defaultMode ? desktop : [desktop, mode].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func labelWidth(_ label: String) -> CGFloat {
        label.isEmpty ? 0 : ceil((label as NSString).size(withAttributes: [.font: font]).width) + labelGap
    }

    /// Draw the label after the drawing, with the middle of its capitals and digits on the centre line.
    private static func draw(label: String, at x: CGFloat) {
        guard !label.isEmpty else { return }
        // In a flipped picture text is placed by the top of its line; the baseline is one ascent below.
        let top = height / 2 + font.capHeight / 2 - font.ascender
        (label as NSString).draw(at: NSPoint(x: x + labelGap, y: top), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }

    static func image(_ state: State, aspect: CGFloat = 1.6, label: String = "") -> NSImage {
        let glyph = NSSize(width: min(max((14 * aspect).rounded(), 18), 26), height: 14)
        let image = NSImage(size: NSSize(width: glyph.width + labelWidth(label), height: height), flipped: true) { _ in
            let rect = NSRect(x: 0, y: (height - glyph.height) / 2, width: glyph.width, height: glyph.height)
            let ink = NSColor.black
            func outline(_ alpha: CGFloat) {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3.2, yRadius: 3.2)
                path.lineWidth = 1.3
                ink.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
            switch state {
            case .needsPermission:
                outline(0.5)
                ink.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - 0.9, y: rect.midY - 4, width: 1.8, height: 5), xRadius: 0.9, yRadius: 0.9).fill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 1, y: rect.midY + 2.2, width: 2, height: 2)).fill()
            case .paused:
                outline(0.5)
                ink.setFill()
                for x in [rect.midX - 3.2, rect.midX + 1.2] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - 3, width: 2, height: 6), xRadius: 0.8, yRadius: 0.8).fill()
                }
            case .layout(let layout, let windows, let focused):
                // Like the gap, the strip of a stacked window is drawn far larger than to scale, so that it can be seen.
                let frames = computeLayout(Tree(snapshot: layout), in: rect, gap: 1.6, visible: windows, peek: 2.6)
                if frames.isEmpty {
                    // An empty desktop.
                    outline(0.7)
                }
                for (id, frame) in frames {
                    let radius = min(2.4, min(frame.width, frame.height) / 2)
                    ink.withAlphaComponent(id == focused || frames.count == 1 ? 1 : 0.4).setFill()
                    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
                }
            }
            draw(label: label, at: glyph.width)
            return true
        }
        // The system colours it for a light or dark menu bar, and for the pressed state.
        image.isTemplate = true
        return image
    }

    /// Several desktops side by side. The one in use is drawn at full strength with a mark under
    /// it; the others are faint. An empty desktop is an outline.
    static func row(_ desks: [Desk], aspect: CGFloat = 1.6, label: String = "") -> (image: NSImage, slots: [Slot]) {
        let glyph = NSSize(width: min(max((11 * aspect).rounded(), 15), 20), height: 11)
        let spacing: CGFloat = 5
        let width = CGFloat(desks.count) * glyph.width + CGFloat(max(desks.count - 1, 0)) * spacing
        var slots: [Slot] = []
        for (index, desk) in desks.enumerated() {
            let x = CGFloat(index) * (glyph.width + spacing)
            slots.append(Slot(number: desk.number, range: (x - spacing / 2)...(x + glyph.width + spacing / 2)))
        }
        let image = NSImage(size: NSSize(width: width + labelWidth(label), height: height), flipped: true) { _ in
            let ink = NSColor.black
            let top = (height - glyph.height) / 2
            for (index, desk) in desks.enumerated() {
                let rect = NSRect(x: CGFloat(index) * (glyph.width + spacing), y: top, width: glyph.width, height: glyph.height)
                let frames = computeLayout(Tree(snapshot: desk.layout), in: rect, gap: 1.4, visible: desk.windows, peek: 2.2)
                if frames.isEmpty {
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 2.6, yRadius: 2.6)
                    path.lineWidth = 1
                    ink.withAlphaComponent(desk.isActive ? 0.85 : 0.3).setStroke()
                    path.stroke()
                }
                for (id, frame) in frames {
                    let radius = min(2, min(frame.width, frame.height) / 2)
                    let alpha: CGFloat = desk.isActive ? (id == desk.focused || frames.count == 1 ? 1 : 0.5) : 0.3
                    ink.withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
                }
                if desk.isActive {
                    // The mark hangs under the row; the row itself stays on the centre line.
                    ink.setFill()
                    NSBezierPath(roundedRect: NSRect(x: rect.midX - 3.5, y: rect.maxY + 1.6, width: 7, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
            draw(label: label, at: width)
            return true
        }
        image.isTemplate = true
        return (image, slots)
    }
}
