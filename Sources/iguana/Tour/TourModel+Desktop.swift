import IguanaCore
import SwiftUI

/// An outline on the play desktop that shows where a window is meant to end up.
struct TourGhost: Equatable {
    let desktop: Int
    let rect: CGRect
    let window: WindowID
}

/// A window of the play desktop, placed.
struct TourTile: Identifiable, Equatable {
    let id: WindowID
    let desktop: Int
    let rect: CGRect
    let color: Int
    let focused: Bool
    /// How near the front the window is: the higher, the nearer. It matters where windows
    /// overlap, which is in a stack.
    var layer = 0
}

extension TourModel {
    // MARK: The play desktop

    var gaps: (outer: CGFloat, inner: CGFloat) { overview ? (11, 9) : (20, 16) }

    /// How much of each window of a stack shows beside the one in front. More than on a real
    /// screen, where it is `stack-peek`: here a strip has to hold the three buttons that make a
    /// coloured shape read as a window.
    var peek: CGFloat { overview ? 44 : 88 }

    /// Where a desktop sits on the stage. One fills it; in the overview all three stand in a row.
    func panel(_ index: Int) -> CGRect {
        let stage = Self.stage
        guard overview else {
            return CGRect(x: CGFloat(index - current) * (stage.width + 180), y: 0, width: stage.width, height: stage.height)
        }
        let spacing: CGFloat = 56
        let total: CGFloat = 2600
        let width = (total - spacing * CGFloat(Self.desktopCount - 1)) / CGFloat(Self.desktopCount)
        let height = width * stage.height / stage.width
        let left = (stage.width - total) / 2
        return CGRect(x: left + CGFloat(index) * (width + spacing), y: (stage.height - height) / 2, width: width, height: height)
    }

    func frames(_ index: Int, tree: Tree? = nil) -> [WindowID: CGRect] {
        computeLayout(tree ?? desktops[index], in: panel(index).insetBy(dx: gaps.outer, dy: gaps.outer), gap: gaps.inner, peek: peek)
    }

    var tiles: [TourTile] {
        desktops.indices.flatMap { index -> [TourTile] in
            let placed = frames(index)
            let focused = desktops[index].focused
            return desktops[index].windows.compactMap { id in
                placed[id].map {
                    TourTile(id: id, desktop: index, rect: $0, color: colors[id] ?? 0, focused: index == current && id == focused,
                             layer: order.count - (order.firstIndex(of: id) ?? order.count))
                }
            }
        }
    }

    /// Two windows that lie over each other, which only the windows of a stack do.
    func overlap(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 1 && shared.height > 1
    }

    /// The middle of what shows of the window that calls for the focus. For a window behind
    /// others in a stack that is its strip, not the middle of the window.
    var beaconSpot: CGPoint? {
        let here = tiles.filter { $0.desktop == current }
        guard let beacon, let tile = here.first(where: { $0.id == beacon }) else { return nil }
        var showing = tile.rect
        for other in here where other.layer > tile.layer && overlap(other.rect, showing) {
            let cover = other.rect
            let slices = [
                CGRect(x: showing.minX, y: showing.minY, width: showing.width, height: cover.minY - showing.minY),
                CGRect(x: showing.minX, y: cover.maxY, width: showing.width, height: showing.maxY - cover.maxY),
                CGRect(x: showing.minX, y: showing.minY, width: cover.minX - showing.minX, height: showing.height),
                CGRect(x: cover.maxX, y: showing.minY, width: showing.maxX - cover.maxX, height: showing.height),
            ].filter { $0.width > 0 && $0.height > 0 }
            guard let largest = slices.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
            showing = largest
        }
        return CGPoint(x: showing.midX, y: showing.midY)
    }

    var focusedWindow: WindowID? { desktops[current].focused }
    var windowCount: Int { desktops[0].windows.count }

    /// Add a window the way the window manager does: beside the focused one, splitting its slot
    /// along the longer side.
    func adopt(_ id: WindowID, into index: Int, tree: Tree? = nil) {
        let tree = tree ?? desktops[index]
        let anchor = tree.focused.flatMap { tree.contains($0) ? $0 : nil } ?? tree.windows.last
        var split: Orientation?
        if let anchor, let frame = frames(index, tree: tree)[anchor] {
            split = frame.width >= frame.height ? .horizontal : .vertical
        }
        tree.insert(id, after: anchor, split: split)
        tree.focused = id
    }

    func copy(_ tree: Tree) -> Tree {
        let twin = Tree(snapshot: tree.snapshot)
        twin.focused = tree.focused
        return twin
    }

    func touch(_ id: WindowID?) {
        guard let id else { return }
        clock += 1
        visits[id] = clock
    }

    func raise(_ id: WindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// Bring the windows of each stack into the order that shows a strip of every one, the
    /// focused window in front. The window manager does the same with real windows.
    func restack() {
        for tree in desktops {
            guard let id = tree.focused else { continue }
            tree.stackRaiseOrder(focused: id, frontToBack: order).forEach(raise)
        }
    }

    func changed(_ body: () -> Void) {
        withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
            body()
            restack()
            revision += 1
        }
    }
}
