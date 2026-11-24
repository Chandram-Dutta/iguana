import CoreGraphics
import Foundation

// Dragging a tiled window with the mouse and letting go of it over another tile.
//
// One function, `DragDrop.plan`, says what letting go right now would do and where the window
// would land. The outline that is drawn during the drag and the drop at the end both ask it,
// so that what was shown is what happens.

/// What letting go of a dragged tile does.
public enum Drop: Equatable {
    /// The dragged window and this one trade places.
    case trade(WindowID)
    /// The dragged window moves in right after this one, in the container this one is in.
    /// In a stack that makes it the next window of the stack.
    case join(WindowID)
    /// This window's tile is cut in two and the dragged window takes the half on this side.
    /// For a window in a stack it is the whole stack that is cut in two.
    case split(WindowID, Direction)
}

/// A drop, and the place it gives the dragged window.
public struct DropPlan: Equatable {
    public var drop: Drop
    /// The frame the layout gives the dragged window once the drop is done.
    public var rect: CGRect

    public init(drop: Drop, rect: CGRect) {
        self.drop = drop
        self.rect = rect
    }
}

/// What a drop is decided on. Rectangles are in the coordinates of the window list: measured
/// from the top-left corner of the primary display, y growing downwards.
public struct DropScene {
    /// The layout of one desktop being shown, and the area it is laid out in.
    public struct Desk {
        public var tree: Tree
        public var area: CGRect

        public init(tree: Tree, area: CGRect) {
            self.tree = tree
            self.area = area
        }
    }

    public var dragged: WindowID
    public var pointer: CGPoint
    /// The tile of every tiled window on screen, the dragged one's among them: where the
    /// layout has it, not where the user has dragged it to.
    public var tiles: [WindowID: CGRect]
    /// Windows on screen that are not tiles and that a drop does not go through: floating
    /// windows, dialogs, a zoomed window. With one of them under the pointer nothing is dropped.
    public var blockers: [WindowID: CGRect]
    /// The windows on screen as they are ordered now. Windows that are neither a tile nor a
    /// blocker are looked through.
    public var frontToBack: [WindowID]
    public var desks: [Desk]
    /// The windows on screen. The others keep their place in a tree and take no room.
    public var visible: Set<WindowID>
    public var gap: CGFloat
    public var peek: CGFloat
    public var minSizes: [WindowID: CGSize]

    public init(
        dragged: WindowID, pointer: CGPoint, tiles: [WindowID: CGRect], blockers: [WindowID: CGRect] = [:],
        frontToBack: [WindowID], desks: [Desk], visible: Set<WindowID>, gap: CGFloat = 0, peek: CGFloat = 32,
        minSizes: [WindowID: CGSize] = [:]
    ) {
        self.dragged = dragged
        self.pointer = pointer
        self.tiles = tiles
        self.blockers = blockers
        self.frontToBack = frontToBack
        self.desks = desks
        self.visible = visible
        self.gap = gap
        self.peek = peek
        self.minSizes = minSizes
    }
}

public enum DragDrop {
    /// A window that changed size by more than this many points was resized, and one that is
    /// no further than this from where it started has not gone anywhere.
    public static let slack: CGFloat = 3

    /// Whether the user is carrying the window somewhere. Dragging an edge changes the size,
    /// and that is a resize, not a move. `start` is the frame the window had before the mouse
    /// button went down, `now` the one it has.
    public static func isMove(from start: CGRect, to now: CGRect) -> Bool {
        guard abs(now.width - start.width) <= slack, abs(now.height - start.height) <= slack else { return false }
        return abs(now.minX - start.minX) > slack || abs(now.minY - start.minY) > slack
    }

    /// How deep the band along an edge of a tile is, for a tile this long across it: a quarter
    /// of the tile. Never under 48 points, so a small tile still has edges that can be hit.
    /// Never over 320, so on a large tile "the edge" stays near the edge. And never over a third
    /// of the tile, so there always is a middle.
    public static func band(_ length: CGFloat) -> CGFloat {
        min(max(length / 4, 48), 320, length / 3)
    }

    /// The edge of a tile that a point is at, or nil in the middle of the tile and outside it.
    /// In a corner two bands overlap. The edge the point is nearer to wins, each distance
    /// counted as a share of its band.
    public static func edge(at point: CGPoint, of tile: CGRect) -> Direction? {
        guard tile.contains(point) else { return nil }
        let across = band(tile.width), down = band(tile.height)
        let depths: [(side: Direction, depth: CGFloat)] = [
            (.left, (point.x - tile.minX) / across), (.right, (tile.maxX - point.x) / across),
            (.up, (point.y - tile.minY) / down), (.down, (tile.maxY - point.y) / down),
        ]
        return depths.filter { $0.depth < 1 }.min { $0.depth < $1.depth }?.side
    }

