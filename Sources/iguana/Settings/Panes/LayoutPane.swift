import AppKit
import IguanaCore
import SwiftUI

struct LayoutPane: View {
    @ObservedObject var model: SettingsModel
    @State private var perSide = false
    /// Looked at when the pane appears and when the user comes back to Iguana, which is how
    /// they return from switching it off in System Settings.
    @State private var systemTiles = SystemTiling.tilesDraggedWindows

    private var outer: Edges { model.config.gapOuter }
    private var outerIsUniform: Bool { outer.top == outer.left && outer.left == outer.bottom && outer.bottom == outer.right }
    private var showsEachEdge: Bool { perSide || !outerIsUniform }

    var body: some View {
        PaneScaffold(title: "Layout", subtitle: "How windows share the desktop.") {
            HStack(alignment: .center, spacing: 24) {
                DesktopPreview(config: model.config, data: model.preview)
                    .frame(width: DesktopPreview.width(forHeight: 172, data: model.preview), height: 172)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.preview.isExample ? "An example desktop" : "Your desktop, right now")
                        .font(Theme.rounded(13, .semibold))
                    Text(model.preview.isExample
                        ? "Open two or more windows and they appear here in place of the example."
                        : "These are your windows. They follow each setting as you change it, and so do the real ones.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        } content: {
            if systemTiles {
                SettingSection {
                    Callout(kind: .note, text: "macOS also tiles a window that is dragged to a screen edge, and shows an outline of its own. Iguana's layout wins when you let go. To see only Iguana's outline, turn off the options for tiling by dragging under Windows in Desktop & Dock.") {
                        Button("Open Desktop & Dock") { SystemTiling.openSettings() }
                            .controlSize(.small)
                    }
                }
            }
            SettingSection(title: "Gaps") {
                SettingRow(title: "Between windows") {
                    ValueSlider(label: "Gap between windows", value: model.config.gapInner, range: 0...40, step: 1, format: points) {
                        model.setNumber(["gaps", "inner"], $0)
                    }
                }
                if showsEachEdge {
                    edge("Top edge", \.top)
                    edge("Left edge", \.left)
                    edge("Bottom edge", \.bottom)
                    edge("Right edge", \.right)
                } else {
                    SettingRow(title: "Around the screen edge") {
                        ValueSlider(label: "Gap around the screen edge", value: outer.top, range: 0...60, step: 1, format: points) {
                            model.setOuterGap(Edges(all: $0))
                        }
                    }
                }
                SettingRow(title: "Set each edge separately") {
                    Toggle("Set each edge separately", isOn: SwiftUI.Binding(
                        get: { showsEachEdge },
                        set: { on in
                            perSide = on
                            if !on { model.setOuterGap(Edges(all: outer.top)) }
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingSection(title: "New windows") {
                SettingRow(title: "A new window",
                           detail: model.config.autoSplit
                               ? "Takes half of the focused window, cutting it along its longer side."
                               : "Joins the row or column of the focused window, and everything in it gets narrower.") {
                    Segmented(name: "A new window", options: [true, false], selection: model.config.autoSplit,
                              onSelect: { model.set(["layout", "auto-split"], .bool($0)) }) {
                        $0 ? "Splits the focused one" : "Joins its row"
                    }
                }
                SettingRow(title: "Resize step", detail: "How far one press of grow or shrink moves the divider.") {
                    ValueSlider(label: "Resize step", value: model.config.resizeStep * 100, range: 1...20, step: 1,
                                format: { "\(Int($0.rounded())) %" }) {
                        model.set(["layout", "resize-step"], .double($0 / 100))
                    }
                }
                SettingRow(title: "Stack peek", detail: "How much of each window in a stack shows behind the one in front.") {
                    ValueSlider(label: "Stack peek", value: model.config.stackPeek, range: 8...120, step: 4, format: points) {
                        model.setNumber(["layout", "stack-peek"], $0)
                    }
                }
                SettingRow(title: "Pointer follows focus", detail: "Move the pointer to a window when a shortcut focuses it.") {
                    Toggle("Pointer follows focus", isOn: SwiftUI.Binding(
                        get: { model.config.mouseFollowsFocus }, set: { model.set(["layout", "mouse-follows-focus"], .bool($0)) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingRow(title: "Focus follows pointer", detail: "Focus the window the pointer comes to rest on, without a click.") {
                    Toggle("Focus follows pointer", isOn: SwiftUI.Binding(
                        get: { model.config.focusFollowsMouse }, set: { model.set(["layout", "focus-follows-mouse"], .bool($0)) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingSection(title: "Stage Manager") {
                SettingRow(title: "Leave room for the strip of recent apps", detail: "Only matters while Stage Manager is on.") {
                    Segmented(name: "Leave room for the strip of recent apps", options: [0, 1, 2], selection: stripChoice, onSelect: setStrip) {
                        ["While it shows", "Always", "Never"][$0]
                    }
                }
                if stripChoice != 2 {
                    SettingRow(title: "Room to leave") {
                        ValueSlider(label: "Room for the Stage Manager strip", value: stripWidth, range: 60...300, step: 5, format: points) { width in
                            if stripChoice == 1 {
                                model.setNumber(["stage-manager", "reserve-strip"], width)
                            } else {
                                model.setNumber(["stage-manager", "strip-width"], width)
                            }
                        }
                    }
                }
            }

            FocusRingSection(model: model)
        }
        .onAppear { systemTiles = SystemTiling.tilesDraggedWindows }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemTiles = SystemTiling.tilesDraggedWindows
        }
    }

    private func edge(_ title: String, _ key: WritableKeyPath<Edges, Double>) -> some View {
        SettingRow(title: title) {
            ValueSlider(label: title, value: outer[keyPath: key], range: 0...60, step: 1, format: points) { v in
                var e = outer
                e[keyPath: key] = v
                // Four equal values would otherwise fold the sliders back into one mid-drag.
                perSide = true
                model.setOuterGap(e)
            }
        }
    }

    private var stripChoice: Int {
        switch model.config.stripReserve {
        case .auto: return 0
        case .points: return 1
        case .off: return 2
        }
    }

    private var stripWidth: Double {
        if case .points(let p) = model.config.stripReserve { return p }
        return model.config.stripWidth
    }

    private func setStrip(_ choice: Int) {
        switch choice {
        case 0: model.set(["stage-manager", "reserve-strip"], .string("auto"))
        case 1: model.setNumber(["stage-manager", "reserve-strip"], stripWidth)
        default: model.set(["stage-manager", "reserve-strip"], .bool(false))
        }
    }
}

private func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }
