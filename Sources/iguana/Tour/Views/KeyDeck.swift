import IguanaCore
import SwiftUI

// MARK: Keys

/// The keys of a lesson, laid out as they are under the hands: the ones to hold, then the ones to
/// press. Held keys go down as they go down on the keyboard.
struct KeyDeck: View {
    @ObservedObject var model: TourModel
    let keys: LessonKeys
    @Environment(\.tourPalette) private var palette

    private static let names: [Modifier: (symbol: String, name: String)] = [
        .ctrl: ("⌃", "control"), .option: ("⌥", "option"), .shift: ("⇧", "shift"), .cmd: ("⌘", "command"),
    ]

    var body: some View {
        let holding = keys.modifiers.allSatisfy(model.held.contains)
        let next = model.suggested
        HStack(spacing: 12) {
            ForEach(keys.modifiers, id: \.self) { modifier in
                let down = model.held.contains(modifier)
                KeyFace(down: down, calling: !down, width: 92) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.names[modifier]?.symbol ?? "")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Spacer(minLength: 0)
                        Text(Self.names[modifier]?.name ?? "")
                            .font(Theme.rounded(12.5, .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            if !keys.modifiers.isEmpty {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.faint)
                    .padding(.horizontal, 2)
            }
            HStack(spacing: 8) {
                ForEach(keys.keys) { key in
                    let wide = key.label.count > 2
                    KeyFace(down: model.lit.contains(key.id), calling: holding && key.command == next, width: wide ? nil : 58) {
                        VStack(spacing: 3) {
                            if let symbol = key.symbol {
                                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).opacity(0.5)
                            }
                            Text(key.label).font(Theme.rounded(wide ? 15 : 19, .semibold))
                        }
                        .padding(.horizontal, wide ? 14 : 0)
                    }
                }
            }
        }
        .modifier(Shake(times: CGFloat(model.refusals)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.keys.map(\.label).joined(separator: ", "))
    }
}

/// A small sideways shake, once for each time `times` goes up: "not that one".
private struct Shake: GeometryEffect {
    var times: CGFloat

    var animatableData: CGFloat {
        get { times }
        set { times = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(times * .pi * 4) * 5, y: 0))
    }
}

private struct KeyFace<Content: View>: View {
    let down: Bool
    let calling: Bool
    var width: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.tourPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        content
            .foregroundStyle(down ? palette.litInk : palette.ink)
            .frame(width: width, height: 58)
            // The colour of a pressed key is painted on the glass rather than left to its tint,
            // which the system drops while another app is in front.
            .background(shape.fill(palette.lit).opacity(down ? 0.92 : 0))
            .glass(shape, interactive: true)
            .overlay(shape.strokeBorder(palette.lit, lineWidth: 2.5).opacity(calling && !down ? (breathe ? 1 : 0.25) : 0))
            .scaleEffect(down ? 0.93 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: down)
            .onAppear {
                guard !reduceMotion else {
                    breathe = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}