    /// The tile that is dropped on: the frontmost one under the pointer, the dragged window's
    /// own aside. The windows of a stack overlap, which is why the order matters. Nil over a
    /// gap, the menu bar, or a window that is no tile.
    public static func target(in scene: DropScene) -> WindowID? {
        for id in scene.frontToBack where id != scene.dragged {
            if scene.blockers[id]?.contains(scene.pointer) == true { return nil }
            if scene.tiles[id]?.contains(scene.pointer) == true { return id }
        }
        return nil
    }

    /// What letting go of the dragged window does with the pointer where it is, or nil when it
    /// does nothing and the window goes back to its tile.
    ///
    /// - Over the window's own tile: nothing. In a stack that tile is most of the stack.
    /// - Near an edge of a tile: the window takes that half of it.
    /// - In the middle of a tile: the two trade places.
    /// - A stack is one thing to drop on. Its edges are the edges of the whole stack, and a
    ///   window dropped there goes beside the stack. Dropped on its middle the window joins the
    ///   stack, after the window that was under the pointer.
    /// - A tile on another display takes the window in beside it when it is dropped on the
    ///   middle: the window that is there stays on its display.
    ///
    /// The drop is tried out on a copy of the layout. That gives the frame the window will have,
    /// and it shows a drop that would leave every window where it is, which counts as nothing.
    public static func plan(_ scene: DropScene) -> DropPlan? {
        let id = scene.dragged
        guard let own = scene.tiles[id], !own.contains(scene.pointer),
              let target = target(in: scene), let tile = scene.tiles[target],
              let home = scene.desks.first(where: { $0.tree.contains(id) }),
              let there = scene.desks.first(where: { $0.tree.contains(target) }) else { return nil }

        let stack = there.tree.shownStack(around: target, visible: scene.visible)
        let whole = stack.map { $0.leaves().compactMap { scene.tiles[$0] }.reduce(tile) { $0.union($1) } } ?? tile
        let drop: Drop
        if let side = edge(at: scene.pointer, of: whole) {
            drop = .split(target, side)
        } else if stack != nil || there.tree !== home.tree {
            drop = .join(target)
        } else {
            drop = .trade(target)
        }

        let homeAfter = home.tree.copy()
        let thereAfter = there.tree === home.tree ? homeAfter : there.tree.copy()
        guard carryOut(drop, of: id, in: [homeAfter, thereAfter], visible: scene.visible) else { return nil }
        func frames(_ a: Tree, _ b: Tree) -> [WindowID: CGRect] {
            var all: [WindowID: CGRect] = [:]
            for (tree, area) in [(a, home.area), (b, there.area)] {
                all.merge(computeLayout(tree, in: area, gap: scene.gap, visible: scene.visible, minSizes: scene.minSizes, peek: scene.peek)) { first, _ in first }
            }
            return all
        }
        let before = frames(home.tree, there.tree), after = frames(homeAfter, thereAfter)
        guard let rect = after[id], after.contains(where: { window, frame in before[window].map { !near($0, frame) } ?? true }) else { return nil }
        return DropPlan(drop: drop, rect: rect)
    }

    /// Do a drop to the trees. `trees` are the layouts being shown; the dragged window and the
    /// window it is dropped on may be in the same one or in two of them. False when the drop
    /// cannot be done, and then nothing has changed.
    @discardableResult
    public static func carryOut(_ drop: Drop, of id: WindowID, in trees: [Tree], visible: Set<WindowID>? = nil) -> Bool {
        guard let home = trees.first(where: { $0.contains(id) }) else { return false }
        func tree(of other: WindowID) -> Tree? { other == id ? nil : trees.first { $0.contains(other) } }
        switch drop {
        case .trade(let other):
            return home.swap(id, other)
        case .join(let other):
            guard let there = tree(of: other) else { return false }
            if there !== home { home.remove(id) }
            return there.place(id, nextTo: other, visible: visible)
        case .split(let other, let side):
            guard let there = tree(of: other) else { return false }
            if there !== home { home.remove(id) }
            return there.place(id, beside: other, on: side, visible: visible)
        }
    }

    /// The outline that shows a landing place: a line of this width that lies just inside the
    /// frame the window will have, so that what is drawn is the size of the window to come.
    /// `cornerRadius` is how round a window's corners are on this system.
    public static func outline(for rect: CGRect, lineWidth: CGFloat, cornerRadius: CGFloat) -> Outline {
        let width = max(0, min(lineWidth, min(rect.width, rect.height) / 2))
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        return Outline(rect: rect.insetBy(dx: width, dy: width), lineWidth: width, cornerRadius: max(0, radius - width))
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}

private extension Tree {
    /// A layout of its own with the same arrangement, to try a change out on.
    func copy() -> Tree { Tree(snapshot: snapshot) }
}
