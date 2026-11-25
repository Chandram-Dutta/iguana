import AppKit
import SwiftUI

// MARK: Backdrop

/// Daylight through leaves: a pale ground with a few slow patches of green light.
struct Backdrop: View {
    let still: Bool
    @Environment(\.tourPalette) private var palette
    @State private var drift = false

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                LinearGradient(colors: [palette.top.opacity(palette.wash), palette.bottom.opacity(palette.wash)], startPoint: .top, endPoint: .bottom)
                patch(palette.glowA, side: w * 0.95)
                    .position(x: w * (drift ? 0.20 : 0.10), y: h * (drift ? 0.96 : 0.82))
                patch(palette.glowB, side: w * 0.80)
                    .position(x: w * (drift ? 0.84 : 0.94), y: h * (drift ? 0.10 : 0.26))
                patch(palette.glowA.opacity(0.55), side: w * 0.55)
                    .position(x: w * (drift ? 0.70 : 0.58), y: h * (drift ? 1.02 : 0.92))
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .onAppear {
            guard !still else { return }
            withAnimation(.easeInOut(duration: 13).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
    }

    private func patch(_ color: Color, side: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: side / 2))
            .frame(width: side, height: side)
            .scaleEffect(x: 1, y: 0.82)
    }
}

/// The logo from the app bundle, or the drawn mark when running outside one.
struct TourLogo: View {
    private static let image: NSImage? = Bundle.main.image(forResource: "logo-large") ?? Bundle.main.image(forResource: "logo")

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                IguanaMark().padding(4)
            }
        }
        .accessibilityHidden(true)
    }
}
