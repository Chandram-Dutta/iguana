import AppKit
import IguanaCore
import SwiftUI

/// The `[focus-ring]` group of the Layout pane: on or off, how thick, and which colour.
struct FocusRingSection: View {
    @ObservedObject var model: SettingsModel
    /// The colour "Custom" starts from, and goes back to after a spell of the accent colour.
    @State private var lastCustom = RingColor.custom(red: 0x8f / 255.0, green: 0xd4 / 255.0, blue: 0x3f / 255.0, alpha: 1)

    private var ring: FocusRingSettings { model.config.focusRing }
    private var isCustom: Bool { ring.color != .accent }

    var body: some View {
        SettingSection(title: "Focus ring") {
            SettingRow(title: "Ring around the focused window", detail: "Drawn just outside the window, tiled or floating.") {
                Toggle("Ring around the focused window", isOn: SwiftUI.Binding(
                    get: { ring.enabled }, set: { model.set(["focus-ring", "enabled"], .bool($0)) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                SettingRow(title: "Width") {
                    ValueSlider(label: "Width of the focus ring", value: ring.width, range: 1...10, step: 1,
                                format: { "\(Int($0.rounded())) pt" }) {
                        model.setNumber(["focus-ring", "width"], $0)
                    }
                }
                SettingRow(title: "Colour", detail: isCustom ? nil : "Follows the accent colour chosen in System Settings.") {
                    HStack(spacing: 10) {
                        if isCustom {
                            // The system's colour well, which opens the system's colour panel.
                            ColorPicker("Colour of the focus ring", selection: SwiftUI.Binding(get: { Color(nsColor: ring.color.nsColor) }, set: choose))
                                .labelsHidden()
                        }
                        Segmented(name: "Colour of the focus ring", options: [false, true], selection: isCustom,
                                  onSelect: { setColor($0 ? lastCustom : .accent) }) {
                            $0 ? "Custom" : "Accent colour"
                        }
                    }
                }
            }
            .disabled(!ring.enabled)
            .opacity(ring.enabled ? 1 : 0.45)
        }
        .onAppear(perform: remember)
        .onChange(of: ring.color) { remember() }
    }

    private func remember() {
        if isCustom { lastCustom = ring.color }
    }

    private func choose(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
        setColor(.custom(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent)))
    }

    private func setColor(_ color: RingColor) {
        // What the file can say: a colour is written with two hex digits for each part.
        guard color.text != ring.color.text else { return }
        model.set(["focus-ring", "color"], .string(color.text))
    }
}
