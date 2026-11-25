import SwiftUI

/// The colours of the tour, taken from the animal: its greens for the windows, its outline for
/// the type, and one sun-warmed amber. The fifth window colour, a blue-green, is for the window
/// that opens in the stack lesson, so that the amber one is still the only one of its kind.
struct TourPalette {
    let top, bottom, glowA, glowB: Color
    let ink, soft, faint: Color
    let panel, panelLine: Color
    let tiles: [Color]
    let key, keyLip, keyLine: Color
    let lit, litInk: Color
    /// How much of the tour's own colour lies over the blurred desktop.
    let wash: Double

    private static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: alpha)
    }

    static func make(_ scheme: ColorScheme) -> TourPalette {
        if scheme == .dark {
            let ink = hex(0xEAF6DA)
            return TourPalette(
                top: hex(0x06191A), bottom: hex(0x0C3B2E), glowA: hex(0x18A67E, 0.34), glowB: hex(0x8FD43F, 0.13),
                ink: ink, soft: ink.opacity(0.66), faint: ink.opacity(0.34),
                panel: Color.white.opacity(0.05), panelLine: Color.white.opacity(0.10),
                tiles: [hex(0x18A67E), hex(0x8FD43F), hex(0xD5F0A0), hex(0xF2B84B), hex(0x62C6CF)],
                key: Color.white.opacity(0.11), keyLip: Color.black.opacity(0.45), keyLine: Color.white.opacity(0.14),
                lit: hex(0x8FD43F), litInk: hex(0x0C3B2E), wash: 0.5)
        }
        let ink = hex(0x0C3B2E)
        return TourPalette(
            top: hex(0xF5F4EC), bottom: hex(0xE2F0CC), glowA: hex(0xC3E86E, 0.62), glowB: hex(0x74CB70, 0.30),
            ink: ink, soft: ink.opacity(0.64), faint: ink.opacity(0.32),
            panel: ink.opacity(0.05), panelLine: ink.opacity(0.09),
            tiles: [hex(0x18A67E), hex(0x8FD43F), hex(0x0F6A52), hex(0xF2B84B), hex(0x62C6CF)],
            key: .white, keyLip: ink.opacity(0.26), keyLine: ink.opacity(0.13),
            lit: hex(0x18A67E), litInk: .white, wash: 0.5)
    }

    func tile(_ index: Int) -> Color { tiles[((index % tiles.count) + tiles.count) % tiles.count] }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = TourPalette.make(.light)
}

extension EnvironmentValues {
    var tourPalette: TourPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
