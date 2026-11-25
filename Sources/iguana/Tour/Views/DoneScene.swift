import IguanaCore
import SwiftUI

// MARK: Done

struct DoneScene: View {
    @ObservedObject var model: TourModel
    let size: CGSize
    let k: CGFloat
    @Environment(\.tourPalette) private var palette

    private struct Line: Identifiable {
        let id: Int
        let modifiers: [Modifier]
        let keys: [String]
        let text: String
        /// For a line about the mouse, which has no keys: a picture in their place.
        var symbol: String?
    }

    private var lines: [Line] {
        var out: [Line] = []
        func add(_ step: TourStep, _ text: String, keys override: [String]? = nil) {
            guard let keys = model.keys(for: step), !keys.modifiers.isEmpty else { return }
            out.append(Line(id: out.count, modifiers: keys.modifiers, keys: override ?? keys.keys.map(\.label), text: text))
        }
        add(.focus, "Move between windows")
        add(.move, "Take a window along")
        add(.resize, "Make it smaller or larger")
        add(.stack, "Stack a row or column")
        if let jump = model.bindings.first(where: { $0.command == .space(.index(1)) }) {
            let order: [Modifier] = [.ctrl, .option, .shift, .cmd]
            out.append(Line(id: out.count, modifiers: order.filter(jump.combo.modifiers.contains), keys: ["1", "…", "9"],
                            text: "Jump to a desktop. Add shift to bring the window."))
        }
        out.append(Line(id: out.count, modifiers: [], keys: [], text: "Drag a window. An outline shows where it lands.",
                        symbol: "cursorarrow"))
        return out
    }

    private static let symbols: [Modifier: String] = [.ctrl: "⌃", .option: "⌥", .shift: "⇧", .cmd: "⌘"]

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: size.height * 0.225 + 48 * k + 30 * k)
            Headline(title: "You know your way around", detail: "Iguana sits in the menu bar. Every key can be changed in its settings.", k: k)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 14) {
                        HStack(spacing: 4) {
                            if let symbol = line.symbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(palette.ink.opacity(0.8))
                                    .frame(minWidth: 22, minHeight: 20)
                                    .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(palette.ink.opacity(0.08)))
                                    .accessibilityHidden(true)
                            }
                            ForEach(line.modifiers, id: \.self) { MiniCap(text: Self.symbols[$0] ?? "") }
                            ForEach(Array(line.keys.enumerated()), id: \.offset) { _, key in
                                if key == "…" {
                                    Text("…").font(Theme.rounded(12, .medium)).foregroundStyle(palette.faint)
                                } else {
                                    MiniCap(text: key)
                                }
                            }
                        }
                        .frame(width: 178, alignment: .leading)
                        Text(line.text).font(.system(size: 15, design: .rounded))
                        Spacer(minLength: 0)
                    }
                    // On the lowest screens six lines at full height push the button off the bottom.
                    .frame(height: size.height < 720 ? 38 : 44)
                    .overlay(alignment: .bottom) {
                        if line.id != lines.count - 1 { Rectangle().fill(palette.panelLine).frame(height: 1) }
                    }
                }
            }
            .frame(width: 590)
            .padding(.horizontal, 22)
            .padding(.vertical, 4)
            .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.top, 30 * k)

            Button {
                model.setLaunchAtLogin(!model.launchAtLogin)
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(model.launchAtLogin ? palette.lit : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .strokeBorder(model.launchAtLogin ? .clear : palette.faint, lineWidth: 1.5))
                        if model.launchAtLogin {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(palette.litInk)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(model.launchAtLoginError ?? "Open Iguana when I log in")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(palette.soft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 30 * k)
            .accessibilityAddTraits(model.launchAtLogin ? .isSelected : [])

            Prompt(label: "Start tiling", action: model.primary)
                .padding(.top, 26 * k)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
