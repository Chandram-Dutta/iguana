import SwiftUI

// MARK: Hello

struct HelloScene: View {
    @ObservedObject var model: TourModel
    let size: CGSize
    let k: CGFloat
    @Environment(\.tourPalette) private var palette
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: size.height * 0.33 + 86 * k + 38 * k)
            RisingText(text: "Meet Iguana", font: Theme.rounded(66 * k, .bold), shown: shown)
            Text("It keeps your windows in order, so you never arrange them again.")
                .font(.system(size: 19 * k, weight: .regular, design: .rounded))
                .foregroundStyle(palette.soft)
                .padding(.top, 12 * k)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(0.75), value: shown)
            Prompt(label: "Take the tour", action: model.primary)
                .padding(.top, 44 * k)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
                .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(1.15), value: shown)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { shown = true }
    }
}

/// A line whose letters come up one after another.
private struct RisingText: View {
    let text: String
    let font: Font
    let shown: Bool

    var body: some View {
        HStack(spacing: -0.5) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, letter in
                Text(String(letter))
                    .font(font)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 26)
                    .animation(.spring(response: 0.62, dampingFraction: 0.74).delay(0.25 + Double(index) * 0.04), value: shown)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
}
