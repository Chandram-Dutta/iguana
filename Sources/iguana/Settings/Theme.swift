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

/// A pane: its name and one line on what it is for go in the window's bar, an optional preview
/// stays put under it, and the settings are a grouped form, as in System Settings. The preview
/// stays in view while a slider is dragged.
struct PaneScaffold<Hero: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content

    private var hasHero: Bool { Hero.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHero {
                hero
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Form { content }
                .formStyle(.grouped)
                // One background for the whole pane, so the preview above does not sit on a
                // different shade from the settings below it.
                .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }
}

extension PaneScaffold where Hero == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, hero: { EmptyView() }, content: content)
    }
}

/// A named group of rows, with an optional line of explanation under it.
struct SettingSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer {
                Text(footer)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One setting: what it is on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

/// A slider with its value written beside it.
struct ValueSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: SwiftUI.Binding(get: { value }, set: { onChange(($0 / step).rounded() * step) }), in: range)
                .controlSize(.small)
                .frame(width: 190)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

/// A choice between a few options, shown side by side: the system's segmented picker.
struct Segmented<Value: Hashable>: View {
    /// What is being chosen, for VoiceOver.
    let name: String
    let options: [Value]
    let selection: Value
    let onSelect: (Value) -> Void
    let title: (Value) -> String

    var body: some View {
        Picker(name, selection: SwiftUI.Binding(get: { selection }, set: onSelect)) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// One key of a shortcut, drawn as a key.
struct KeyCap: View {
    let text: String
    var dimmed = false

    var body: some View {
        Text(text)
            .font(Theme.rounded(12, .medium))
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .frame(minWidth: 13)
            .padding(.horizontal, 5)
            .frame(height: 22)
            // A flat, see-through key: the window is glass, and a raised white key would sit on it
            // like a sticker.
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.075)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// A shortcut as a row of keys: ⌥ ⇧ H.
struct KeyCaps: View {
    let combo: KeyCombo

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(ShortcutFormat.keys(combo).enumerated()), id: \.offset) { _, key in
                KeyCap(text: key)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShortcutFormat.spoken(combo))
    }
}

/// A short message among the settings: something to fix, or something to know.
struct Callout<Trailing: View>: View {
    enum Kind { case attention, good, note }
    let kind: Kind
    let text: String
    @ViewBuilder var trailing: Trailing

    private var symbol: String {
        switch kind {
        case .attention: return "exclamationmark.triangle.fill"
        case .good: return "checkmark.circle.fill"
        case .note: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .attention: return Theme.attention
        case .good: return Theme.accent
        case .note: return .secondary
        }
    }

    var body: some View {
        // A row of the form it sits in: the symbol's colour says what kind of message it is.
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension Callout where Trailing == EmptyView {
    init(_ kind: Kind, _ text: String) {
        self.init(kind: kind, text: text) { EmptyView() }
    }
}

/// The curve of a pacing option, so the choice can be seen as well as read.
struct EasingGlyph: View {
    let easing: Easing

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let steps = 24
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let point = CGPoint(x: 1 + (size.width - 2) * t, y: size.height - 1 - (size.height - 2) * easing.apply(t))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 18, height: 12)
        .accessibilityHidden(true)
    }
}

extension Easing {
    var title: String {
        switch self {
        case .easeOut: return "Ease out"
        case .easeInOut: return "Ease in and out"
        case .linear: return "Linear"
        }
    }

    /// The closest SwiftUI curve, for previews.
    func animation(duration: Double) -> Animation {
        switch self {
        case .linear: return .linear(duration: duration)
        case .easeOut: return .timingCurve(0.215, 0.61, 0.355, 1, duration: duration)
        case .easeInOut: return .timingCurve(0.645, 0.045, 0.355, 1, duration: duration)
        }
    }
}
