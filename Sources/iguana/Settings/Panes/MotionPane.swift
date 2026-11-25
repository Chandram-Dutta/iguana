import AppKit
import IguanaCore
import SwiftUI

struct MotionPane: View {
    @ObservedObject var model: SettingsModel
    @State private var shuffle = 0

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var animation: Animation? {
        model.config.animate ? model.config.animationEasing.animation(duration: model.config.animationDuration) : nil
    }

    var body: some View {
        PaneScaffold(title: "Animation", subtitle: "How windows travel to their new place.") {
            HStack(alignment: .center, spacing: 24) {
                DesktopPreview(config: model.config, data: model.preview, shuffle: shuffle)
                    .animation(animation, value: shuffle)
                    .frame(width: DesktopPreview.width(forHeight: 172, data: model.preview), height: 172)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try the current settings on the preview before your real windows.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        shuffle += 1
                    } label: {
                        Label("Play a move", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
                    }
                    .glassButton()
                }
                Spacer(minLength: 0)
            }
        } content: {
            if reduceMotion {
                SettingSection {
                    Callout(.note, "Reduce Motion is on in System Settings, so windows are placed at once whatever is chosen here.")
                }
            }

            SettingSection(footer: "macOS cannot move another app's window without that app redrawing it. Apps that redraw slowly, such as browsers, skip frames and look less smooth than light apps. A shorter duration hides that best.") {
                SettingRow(title: "Animate window changes", detail: "Windows glide when one opens, closes, moves or is resized.") {
                    Toggle("Animate window changes", isOn: SwiftUI.Binding(
                        get: { model.config.animate },
                        set: {
                            model.set(["animation", "enabled"], .bool($0))
                            play()
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingRow(title: "Duration") {
                    ValueSlider(label: "Animation duration", value: model.config.animationDuration * 1000, range: 50...600, step: 10,
                                format: { "\(Int($0.rounded())) ms" }) {
                        model.set(["animation", "duration"], .double($0 / 1000))
                    }
                }
                .disabled(!model.config.animate)
                .opacity(model.config.animate ? 1 : 0.45)
                SettingRow(title: "Pacing") {
                    HStack(spacing: 10) {
                        EasingGlyph(easing: model.config.animationEasing).foregroundStyle(.secondary)
                        Segmented(name: "Pacing", options: [Easing.easeOut, .easeInOut, .linear], selection: model.config.animationEasing,
                                  onSelect: {
                                      model.set(["animation", "easing"], .string($0.rawValue))
                                      play()
                                  }) { $0.title }
                    }
                }
                .disabled(!model.config.animate)
                .opacity(model.config.animate ? 1 : 0.45)
            }
        }
    }

    private func play() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shuffle += 1 }
    }
}
