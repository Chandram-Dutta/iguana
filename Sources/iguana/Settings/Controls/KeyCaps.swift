import IguanaCore
import SwiftUI

/// One key of a shortcut, drawn as a key.
struct KeyCap: View {
    let text: String
    var dimmed = false

    var body: some View {
        Text(text)
            .font(Theme.rounded(12, .medium))
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .frame(minWidth: 13)
            .padding(.horizontal, 5)
            .frame(height: 22)
            // A flat, see-through key: the window is glass, and a raised white key would sit on it
            // like a sticker.
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.075)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// A shortcut as a row of keys: ⌥ ⇧ H.
struct KeyCaps: View {
    let combo: KeyCombo

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(ShortcutFormat.keys(combo).enumerated()), id: \.offset) { _, key in
                KeyCap(text: key)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShortcutFormat.spoken(combo))
    }
}
