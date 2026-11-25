import AppKit
import IguanaCore
import SwiftUI

/// The look of the settings window: a fern green taken from the animal, rounded type for names
/// and keys, and content ruled by hairlines rather than boxed into cards.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// Fern: selection, switches, the focused tile.
    static let accent = dynamic(light: NSColor(srgbRed: 0.09, green: 0.50, blue: 0.31, alpha: 1),
                                dark: NSColor(srgbRed: 0.36, green: 0.82, blue: 0.57, alpha: 1))
    /// Amber: things that need attention.
    static let attention = dynamic(light: NSColor(srgbRed: 0.72, green: 0.44, blue: 0.02, alpha: 1),
                                   dark: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.30, alpha: 1))
    static let hairline = Color.primary.opacity(0.09)
    /// A surface lifted off the window: key caps, the chosen segment.
    static let raised = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.17))
    static let keyStroke = dynamic(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.12))
    static let keyLip = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 0, alpha: 0.45))
    static let well = Color.primary.opacity(0.055)

    // The miniature desktop's wallpaper: canopy to moss.
    static let canopy = Color(red: 0.05, green: 0.24, blue: 0.17)
    static let fern = Color(red: 0.13, green: 0.50, blue: 0.33)
    static let moss = Color(red: 0.62, green: 0.80, blue: 0.42)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The window's own translucent material, as the sidebar of a Mac app has.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    /// `.active` keeps the window see-through while another app is in front.
    var state: NSVisualEffectView.State = .followsWindowActiveState
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.state = state
    }
}

extension View {
    /// Liquid Glass in the given shape where the system has it, and a material before that.
    /// Glass is for the layer that floats above the content: bars, panels, keys and buttons.
    @ViewBuilder
    func glass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.55)) }
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
            }
        }
    }

    /// The system's glass button, where there is one.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            self
        }
    }
}

/// Glass shapes that sit close together are drawn as one piece of glass, which is both how
/// the material is meant to behave and cheaper to draw.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The app's mark: two tiles and an eye.
struct IguanaMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let gap = s * 0.10
            let column = (s - gap) / 2
            let r = s * 0.14
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: column, height: s), cornerRadius: r), with: .color(Theme.accent))
            context.fill(Path(roundedRect: CGRect(x: column + gap, y: column + gap, width: column, height: column), cornerRadius: r),
                         with: .color(Theme.accent.opacity(0.55)))
            let eye = CGRect(x: column + gap, y: 0, width: column, height: column)
            context.fill(Path(ellipseIn: eye), with: .color(Theme.accent))
            let pupil = eye.insetBy(dx: column * 0.36, dy: column * 0.18)
            context.blendMode = .destinationOut
            context.fill(Path(ellipseIn: pupil), with: .color(.black))
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }
}
