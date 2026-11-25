import AppKit
import IguanaCore
import SwiftUI

struct FloatingPane: View {
    @ObservedObject var model: SettingsModel
    @State private var rows: [RuleRow] = []
    @State private var loadedFrom: [Rule]?

    struct RuleRow: Identifiable {
        let id = UUID()
        var app: String
        var title: String
        /// False for an exception: windows that match are tiled even if a later rule would float them.
        /// Nil for a rule that only names a desktop or a display and says nothing about floating.
        var float: Bool? = true
        /// The desktop the rule sends new windows to.
        var desktop: Int?
        /// The display the rule sends new windows to, when it names no desktop.
        var display: DisplayRef?
        /// The size and the position the rule gives the windows it floats. The pane has no
        /// controls for them, and keeps them as the file has them.
        var size: CGSize?
        var position: Placement?
        /// A row the user is still typing the app into.
        var isDraft = false
    }

    var body: some View {
        // Asked once for the pane, not once for every row.
        let desktopCount = Desktop.all().count
        let screens = DisplayInfo.current()
        PaneScaffold(title: "Window Rules", subtitle: "Apps whose windows float instead of being tiled, or open on a desktop or a display of their own.") {
            if !Private.hasMoveBridge, rows.contains(where: { $0.desktop != nil }) {
                SettingSection {
                    Callout(.attention, "This version of macOS can only take a window to another desktop by going there with it, so the desktops chosen here are not used.")
                }
            }

            SettingSection {
                if rows.isEmpty {
                    Text("Nothing floats by rule. Every standard window is tiled. Add an app below to keep its windows where you put them.")
                        .foregroundStyle(.secondary)
                }
                ForEach($rows) { $row in
                    RuleRowView(row: $row, desktopCount: desktopCount, displayNames: screens.map(\.name), displayFrames: screens.map(\.frame), commit: commit) {
                        rows.removeAll { $0.id == row.id }
                        commit()
                    }
                }
            }

            SettingSection(footer: "Dialogs, sheets and windows that cannot be resized always float; they need no rule. To float one window for now, focus it and press the Float or tile shortcut. A window goes to the desktop or display chosen for it once, when it opens, and you stay where you are.") {
            HStack(spacing: 10) {
                Menu {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button {
                            rows.append(RuleRow(app: app.bundleIdentifier ?? app.localizedName ?? "", title: ""))
                            commit()
                        } label: {
                            Text(app.localizedName ?? app.bundleIdentifier ?? "App")
                            if let icon = app.icon { Image(nsImage: resized(icon, 16)) }
                        }
                    }
                    Divider()
                    Button("Another App…") { rows.append(RuleRow(app: "", title: "", isDraft: true)) }
                } label: {
                    Label("Add an App", systemImage: "plus")
                }
                .menuStyle(.button)
                .glassButton()
                .fixedSize()
                Spacer()
            }
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.config.rules) { load() }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func load() {
        guard model.config.rules != loadedFrom else { return }
        loadedFrom = model.config.rules
        let drafts = rows.filter { $0.isDraft && $0.app.trimmingCharacters(in: .whitespaces).isEmpty }
        rows = model.config.rules.map(RuleRow.init) + drafts
    }

    private func commit() {
        let rules = rows.compactMap(\.rule)
        for i in rows.indices where !rows[i].app.trimmingCharacters(in: .whitespaces).isEmpty { rows[i].isDraft = false }
        loadedFrom = rules
        model.setRules(rules)
    }
}

extension FloatingPane.RuleRow {
    init(_ rule: Rule) {
        self.init(app: rule.app ?? "", title: rule.title ?? "", float: rule.float, desktop: rule.desktop,
                  display: rule.display, size: rule.size, position: rule.position)
    }

    /// The rule the row stands for. Nil while it has neither an app nor a title.
    var rule: Rule? {
        let app = app.trimmingCharacters(in: .whitespaces), title = title.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty || !title.isEmpty else { return nil }
        return Rule(app: app.isEmpty ? nil : app, title: title.isEmpty ? nil : title, float: float, desktop: desktop,
                    display: display, size: size, position: position)
    }
}

private func resized(_ image: NSImage, _ side: CGFloat) -> NSImage {
    let copy = image.copy() as? NSImage ?? image
    copy.size = NSSize(width: side, height: side)
    return copy
}
