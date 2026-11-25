import SwiftUI

/// Shows `label` until clicked, then listens for a shortcut.
struct RecorderButton<Label: View>: View {
    @ObservedObject var model: SettingsModel
    let slot: String
    let onClear: (() -> Void)?
    let onRecorded: (String) -> Void
    @ViewBuilder var label: Label
    @State private var pulse = false

    private var recording: Bool { model.recording == slot }

    var body: some View {
        Button {
            if recording {
                model.stopRecording()
            } else {
                model.startRecording(slot: slot, onClear: onClear, completion: onRecorded)
            }
        } label: {
            if recording {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 5, height: 5).opacity(pulse ? 0.35 : 1)
                    Text("Type shortcut").font(Theme.rounded(11.5, .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Theme.accent))
                .onAppear {
                    pulse = false
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                }
            } else {
                label
            }
        }
        .buttonStyle(.plain)
    }
}
