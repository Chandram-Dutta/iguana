import Combine
import SwiftUI

// MARK: Permission

struct PermissionScene: View {
    @ObservedObject var model: TourModel
    let k: CGFloat
    @Environment(\.tourPalette) private var palette

    var body: some View {
        let granted = model.permission == .granted
        VStack(spacing: 0) {
            Spacer()
            SwitchCard(on: granted, demonstrate: !granted)
            Spacer().frame(height: 46 * k)
            ZStack {
                Headline(title: granted ? "That was it" : "One switch to flip",
                         detail: granted ? "Iguana can arrange your windows now."
                             : "macOS asks you before an app may move windows. Turn Iguana on\nunder Accessibility, and the tour carries on by itself.",
                         k: k)
                    .id(granted)
                    .transition(.opacity)
            }
            Spacer().frame(height: 36 * k)
            ZStack {
                switch model.permission {
                case .idle:
                    Prompt(label: "Open System Settings", action: model.primary)
                case .waiting:
                    VStack(spacing: 14) {
                        HStack(spacing: 9) {
                            WaitingDots()
                            Text("Waiting for the switch").font(Theme.rounded(15, .medium)).foregroundStyle(palette.soft)
                        }
                        .frame(height: 48)
                        Button("Open Accessibility settings again", action: model.openAccessibilitySettings)
                            .buttonStyle(.plain)
                            .font(Theme.rounded(13, .medium))
                            .foregroundStyle(palette.soft)
                            .underline()
                    }
                case .granted:
                    Color.clear.frame(height: 48)
                }
            }
            .frame(height: 90, alignment: .top)
            Spacer()
            Spacer().frame(height: 30 * k)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The row to look for in System Settings, flipping its switch to show what to do.
private struct SwitchCard: View {
    let on: Bool
    let demonstrate: Bool
    @Environment(\.tourPalette) private var palette
    @State private var shown = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let isOn = on || shown
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Text("Privacy & Security")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                Text("Accessibility")
            }
            .font(Theme.rounded(12.5, .medium))
            .foregroundStyle(palette.soft)
            .padding(.leading, 4)

            HStack(spacing: 14) {
                TourLogo().frame(width: 38, height: 38)
                Text("Iguana").font(Theme.rounded(19, .semibold))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? palette.lit : palette.ink.opacity(0.16)).frame(width: 58, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isOn)
                .overlay {
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(palette.lit)
                            .offset(x: 12)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(width: 430, height: 76)
            .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .onReceive(timer) { _ in
            guard demonstrate else { return }
            shown.toggle()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In System Settings, under Privacy and Security, Accessibility, turn on Iguana")
    }
}

private struct WaitingDots: View {
    @Environment(\.tourPalette) private var palette
    @State private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(palette.soft).frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(index) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}
