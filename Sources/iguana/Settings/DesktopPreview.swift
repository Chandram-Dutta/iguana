import AppKit
import IguanaCore
import SwiftUI

/// A miniature of the desktop: the windows that are on it now, laid out by the same engine that
/// lays out the real ones, with the gaps drawn to scale. Moving a slider moves these tiles and
/// your real windows together.
struct DesktopPreview: View {
    let config: Config
    let data: DesktopPreviewData
    /// Each step rotates the windows through the slots, to show how a move looks.
    var shuffle = 0
    var cornerRadius: CGFloat = 10
    /// Set to make the windows clickable.
    var onSelect: ((WindowID) -> Void)?

    /// The width that shows the whole screen at a given height.
    static func width(forHeight height: CGFloat, data: DesktopPreviewData) -> CGFloat {
        height * data.screen.width / max(data.screen.height, 1)
    }

    private struct Tile: Identifiable {
        let id: WindowID
        let frame: CGRect
        let icon: NSImage?
        let focused: Bool
    }

    private func tiles(in size: CGSize) -> [Tile] {
        let scale = size.width / data.screen.width
        let outer = config.gapOuter
        let usable = CGRect(x: (data.usable.minX + outer.left) * scale,
                            y: (data.usable.minY + outer.top) * scale,
                            width: (data.usable.width - outer.left - outer.right) * scale,
                            height: (data.usable.height - outer.top - outer.bottom) * scale)
        let tree = Tree(snapshot: data.layout)
        let slots = computeLayout(tree, in: usable, gap: config.gapInner * scale, visible: data.visible)
        // Keep a stable order so that the same window keeps its identity while it travels.
        let order = tree.windows.filter { slots[$0] != nil }
        guard !order.isEmpty else { return [] }
        return order.enumerated().map { index, id in
            let slot = order[(index + shuffle) % order.count]
            return Tile(id: id, frame: slots[slot] ?? .zero, icon: data.icons[id], focused: id == data.focused)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let aspect = data.screen.width / max(data.screen.height, 1)
            let width = min(geometry.size.width, geometry.size.height * aspect)
            let size = CGSize(width: width, height: width / aspect)
            let scale = size.width / data.screen.width

            ZStack(alignment: .topLeading) {
                LinearGradient(stops: [.init(color: Theme.canopy, location: 0), .init(color: Theme.fern, location: 0.55),
                                       .init(color: Theme.moss, location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // The menu bar, to scale.
                Rectangle()
                    .fill(.black.opacity(0.22))
                    .frame(width: size.width, height: max(data.usable.minY * scale, 0))

                ForEach(tiles(in: size)) { tile in
                    TileView(icon: tile.icon, focused: tile.focused, size: tile.frame.size, select: onSelect.map { select in { select(tile.id) } })
                        .frame(width: max(tile.frame.width, 0), height: max(tile.frame.height, 0))
                        .position(x: tile.frame.midX, y: tile.frame.midY)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: cornerRadius * 1.4, y: cornerRadius * 0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: onSelect == nil ? .ignore : .contain)
        .accessibilityLabel(data.isExample ? "Example desktop with three tiled windows" : "Your desktop with \(data.visible.count) tiled windows")
    }
}

private struct TileView: View {
    let icon: NSImage?
    let focused: Bool
    let size: CGSize
    var select: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        // Slightly see-through, so the wallpaper tints the windows the way a real desktop does.
        let surface = scheme == .dark ? Color(white: 0.10).opacity(0.80) : Color.white.opacity(0.86)
        let iconSide = min(34, min(size.width, size.height) * 0.42)
        let radius = min(4.5, min(size.width, size.height) * 0.16)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(surface)
            .overlay(alignment: .topLeading) {
                // The three window buttons, when there is room for them.
                if size.width > 40, size.height > 22 {
                    HStack(spacing: 2.5) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.primary.opacity(0.18)).frame(width: 3.5, height: 3.5) }
                    }
                    .padding(5)
                }
            }
            .overlay {
                if let icon, iconSide >= 12 {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: iconSide, height: iconSide)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(focused ? Theme.moss : Color.black.opacity(0.18), lineWidth: focused ? 1.5 : 0.5))
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
            .scaleEffect(hovering && select != nil ? 1.025 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { select?() }
            .accessibilityAddTraits(select == nil ? [] : .isButton)
    }
}
