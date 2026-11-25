import IguanaCore
import SwiftUI

struct HooksPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PaneScaffold(title: "Hooks", subtitle: "Commands Iguana runs when something changes, for status bars and scripts.") {
            SettingSection {
                Callout(.attention, "Each command runs with /bin/sh and gets the facts as environment variables. A window title can be any text: write \"$IGUANA_TITLE\" with the double quotes, and never pass it to eval.")
            }
            SettingSection(footer: "A command is saved when you press Return or leave its field. An empty field runs nothing. The configuration reference lists the variables each event gets.") {
                ForEach(HookEvent.allCases, id: \.self) { HookRow(model: model, event: $0) }
            }
        }
    }
}

/// One event and its command. What is typed is written to the file when it is committed, not
/// on every key, so that a half-typed command never runs.
private struct HookRow: View {
    @ObservedObject var model: SettingsModel
    let event: HookEvent
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.rawValue).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                Text(event.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            TextField(event.rawValue, text: $text, prompt: Text("Runs nothing"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .focused($editing)
                .onSubmit(commit)
                .accessibilityLabel("Command for \(event.rawValue)")
        }
        .padding(.vertical, 2)
        .onAppear { text = model.hookCommand(event) }
        .onChange(of: editing) { if !editing { commit() } }
        // A change saved in the file shows up here, unless the field is being typed in.
        .onChange(of: model.config.hooks[event]) { if !editing { text = model.hookCommand(event) } }
        .onDisappear(perform: commit)
    }

    private func commit() { model.setHook(event, text) }
}
