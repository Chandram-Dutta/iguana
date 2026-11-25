import IguanaCore
import SwiftUI

/// The shortcuts of one command: its keys, or an empty slot to add one.
struct ShortcutCell: View {
    @ObservedObject var model: SettingsModel
    let commandText: String

    private var bindings: [KeyBinding] {
        guard let command = try? Command.parse(commandText) else { return [] }
        return model.bindings(for: command)
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(bindings, id: \.source) { binding in
                RecorderButton(model: model, slot: "\(commandText)|\(binding.source)",
                               onClear: { model.unbind(binding) },
                               onRecorded: { model.bind($0, to: commandText, replacing: binding) }) {
                    KeyCaps(combo: binding.combo)
                }
                .contextMenu {
                    Button("Add Another Shortcut") {
                        model.startRecording(slot: "\(commandText)|new") { model.bind($0, to: commandText, replacing: nil) }
                    }
                    Button("Remove \(ShortcutFormat.display(binding.combo))") { model.unbind(binding) }
                }
                .help("Click to change. Right-click to add another or remove.")
                .accessibilityLabel("\(commandText): \(ShortcutFormat.spoken(binding.combo))")
                .accessibilityHint("Activate, then type a new shortcut")
            }
            if bindings.isEmpty || model.recording == "\(commandText)|new" {
                RecorderButton(model: model, slot: "\(commandText)|new", onClear: nil,
                               onRecorded: { model.bind($0, to: commandText, replacing: nil) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                        .contentShape(Rectangle())
                }
                .help("Add a shortcut")
                .accessibilityLabel("\(commandText): no shortcut")
                .accessibilityHint("Activate, then type a shortcut")
            }
        }
    }
}
