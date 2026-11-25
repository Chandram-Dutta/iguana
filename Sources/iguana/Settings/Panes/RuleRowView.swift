import AppKit
import IguanaCore
import SwiftUI
import UniformTypeIdentifiers

struct RuleRowView: View {
    @SwiftUI.Binding var row: FloatingPane.RuleRow
    /// How many desktops there are now, 0 when that is not known.
    let desktopCount: Int
    /// The connected displays, in the same order in both.
    let displayNames: [String]
    let displayFrames: [CGRect]
    let commit: () -> Void
    let remove: () -> Void

    private var floats: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(get: { row.float ?? false }, set: { on in
            // Switched off, a rule that names a desktop or a display says nothing about floating.
            // One that names neither has to say `float = false`, or it would mean a floating rule again.
            row.float = on ? true : (row.desktop == nil && row.display == nil ? false : nil)
            commit()
        })
    }

    private var desktop: SwiftUI.Binding<Int?> {
        SwiftUI.Binding(get: { row.desktop }, set: { n in
            if n == nil, row.float == nil, row.display == nil { row.float = false }
            // A desktop belongs to one display, so it decides where the windows go.
            if n != nil { row.display = nil }
            row.desktop = n
            commit()
        })
    }

    private var display: SwiftUI.Binding<DisplayRef?> {
        SwiftUI.Binding(get: { row.display }, set: { d in
            if d == nil, row.float == nil, row.desktop == nil { row.float = false }
            row.display = d
            commit()
        })
    }

    /// The desktops to offer: the ones there are, and the one the rule names if it is beyond them.
    private var desktopsOffered: ClosedRange<Int> {
        1...max(desktopCount > 0 ? desktopCount : 9, row.desktop ?? 1)
    }

    /// The app a rule names, looked up for its proper name and icon.
    private var app: (name: String, icon: NSImage) {
        let text = row.app.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        if !text.isEmpty, let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(text) == true
        }), let icon = running.icon {
            return (text, icon)
        }
        return (text.isEmpty ? "Any app" : text, NSWorkspace.shared.icon(for: .application))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                if row.isDraft {
                    TextField("App", text: $row.app, prompt: Text("App name or bundle identifier"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(.system(size: 13, weight: .medium))
                        .onSubmit(commit)
                } else {
                    HStack(spacing: 7) {
                        Text(app.name).font(.system(size: 13, weight: .medium))
                        if row.float == false {
                            // An exception written in the settings file: these windows are tiled.
                            Text("Tiled, as an exception")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Capsule().fill(Theme.accent.opacity(0.13)))
                        }
                    }
                }
                TextField("Title", text: $row.title, prompt: Text("All windows, or a title pattern"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .onSubmit(commit)
                    .accessibilityLabel("Title pattern for \(app.name)")
            }
            Spacer(minLength: 8)
            // The switch carries no label of its own: inside a form, a labelled control takes the
            // row over as "label on the left, control on the right" and pushes the app out of it.
            HStack(spacing: 6) {
                Text("Float").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Toggle("Float", isOn: floats)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Float the windows of \(app.name)")
            }
            .fixedSize()
            .help("Keep these windows where you put them instead of tiling them")
            Picker("Desktop for \(app.name)", selection: desktop) {
                Text("Any Desktop").tag(Int?.none)
                Divider()
                ForEach(desktopsOffered, id: \.self) { n in
                    Text(desktopCount > 0 && n > desktopCount ? "Desktop \(n) (not there now)" : "Desktop \(n)").tag(Int?.some(n))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Send these windows to a desktop when they open. You stay where you are.")
            Picker("Display for \(app.name)", selection: display) {
                Text("Any Display").tag(DisplayRef?.none)
                Divider()
                ForEach(DisplayChoice.menu(for: row.display, names: displayNames, frames: displayFrames), id: \.self) { choice in
                    Text(choice.title).tag(DisplayRef?.some(choice.display))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(row.desktop != nil)
            .help(row.desktop == nil ? "Send these windows to a display when they open, onto the desktop it is showing. You stay where you are."
                : "The desktop chosen here decides, because a desktop belongs to one display.")
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove the rule for \(app.name)")
            .accessibilityLabel("Remove the rule for \(app.name)")
        }
        .padding(.vertical, 2)
    }
}
