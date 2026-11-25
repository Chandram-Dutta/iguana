import AppKit
import IguanaCore
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    private var path: String { model.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        PaneScaffold(title: "General", subtitle: "Startup, and where your settings are kept.") {
            if model.needsPermission {
                SettingSection {
                Callout(kind: .attention, text: "Iguana cannot move windows until it has Accessibility permission.") {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .glassButton()
                }
                }
            }

            SettingSection {
                SettingRow(title: "Open at login", detail: "Start tiling as soon as you log in to this Mac.") {
                    Toggle("Open at login", isOn: SwiftUI.Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if let error = model.loginItemError {
                    Callout(.attention, error)
                }
            }

            SettingSection(title: "Menu bar", footer: model.config.menuBarDesktops == .current
                ? "The icon in the menu bar is a drawing of the desktop you are on."
                : "Each desktop is drawn with its own layout.") {
                SettingRow(title: "Desktops drawn in the menu bar") {
                    Segmented(name: "Desktops drawn in the menu bar", options: [MenuBarDesktops.current, .occupied, .all],
                              selection: model.config.menuBarDesktops,
                              onSelect: { model.set(["menu-bar", "desktops"], .string($0.rawValue)) }) {
                        switch $0 {
                        case .current: return "This one"
                        case .occupied: return "Those in use"
                        case .all: return "All"
                        }
                    }
                }
                if model.config.menuBarDesktops != .current {
                    SettingRow(title: "Click a desktop to go to it",
                               detail: model.config.menuBarClickSwitches
                                   ? "A click on the desktop you are on opens the menu."
                                   : "A click anywhere on the item opens the menu.") {
                        Toggle("Click a desktop to go to it", isOn: SwiftUI.Binding(
                            get: { model.config.menuBarClickSwitches }, set: { model.set(["menu-bar", "click-to-switch"], .bool($0)) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            SettingSection(title: "Updates") {
                SettingRow(title: "Check for updates",
                           detail: "Once a day, ask GitHub whether a newer Iguana is out. Nothing about you is sent, and nothing is downloaded.") {
                    Toggle("Check for updates", isOn: SwiftUI.Binding(
                        get: { model.config.checkForUpdates }, set: { model.set(["updates", "check"], .bool($0)) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingRow(title: model.updateSummary(running: Iguana.version)) {
                    HStack(spacing: 8) {
                        if model.checkingForUpdate { ProgressView().controlSize(.small) }
                        if let update = model.updateOffered {
                            Button("Show Iguana \(update.version)…") { NSWorkspace.shared.open(update.page) }
                                .glassButton()
                                .help("Open the page of this release in your browser")
                        }
                        Button("Check Now") { model.checkForUpdate() }
                            .glassButton()
                            .disabled(model.checkingForUpdate)
                    }
                    .controlSize(.small)
                }
            }

            SettingSection(title: "Settings file") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Theme.accent)
                            .font(.system(size: 14))
                        Text(path)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Show in Finder") {
                            ensureFile()
                            NSWorkspace.shared.activateFileViewerSelecting([model.configURL])
                        }
                        .glassButton()
                        Button("Open") {
                            ensureFile()
                            NSWorkspace.shared.open(model.configURL)
                        }
                        .glassButton()
                    }
                    .controlSize(.small)
                    Text(model.fileExists
                        ? "This window and that file are the same settings. A change here rewrites only the value you changed and keeps your comments; a change you save in the file appears here."
                        : "There is no file yet, so the built-in settings apply. Your first change here creates it, with every setting explained in comments.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            if model.problems.isEmpty {
                if model.fileExists {
                    SettingSection { Callout(.good, "No problems in the settings file.") }
                }
            } else {
                SettingSection(title: model.problems.count == 1 ? "1 problem in the settings file" : "\(model.problems.count) problems in the settings file") {
                    ForEach(model.problems, id: \.self) { Callout(.attention, $0) }
                }
            }
        }
    }

    private func ensureFile() {
        if !model.fileExists { model.edit { _ in } }
    }
}
