import IguanaCore
import SwiftUI

struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel
    @State private var customCommand = ""

    private let directions = [("left", "Left", "arrow.left"), ("down", "Down", "arrow.down"), ("up", "Up", "arrow.up"), ("right", "Right", "arrow.right")]
    private let desktops = (1...9).map { ("\($0)", "Desktop \($0)") } + [("next", "Next desktop"), ("prev", "Previous desktop"), ("recent", "Recent desktop")]
    private let displays = [("next", "Next display"), ("prev", "Previous display")]
    private let windowCommands = [
        ("switcher", "Find a window"),
        ("focus recent", "Back to the window before"),
        ("resize grow", "Grow"), ("resize shrink", "Shrink"), ("balance", "Even out all sizes"), ("zoom", "Fill the desktop"),
        ("flip", "Switch between side by side and top to bottom"), ("stack", "Stack or unstack"), ("float", "Float or tile"), ("close", "Close"), ("pause", "Pause tiling"),
        ("undo", "Undo the last layout change"), ("redo", "Redo the layout change"),
    ]

    private var customText: String { customCommand.trimmingCharacters(in: .whitespaces) }
    private var customProblem: String? {
        guard !customText.isEmpty else { return nil }
        do {
            _ = try Command.parse(customText)
            return nil
        } catch {
            return "\(error)"
        }
    }

    var body: some View {
        PaneScaffold(title: "Shortcuts", subtitle: "Click a shortcut and type a new one. Delete clears it, Esc cancels.") {
            matrix(title: "Directions", columns: ["Focus", "Move", "Group with"], rows: directions.map { d in
                (AnyView(Label(d.1, systemImage: d.2).labelStyle(DirectionLabelStyle())), ["focus \(d.0)", "move \(d.0)", "join \(d.0)"])
            })

            SettingSection(title: "Focused window") {
                ForEach(windowCommands, id: \.0) { command in
                    SettingRow(title: command.1) { ShortcutCell(model: model, commandText: command.0) }
                }
            }

            matrix(title: "Desktops", columns: ["Go to", "Take the window to"], rows: desktops.map { d in
                (AnyView(Text(d.1)), ["space \(d.0)", "move-to-space \(d.0)"])
            })

            matrix(title: "Displays", columns: ["Focus", "Take the window to"], rows: displays.map { d in
                (AnyView(Text(d.1)), ["focus-display \(d.0)", "move-to-display \(d.0)"])
            })

            SettingSection(title: "Other commands", footer: "Any command Iguana understands can have a shortcut. Type it, then record the keys.") {
                ForEach(model.customBindings, id: \.source) { binding in
                    SettingRow(title: binding.commandText) { ShortcutCell(model: model, commandText: binding.commandText) }
                }
                HStack(spacing: 12) {
                    TextField("Command", text: $customCommand, prompt: Text("move-to-space 3 --stay"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Command for a new shortcut")
                    Spacer()
                    RecorderButton(model: model, slot: "custom|new", onClear: nil, onRecorded: { keys in
                        model.bind(keys, to: customText, replacing: nil)
                        customCommand = ""
                    }) {
                        Text("Record shortcut").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11).frame(height: 24)
                            .background(Capsule().fill(Theme.well))
                    }
                    .disabled(customText.isEmpty || customProblem != nil)
                    .opacity(customText.isEmpty || customProblem != nil ? 0.45 : 1)
                }
                if let customProblem { Callout(.attention, customProblem) }
            }

            SettingSection {
                HStack {
                    Text("In the settings file, ⌥ is written option.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore built-in shortcuts") { model.resetShortcuts() }
                        .glassButton()
                        .disabled(!model.shortcutsDifferFromBuiltIn)
                }
            }
        }
        .onDisappear { model.stopRecording() }
    }

    /// Commands that are one verb applied to several targets, as a table: targets down, verbs across.
    private func matrix(title: String, columns: [String], rows: [(AnyView, [String])]) -> some View {
        SettingSection(title: title) {
            HStack(spacing: 16) {
                Color.clear.frame(width: 150, height: 1)
                ForEach(columns, id: \.self) { column in
                    Text(column)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    row.0.frame(width: 150, alignment: .leading)
                    ForEach(row.1, id: \.self) { command in
                        ShortcutCell(model: model, commandText: command)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct DirectionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 14)
            configuration.title
        }
    }
}
