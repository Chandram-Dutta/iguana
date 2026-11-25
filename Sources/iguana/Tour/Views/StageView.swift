import IguanaCore
import SwiftUI

/// The play desktop: its windows, the outline that shows where one should go, and the mark that
/// calls for the focus. Everything is placed in the model's units and scaled here.
struct StageView: View {
    @ObservedObject var model: TourModel
    let height: CGFloat
    @Environment(\.tourPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop = false

    var body: some View {
        GeometryReader { geometry in
            let scale = height / TourModel.stage.height
            let left = (geometry.size.width - TourModel.stage.width * scale) / 2
            let compact = model.overview
            let place: (CGRect) -> CGRect = { r in
                CGRect(x: left + r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            }
            let tiles = model.tiles

            ZStack(alignment: .topLeading) {
                ForEach(0..<TourModel.desktopCount, id: \.self) { index in
                    let frame = place(model.panel(index))
                    let isCurrent = index == model.current
                    let visible = model.overview || isCurrent
                    // The desktop is a slab of glass; the windows on it are the content.
                    Color.clear
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .glass(RoundedRectangle(cornerRadius: compact ? 15 : 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: compact ? 15 : 24, style: .continuous)
                            .strokeBorder(palette.ink, lineWidth: 2.5).opacity(compact && isCurrent ? 1 : 0))
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(visible ? 1 : 0)

                    if model.desktopBeacon == index {
                        Beacon()
                            .position(x: frame.midX, y: frame.midY)
                            .zIndex(4)
                            .transition(.scale.combined(with: .opacity))
                    }

                    DesktopNumber(number: index + 1, current: isCurrent, calling: model.desktopBeacon == index)
                        .position(x: frame.midX, y: frame.maxY + 30)
                        .opacity(model.overview ? 1 : 0)
                }

                if model.step == .open, tiles.isEmpty {
                    let frame = place(model.panel(0))
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(palette.faint)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                }

                ForEach(Array(tiles.enumerated()), id: \.element.id) { order, tile in
                    let frame = place(tile.rect)
                    TileView(color: palette.tile(tile.color), focused: tile.focused, compact: compact, size: frame.size)
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .scaleEffect(hop ? 1.035 : 1)
                        .animation(.spring(response: 0.28, dampingFraction: 0.5).delay(Double(order) * 0.05), value: hop)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(model.overview || tile.desktop == model.current ? 1 : 0)
                        // Between 1 and 2, in the order the windows lie in. It shows in a stack.
                        .zIndex(tile.focused ? 2 : 1 + Double(tile.layer) / Double(tiles.count + 1))
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                }

                // The call for the focus is drawn over the windows, on the part of its window
                // that shows: in a stack that is a strip, and a mark inside the window would be
                // cut off by the window in front.
                if let spot = model.beaconSpot {
                    Beacon()
                        .position(x: left + spot.x * scale, y: spot.y * scale)
                        .zIndex(4)
                        .id(model.beacon)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                if let ghost = model.ghost {
                    let frame = place(ghost.rect)
                    GhostView(color: palette.tile(model.colors[ghost.window] ?? 0), compact: compact, still: reduceMotion)
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .position(x: frame.midX, y: frame.midY)
                        .zIndex(3)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: model.celebrations) { _, _ in
            guard !reduceMotion else { return }
            hop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { hop = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Practice desktop with \(model.tiles.count) windows")
    }
}

private struct DesktopNumber: View {
    let number: Int
    let current: Bool
    let calling: Bool
    @Environment(\.tourPalette) private var palette

    var body: some View {
        Text("\(number)")
            .font(Theme.rounded(14, .bold))
            .foregroundStyle(current ? palette.top : palette.soft)
            .frame(width: 28, height: 28)
            .background(Circle().fill(current ? palette.ink : palette.ink.opacity(0.08)))
            .background { if calling { Pulse(color: palette.ink).frame(width: 28, height: 28) } }
    }
}

/// A ring that spreads and fades, over and over: "here".
private struct Pulse: View {
    let color: Color
    @State private var spread = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 2)
            .scaleEffect(spread ? 2.5 : 1)
            .opacity(spread ? 0 : 0.85)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) { spread = true }
            }
    }
}

/// The mark that calls for attention: go here.
private struct Beacon: View {
    var body: some View {
        ZStack {
            Pulse(color: .white).frame(width: 30, height: 30)
            Circle().fill(.white).frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct TileView: View {
    let color: Color
    let focused: Bool
    let compact: Bool
    let size: CGSize
    @Environment(\.tourPalette) private var palette

    var body: some View {
        let radius: CGFloat = compact ? 8 : 15
        let mark = Color.black.opacity(0.17)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .overlay(alignment: .topLeading) {
                // Enough of a window to read as one: its three buttons and a few lines.
                VStack(alignment: .leading, spacing: compact ? 5 : 11) {
                    HStack(spacing: compact ? 3 : 6) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(mark).frame(width: compact ? 4.5 : 9, height: compact ? 4.5 : 9) }
                    }
                    if !compact, size.height > 120, size.width > 120 {
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule().fill(mark).frame(width: size.width * 0.34, height: 8)
                            Capsule().fill(mark.opacity(0.6)).frame(width: size.width * 0.52, height: 8)
                            Capsule().fill(mark.opacity(0.6)).frame(width: size.width * 0.26, height: 8)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(compact ? 7 : 15)
            }
            .overlay {
                // The outline of the animal itself, with a pale line inside it so that it also
                // shows on the darkest window.
                let line: CGFloat = compact ? 3 : 5
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.ink, lineWidth: line)
                    RoundedRectangle(cornerRadius: max(radius - line, 2), style: .continuous)
                        .strokeBorder(palette.top.opacity(0.85), lineWidth: compact ? 1 : 1.5)
                        .padding(line)
                }
                .opacity(focused ? 1 : 0)
            }
            .shadow(color: .black.opacity(focused ? 0.20 : 0.10), radius: focused ? 14 : 6, y: focused ? 7 : 3)
    }
}

private struct GhostView: View {
    let color: Color
    let compact: Bool
    let still: Bool
    @Environment(\.tourPalette) private var palette
    @State private var phase: CGFloat = 0

    var body: some View {
        let radius: CGFloat = compact ? 8 : 15
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color.opacity(0.42))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(palette.ink.opacity(0.75), style: StrokeStyle(lineWidth: compact ? 2 : 2.5, lineCap: .round, dash: [2, 9], dashPhase: phase)))
            .onAppear {
                guard !still else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = -11 }
            }
    }
}
