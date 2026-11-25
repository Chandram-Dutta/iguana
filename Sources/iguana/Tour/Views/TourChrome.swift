import SwiftUI

// MARK: Chrome

struct TopBar: View {
    @ObservedObject var model: TourModel
    @Environment(\.tourPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            if !model.closing {
                Button(action: model.toggleMute) {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .glass(Capsule(), interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.soft)
                .help(model.muted ? "Turn sound on" : "Turn sound off")
                .accessibilityLabel(model.muted ? "Turn sound on" : "Turn sound off")

                Button(action: model.escape) {
                    HStack(spacing: 7) {
                        MiniCap(text: "esc")
                        Text(model.skipArmed ? "Press again to leave the tour" : "Skip")
                            .font(Theme.rounded(13, .medium))
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(palette.lit).opacity(model.skipArmed ? 0.4 : 0))
                    .glass(Capsule(), interactive: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.skipArmed ? palette.ink : palette.soft)
                .animation(.snappy(duration: 0.2), value: model.skipArmed)
            }
        }
    }
}

/// A small key, for naming a key inside a line of text or a button.
struct MiniCap: View {
    let text: String
    var inverted = false
    @Environment(\.tourPalette) private var palette

    var body: some View {
        Text(text)
            .font(Theme.rounded(11.5, .semibold))
            .foregroundStyle(inverted ? palette.top : palette.ink.opacity(0.8))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(inverted ? palette.top.opacity(0.18) : palette.ink.opacity(0.08)))
    }
}

/// The one thing Return does on a scene, as a button that says so.
struct Prompt: View {
    let label: String
    var enabled = true
    let action: () -> Void
    @Environment(\.tourPalette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Text(label).font(Theme.rounded(16, .semibold))
                MiniCap(text: "↩", inverted: true)
            }
            .foregroundStyle(palette.top)
            .padding(.leading, 24)
            .padding(.trailing, 14)
            .frame(height: 48)
            .background(Capsule().fill(palette.ink).opacity(0.9))
            .glass(Capsule(), interactive: true)
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

struct Headline: View {
    let title: String
    let detail: String
    let k: CGFloat
    @Environment(\.tourPalette) private var palette

    var body: some View {
        VStack(spacing: 9 * k) {
            Text(title)
                .font(Theme.rounded(44 * k, .bold))
                .tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.system(size: 17.5 * k, weight: .regular, design: .rounded))
                .foregroundStyle(palette.soft)
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: 720)
    }
}
