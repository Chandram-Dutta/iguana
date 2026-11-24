import CoreGraphics
import XCTest
@testable import IguanaCore

/// Dragging a tiled window with the mouse: what letting go of it does, where it lands, and the
/// tree operations that carry a drop out.
final class DragDropTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
    /// A second display to the right of the first.
    let second = CGRect(x: 1000, y: 0, width: 800, height: 600)

    func win(_ id: WindowID) -> NodeSnapshot { NodeSnapshot(window: id, orientation: nil, weight: 1, children: nil) }
    func split(_ o: Orientation, _ kids: NodeSnapshot...) -> NodeSnapshot { NodeSnapshot(window: nil, orientation: o, weight: 1, children: kids) }
    func stack(_ o: Orientation, _ kids: NodeSnapshot...) -> NodeSnapshot {
        NodeSnapshot(window: nil, orientation: o, weight: 1, children: kids, stacked: true)
    }
    func row(_ ids: WindowID...) -> Tree { Tree(snapshot: NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: ids.map(win))) }
    /// Tile 9 on the left half, a stack of 1, 2 and 3 on the right half.
    func tileAndStack() -> Tree { Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2), win(3)))) }

    /// What is on screen: the tiles are where the layouts put them. `order` is front to back;
    /// left out, the dragged window is in front and the rest follow by number.
    func scene(
        _ desks: [(Tree, CGRect)], drag id: WindowID, at pointer: CGPoint, order: [WindowID]? = nil,
        blockers: [WindowID: CGRect] = [:], visible: Set<WindowID>? = nil, gap: CGFloat = 0, mins: [WindowID: CGSize] = [:]
    ) -> DropScene {
        let visible = visible ?? Set(desks.flatMap { $0.0.windows })
        var tiles: [WindowID: CGRect] = [:]
        for (tree, area) in desks { tiles.merge(computeLayout(tree, in: area, gap: gap, visible: visible, minSizes: mins)) { a, _ in a } }
        let rest = (Array(blockers.keys) + Array(tiles.keys)).filter { $0 != id }.sorted()
        return DropScene(dragged: id, pointer: pointer, tiles: tiles, blockers: blockers, frontToBack: order ?? [id] + rest,
                         desks: desks.map { DropScene.Desk(tree: $0.0, area: $0.1) }, visible: visible, gap: gap, minSizes: mins)
    }

    func plan(_ tree: Tree, drag id: WindowID, at pointer: CGPoint, order: [WindowID]? = nil, blockers: [WindowID: CGRect] = [:],
              visible: Set<WindowID>? = nil, gap: CGFloat = 0) -> DropPlan? {
        DragDrop.plan(scene([(tree, screen)], drag: id, at: pointer, order: order, blockers: blockers, visible: visible, gap: gap))
    }

    func assertCanonical(_ n: Node, isRoot: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        guard let o = n.orientation else { return }
        if !isRoot { XCTAssertGreaterThan(n.children.count, 1, "container with fewer than two children", file: file, line: line) }
        if n.children.count < 2 { XCTAssertFalse(n.stacked, "a stack of one", file: file, line: line) }
        for c in n.children {
            XCTAssertTrue(c.parent === n, file: file, line: line)
            if c.orientation == o { XCTAssertNotEqual(c.stacked, n.stacked, "nested container arranges its children the same way as its parent", file: file, line: line) }
            XCTAssertGreaterThan(c.weight, 0, file: file, line: line)
            assertCanonical(c, isRoot: false, file: file, line: line)
        }
    }

    // MARK: A move or a resize

    func testDraggingAnEdgeIsNotAMove() {
        let start = CGRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertTrue(DragDrop.isMove(from: start, to: start.offsetBy(dx: 40, dy: 0)))
        XCTAssertTrue(DragDrop.isMove(from: start, to: start.offsetBy(dx: 0, dy: -9)))
        XCTAssertFalse(DragDrop.isMove(from: start, to: start), "it has not gone anywhere")
        XCTAssertFalse(DragDrop.isMove(from: start, to: start.offsetBy(dx: 2, dy: -3)), "a wobble of the hand")
        // The right edge was dragged: only the size changed.
        XCTAssertFalse(DragDrop.isMove(from: start, to: CGRect(x: 100, y: 50, width: 460, height: 300)))
        // The top-left corner was dragged: the origin moved, and the size changed with it.
        XCTAssertFalse(DragDrop.isMove(from: start, to: CGRect(x: 60, y: 20, width: 440, height: 330)))
        // A window that came out a point or two off its tile and was then carried away.
        XCTAssertTrue(DragDrop.isMove(from: start, to: CGRect(x: 300, y: 200, width: 402, height: 298)))
    }

    // MARK: The edges of a tile

    func testTheBandAlongAnEdgeIsAQuarterOfTheTileWithinLimits() {
        XCTAssertEqual(DragDrop.band(1000), 250)
        XCTAssertEqual(DragDrop.band(400), 100)
        XCTAssertEqual(DragDrop.band(2560), 320, "on a very large tile the edge stays near the edge")
        XCTAssertEqual(DragDrop.band(160), 48, "on a small tile the edge can still be hit")
        XCTAssertEqual(DragDrop.band(90), 30, "and a very small tile keeps a middle: a third on each side")
    }

    func testAPointIsAtAnEdgeOrInTheMiddle() {
        let tile = CGRect(x: 500, y: 0, width: 500, height: 600)   // bands: 125 across, 150 down
        XCTAssertNil(DragDrop.edge(at: CGPoint(x: 750, y: 300), of: tile), "the middle")
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 520, y: 300), of: tile), .left)
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 980, y: 300), of: tile), .right)
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 750, y: 40), of: tile), .up)
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 750, y: 580), of: tile), .down)
        XCTAssertNil(DragDrop.edge(at: CGPoint(x: 626, y: 300), of: tile), "just past the band")
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 624, y: 300), of: tile), .left)
        XCTAssertNil(DragDrop.edge(at: CGPoint(x: 400, y: 300), of: tile), "not on the tile at all")
        // In a corner the nearer edge wins, each distance counted against its own band.
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 510, y: 5), of: tile), .up)
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 505, y: 60), of: tile), .left)
        XCTAssertEqual(DragDrop.edge(at: CGPoint(x: 990, y: 590), of: tile), .down)
    }

    // MARK: What is dropped on

    func testTheTileUnderThePointerIsTheTarget() {
        let s = scene([(row(1, 2, 3), screen)], drag: 1, at: CGPoint(x: 800, y: 300))
        XCTAssertEqual(DragDrop.target(in: s), 3)
        var gap = scene([(row(1, 2), screen)], drag: 1, at: CGPoint(x: 500, y: 300), gap: 10)
        XCTAssertNil(DragDrop.target(in: gap), "the gap between two tiles")
        gap.pointer = CGPoint(x: 300, y: -10)
        XCTAssertNil(DragDrop.target(in: gap), "above the tiles: the menu bar")
        gap.pointer = CGPoint(x: 5000, y: 300)
        XCTAssertNil(DragDrop.target(in: gap), "nothing there")
    }

    func testThePointerInTheMarginRoundTheTilesIsAtTheEdgeOfTheTileBesideIt() {
        // A desktop with a margin of 8 points round its tiles, as the outer gaps leave.
        let area = screen.insetBy(dx: 8, dy: 8)
        var s = scene([(row(1, 2), area)], drag: 2, at: CGPoint(x: 1, y: 300))
        XCTAssertNil(DragDrop.plan(s), "not told about the margin, the pointer is beside the tiles")
        s.margin = 10
        XCTAssertEqual(DragDrop.plan(s)?.drop, .split(1, .left), "dragged to the left edge of the screen")
        XCTAssertEqual(DragDrop.plan(s)?.rect.minX, area.minX)

        s = scene([(row(1, 2), area)], drag: 1, at: CGPoint(x: 999.5, y: 300))
        s.margin = 10
        XCTAssertEqual(DragDrop.plan(s)?.drop, .split(2, .right), "and to the right edge")

        // Its own tile is still its own tile from the margin beside it.
        s = scene([(row(1, 2), area)], drag: 1, at: CGPoint(x: 1, y: 300))
        s.margin = 10
        XCTAssertNil(DragDrop.plan(s))

        // Further out than the margin is somewhere else: the menu bar, the Dock.
        s = scene([(row(1, 2), area)], drag: 2, at: CGPoint(x: 300, y: -30))
        s.margin = 10
        XCTAssertNil(DragDrop.plan(s))
        XCTAssertEqual(DragDrop.reach(CGPoint(x: 300, y: 300), into: [area], margin: 10), CGPoint(x: 300, y: 300), "a pointer over the tiles is left alone")
    }

    func testOverItsOwnTileNothingHappens() {
        XCTAssertNil(plan(row(1, 2), drag: 1, at: CGPoint(x: 100, y: 100)))
        // The window itself is elsewhere by now; it is the tile that counts.
        XCTAssertNil(plan(row(1, 2), drag: 2, at: CGPoint(x: 999, y: 599)))
    }

    func testAWindowThatIsNoTileBlocksTheDrop() {
        let floating: [WindowID: CGRect] = [7: CGRect(x: 600, y: 100, width: 300, height: 300)]
        XCTAssertNil(plan(row(1, 2), drag: 1, at: CGPoint(x: 750, y: 300), order: [1, 7, 2], blockers: floating), "on a floating window")
        XCTAssertEqual(plan(row(1, 2), drag: 1, at: CGPoint(x: 750, y: 420), order: [1, 7, 2], blockers: floating)?.drop, .trade(2), "beside it")
        XCTAssertEqual(plan(row(1, 2), drag: 1, at: CGPoint(x: 750, y: 300), order: [1, 2, 7], blockers: floating)?.drop, .trade(2), "it is behind the tile")
        // A window that is neither (the outline itself, the focus ring) is looked through.
        XCTAssertEqual(plan(row(1, 2), drag: 1, at: CGPoint(x: 750, y: 300), order: [99, 1, 98, 2])?.drop, .trade(2))
        // A window that is not a tile is not dragged onto anything.
        var s = scene([(row(1, 2), screen)], drag: 1, at: CGPoint(x: 750, y: 300))
        s.tiles[1] = nil
        XCTAssertNil(DragDrop.plan(s), "floating or zoomed: it has no tile")
    }

    // MARK: Trade places, or take half

    func testTheMiddleOfATileTradesPlaces() {
        let t = row(1, 2)
        let p = plan(t, drag: 1, at: CGPoint(x: 750, y: 300))
        XCTAssertEqual(p, DropPlan(drop: .trade(2), rect: CGRect(x: 500, y: 0, width: 500, height: 600)), "the outline covers that tile")
        XCTAssertTrue(DragDrop.carryOut(.trade(2), of: 1, in: [t]))
        XCTAssertEqual(t.windows, [2, 1])
    }

    func testAnEdgeOfATileTakesThatHalf() {
        // 1 | 2, and 1 is let go on the top edge of 2: 1 above 2, each the width of the screen,
        // because 1 no longer takes the left half.
        let t = row(1, 2)
        let top = plan(t, drag: 1, at: CGPoint(x: 750, y: 40))
        XCTAssertEqual(top, DropPlan(drop: .split(2, .up), rect: CGRect(x: 0, y: 0, width: 1000, height: 300)))
        XCTAssertEqual(plan(t, drag: 1, at: CGPoint(x: 750, y: 580)), DropPlan(drop: .split(2, .down), rect: CGRect(x: 0, y: 300, width: 1000, height: 300)))
        XCTAssertEqual(plan(t, drag: 1, at: CGPoint(x: 980, y: 300)), DropPlan(drop: .split(2, .right), rect: CGRect(x: 500, y: 0, width: 500, height: 600)))
        XCTAssertNil(plan(t, drag: 1, at: CGPoint(x: 520, y: 300)), "left of 2 is where 1 is already: nothing would change, so nothing is shown")

        XCTAssertTrue(DragDrop.carryOut(.split(2, .up), of: 1, in: [t]))
        XCTAssertEqual(t.root.orientation, .vertical)
        XCTAssertEqual(t.windows, [1, 2])
        assertCanonical(t.root)
    }

    func testTheDraggedWindowTakesHalfOfTheTargetAndTheTargetKeepsTheRest() {
        // 1 | 2 | 3, and 3 is let go on the left edge of 1. 3 leaves, so 1 and 2 have half the
        // screen each; then 3 takes the left half of 1's half.
        let t = row(1, 2, 3)
        let p = plan(t, drag: 3, at: CGPoint(x: 10, y: 300))
        XCTAssertEqual(p, DropPlan(drop: .split(1, .left), rect: CGRect(x: 0, y: 0, width: 250, height: 600)))
        XCTAssertTrue(DragDrop.carryOut(.split(1, .left), of: 3, in: [t]))
        XCTAssertEqual(t.windows, [3, 1, 2])
        let f = computeLayout(t, in: screen)
        XCTAssertEqual(f[3], CGRect(x: 0, y: 0, width: 250, height: 600))
        XCTAssertEqual(f[1], CGRect(x: 250, y: 0, width: 250, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 600), "2 keeps what it had once 3 was gone")
        assertCanonical(t.root)
    }

    func testAnEdgeAcrossTheRowSplitsOnlyTheTarget() {
        // 1 | (2 / 3), and 3 is let go on the bottom edge of 1: (1 / 3) | 2.
        let t = Tree(snapshot: split(.horizontal, win(1), split(.vertical, win(2), win(3))))
        let p = plan(t, drag: 3, at: CGPoint(x: 250, y: 550))
        XCTAssertEqual(p, DropPlan(drop: .split(1, .down), rect: CGRect(x: 0, y: 300, width: 500, height: 300)))
        XCTAssertTrue(DragDrop.carryOut(.split(1, .down), of: 3, in: [t]))
        XCTAssertEqual(t.windows, [1, 3, 2])
        XCTAssertEqual(computeLayout(t, in: screen)[2], CGRect(x: 500, y: 0, width: 500, height: 600))
        assertCanonical(t.root)
    }

    func testTheOutlineAllowsForTheGap() {
        let p = plan(row(1, 2), drag: 1, at: CGPoint(x: 750, y: 40), gap: 10)
        XCTAssertEqual(p, DropPlan(drop: .split(2, .up), rect: CGRect(x: 0, y: 0, width: 1000, height: 295)))
    }

    func testAHiddenWindowKeepsItsPlace() {
        // 2 is minimised. 1 let go on the right edge of 3 goes to the right of it.
        let t = row(1, 2, 3)
        let p = plan(t, drag: 1, at: CGPoint(x: 990, y: 300), visible: [1, 3])
        XCTAssertEqual(p, DropPlan(drop: .split(3, .right), rect: CGRect(x: 500, y: 0, width: 500, height: 600)))
        XCTAssertTrue(DragDrop.carryOut(.split(3, .right), of: 1, in: [t], visible: [1, 3]))
        XCTAssertEqual(t.windows, [2, 3, 1])
    }

    // MARK: Stacks

    func testTheMiddleOfAStackJoinsItAfterTheWindowInFront() {
        // 9 | stack(1, 2, 3) with 2 in front. The stack is the right half: 1 from 500, 2 from 532, 3 from 564.
        let t = tileAndStack()
        let p = plan(t, drag: 9, at: CGPoint(x: 750, y: 300), order: [9, 2, 1, 3])
        // The stack is all there is then: four windows across the screen, 9 the third of them.
        XCTAssertEqual(p, DropPlan(drop: .join(2), rect: CGRect(x: 64, y: 0, width: 904, height: 600)))
        XCTAssertEqual(plan(t, drag: 9, at: CGPoint(x: 750, y: 300), order: [9, 3, 2, 1])?.drop, .join(3), "of the windows under the pointer, the one in front")

        XCTAssertTrue(DragDrop.carryOut(.join(2), of: 9, in: [t]))
        XCTAssertEqual(t.windows, [1, 2, 9, 3])
        XCTAssertTrue(t.root.stacked)
        assertCanonical(t.root)
    }

    func testAnEdgeOfAStackSplitsBesideTheWholeStack() {
        let t = tileAndStack()
        // Its edges are those of the whole stack, whichever of its windows is under the pointer.
        let top = plan(t, drag: 9, at: CGPoint(x: 750, y: 30), order: [9, 2, 1, 3])
        XCTAssertEqual(top, DropPlan(drop: .split(2, .up), rect: CGRect(x: 0, y: 0, width: 1000, height: 300)))
        let right = plan(t, drag: 9, at: CGPoint(x: 990, y: 300), order: [9, 2, 1, 3])
        XCTAssertEqual(right, DropPlan(drop: .split(3, .right), rect: CGRect(x: 500, y: 0, width: 500, height: 600)), "the strip of 3 is the right edge of the stack")
        XCTAssertNil(plan(t, drag: 9, at: CGPoint(x: 510, y: 300), order: [9, 2, 1, 3]), "left of the stack is where 9 is already")

        XCTAssertTrue(DragDrop.carryOut(.split(2, .up), of: 9, in: [t]))
        XCTAssertEqual(t.root.orientation, .vertical)
        XCTAssertFalse(t.root.stacked)
        XCTAssertEqual(t.root.children.map(\.stacked), [false, true], "the stack is whole, and 9 is not in it")
        XCTAssertEqual(t.root.children[1].leaves(), [1, 2, 3])
        assertCanonical(t.root)
    }

    func testAWindowDraggedOutOfAStackFollowsTheSameRules() {
        // 2 is dragged out of the stack and let go on tile 9.
        let middle = plan(tileAndStack(), drag: 2, at: CGPoint(x: 250, y: 300), order: [2, 1, 3, 9])
        XCTAssertEqual(middle, DropPlan(drop: .trade(9), rect: CGRect(x: 0, y: 0, width: 500, height: 600)), "9 takes its place in the stack")
        let top = plan(tileAndStack(), drag: 2, at: CGPoint(x: 250, y: 30), order: [2, 1, 3, 9])
        XCTAssertEqual(top, DropPlan(drop: .split(9, .up), rect: CGRect(x: 0, y: 0, width: 500, height: 300)))

        let t = tileAndStack()
        XCTAssertTrue(DragDrop.carryOut(.split(9, .up), of: 2, in: [t]))
        XCTAssertEqual(t.windows, [2, 9, 1, 3])
        XCTAssertEqual(t.root.children.map(\.stacked), [false, true])
        assertCanonical(t.root)
    }

    func testInAStackTheOwnTileIsMostOfTheStack() {
        let t = tileAndStack()
        // 2's tile runs from 532 to 968. Let go there it stays, whatever else is under the pointer.
        XCTAssertNil(plan(t, drag: 2, at: CGPoint(x: 700, y: 300), order: [2, 1, 3, 9]))
        XCTAssertNil(plan(t, drag: 2, at: CGPoint(x: 700, y: 20), order: [1, 3, 2, 9]))
        // On the strip of 1, outside its own tile, it is at the left edge of the stack: it
        // leaves the stack and stands to the left of it, in half of the stack's room.
        let p = plan(t, drag: 2, at: CGPoint(x: 515, y: 300), order: [2, 1, 3, 9])
        XCTAssertEqual(p, DropPlan(drop: .split(1, .left), rect: CGRect(x: 500, y: 0, width: 250, height: 600)))
        XCTAssertTrue(DragDrop.carryOut(.split(1, .left), of: 2, in: [t]))
        XCTAssertEqual(t.windows, [9, 2, 1, 3])
        XCTAssertEqual(t.root.children.map(\.stacked), [false, false, true])
        assertCanonical(t.root)
    }

    func testAStackOfTwoThatLosesAWindowIsATileAgain() {
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2))))
        // 2 is in front (from 532). It is let go on the strip of 1, at the left edge of the stack.
        XCTAssertTrue(DragDrop.carryOut(.split(1, .left), of: 2, in: [t]))
        XCTAssertEqual(t.windows, [9, 2, 1])
        XCTAssertEqual(t.root.children.count, 3)
        XCTAssertFalse(t.root.children.contains { $0.stacked })
        assertCanonical(t.root)
    }

    func testJoiningItsOwnStackOnlyChangesTheOrder() {
        // A tall stack with wide strips, so that the middle of it reaches past 1's own tile.
        let t = Tree(snapshot: NodeSnapshot(window: nil, orientation: .vertical, weight: 1, children: [1, 2, 3, 4, 5, 6, 7, 8].map(win), stacked: true))
        // Eight windows 600 high: each is 376 high and starts 32 below the one before. 1's tile ends at 376.
        let p = plan(t, drag: 1, at: CGPoint(x: 500, y: 400), order: [1, 3, 2, 4, 5, 6, 7, 8])
        XCTAssertEqual(p, DropPlan(drop: .join(3), rect: CGRect(x: 0, y: 64, width: 1000, height: 376)))
        XCTAssertTrue(DragDrop.carryOut(.join(3), of: 1, in: [t]))
        XCTAssertEqual(t.windows, [2, 3, 1, 4, 5, 6, 7, 8])
        XCTAssertTrue(t.root.stacked)
        assertCanonical(t.root)
    }

    func testAStackWithOneWindowOnScreenIsAnOrdinaryTile() {
        let t = tileAndStack()
        let p = plan(t, drag: 9, at: CGPoint(x: 750, y: 300), visible: [9, 1])
        XCTAssertEqual(p, DropPlan(drop: .trade(1), rect: CGRect(x: 500, y: 0, width: 500, height: 600)))
    }

    func testAStackThatFillsTheDisplayIsSplitAsAWhole() {
        // Two displays. 5 comes from the second one and is let go on the left edge of a stack that fills the first.
        let stacked = Tree(snapshot: stack(.horizontal, win(1), win(2)))
        let other = row(5, 6)
        let s = scene([(stacked, screen), (other, second)], drag: 5, at: CGPoint(x: 20, y: 300), order: [5, 2, 1, 6])
        XCTAssertEqual(DragDrop.plan(s), DropPlan(drop: .split(1, .left), rect: CGRect(x: 0, y: 0, width: 500, height: 600)))
        XCTAssertTrue(DragDrop.carryOut(.split(1, .left), of: 5, in: [stacked, other]))
        XCTAssertEqual(stacked.windows, [5, 1, 2])
        XCTAssertFalse(stacked.root.stacked)
        XCTAssertEqual(stacked.root.children.map(\.stacked), [false, true])
        XCTAssertEqual(other.windows, [6])
        assertCanonical(stacked.root)
    }

    // MARK: Another display

    func testATileOnAnotherDisplay() {
        let here = row(1, 2), there = row(5)
        func drop(at pointer: CGPoint) -> DropPlan? { DragDrop.plan(scene([(here, screen), (there, second)], drag: 2, at: pointer)) }
        // The middle: 2 moves in beside 5, and 5 stays on its display.
        XCTAssertEqual(drop(at: CGPoint(x: 1400, y: 300)), DropPlan(drop: .join(5), rect: CGRect(x: 1400, y: 0, width: 400, height: 600)))
        // An edge: the same as on its own display.
        XCTAssertEqual(drop(at: CGPoint(x: 1400, y: 20)), DropPlan(drop: .split(5, .up), rect: CGRect(x: 1000, y: 0, width: 800, height: 300)))
        XCTAssertEqual(drop(at: CGPoint(x: 1010, y: 300)), DropPlan(drop: .split(5, .left), rect: CGRect(x: 1000, y: 0, width: 400, height: 600)))

        XCTAssertTrue(DragDrop.carryOut(.split(5, .left), of: 2, in: [here, there]))
        XCTAssertEqual(here.windows, [1])
        XCTAssertEqual(there.windows, [2, 5])
        assertCanonical(here.root)
        assertCanonical(there.root)
    }

    func testADropThatCannotBeDoneChangesNothing() {
        let here = row(1, 2), there = row(5)
        XCTAssertFalse(DragDrop.carryOut(.trade(5), of: 1, in: [here, there]), "trading places is for two windows of one layout")
        XCTAssertFalse(DragDrop.carryOut(.split(8, .left), of: 1, in: [here, there]), "no such window")
        XCTAssertFalse(DragDrop.carryOut(.join(1), of: 1, in: [here, there]), "onto itself")
        XCTAssertFalse(DragDrop.carryOut(.join(5), of: 8, in: [here, there]))
        XCTAssertEqual(here.windows, [1, 2])
        XCTAssertEqual(there.windows, [5])
    }

    // MARK: The tree operations

    func testPlaceBesideKeepsTheSharesOfTheOthers() {
        // 1 has half of the row, 2 and 3 a quarter each.
        let t = Tree(snapshot: NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: [
            NodeSnapshot(window: 1, orientation: nil, weight: 2, children: nil), win(2), win(3),
        ]))
        t.focused = 3
        XCTAssertTrue(t.place(3, beside: 1, on: .right))
        XCTAssertEqual(t.windows, [1, 3, 2])
        XCTAssertEqual(t.focused, 3, "it is the same window, in another place")
        let f = computeLayout(t, in: CGRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 300, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 300, y: 0, width: 300, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 600, y: 0, width: 300, height: 600))
        XCTAssertFalse(t.place(3, beside: 3, on: .left))
        XCTAssertFalse(t.place(3, beside: 8, on: .left))
        XCTAssertEqual(t.windows, [1, 3, 2])
    }

    func testPlaceBesideOnEverySide() {
        let cases: [(Direction, [WindowID], Orientation)] = [
            (.left, [3, 1], .horizontal), (.right, [1, 3], .horizontal), (.up, [3, 1], .vertical), (.down, [1, 3], .vertical),
        ]
        for (side, order, orientation) in cases {
            let t = Tree(snapshot: split(.horizontal, split(.vertical, win(1), win(2)), win(3)))
            XCTAssertTrue(t.place(3, beside: 1, on: side))
            assertCanonical(t.root)
            // 3 left the row, so the column of 1 and 2 is all there is, and 3 shares 1's part of it.
            XCTAssertEqual(t.root.orientation, .vertical)
            if orientation == .vertical {
                XCTAssertEqual(t.windows, order + [2], "\(side)")
                XCTAssertEqual(t.root.children.count, 3)
            } else {
                XCTAssertEqual(t.root.children.first?.orientation, .horizontal, "\(side)")
                XCTAssertEqual(t.root.children.first?.leaves(), order, "\(side)")
            }
        }
    }

    func testPlaceNextToOutsideAStack() {
        let t = row(1, 2, 3)
        XCTAssertTrue(t.place(1, nextTo: 3))
        XCTAssertEqual(t.windows, [2, 3, 1])
        XCTAssertTrue(t.place(9, nextTo: 2))
        XCTAssertEqual(t.windows, [2, 9, 3, 1])
        XCTAssertFalse(t.place(9, nextTo: 9))
        XCTAssertFalse(t.place(9, nextTo: 7))
        assertCanonical(t.root)
    }

    func testPlaceNextToAWindowInsideAStackGoesAfterItsBranch() {
        // A stack of 1 and of (2 | 3). 9 dropped on 2 becomes the next window of the stack, after the pair.
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.vertical, win(1), split(.horizontal, win(2), win(3)))))
        XCTAssertTrue(t.place(9, nextTo: 2))
        XCTAssertEqual(t.windows, [1, 2, 3, 9])
        XCTAssertTrue(t.root.stacked)
        XCTAssertEqual(t.root.children.count, 3)
        assertCanonical(t.root)
    }

    // MARK: What was shown is what happens

    func testEveryPlanLandsWhereItSaid() {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var plans = 0, kinds = Set<String>()
        for round in 0..<600 {
            // Two displays, each with a layout that has been through some changes.
            let trees = [Tree(), Tree(orientation: .vertical)]
            var id: WindowID = 1
            for (k, tree) in trees.enumerated() {
                for _ in 0..<(round % 7 == 0 && k == 1 ? 1 : 2 + next(5)) {
                    let ids = tree.windows
                    tree.insert(id, after: ids.isEmpty ? nil : ids[next(ids.count)], split: [nil, .horizontal, .vertical][next(3)])
                    id += 1
                }
                for _ in 0..<next(6) {
                    let ids = tree.windows, pick = ids[next(ids.count)]
                    switch next(4) {
                    case 0: tree.toggleStack(pick)
                    case 1: tree.move(pick, Direction.allCases[next(4)])
                    case 2: tree.join(pick, with: Direction.allCases[next(4)])
                    default: tree.changeShare(of: pick, .delta(Double(next(5) - 2) * 0.05))
                    }
                }
            }
            let all = trees.flatMap(\.windows)
            // Now and then a window is not on screen.
            var visible = Set(all)
            if next(3) == 0, let hidden = all.dropFirst(next(all.count)).first { visible.remove(hidden) }
            let shown = all.filter(visible.contains)
            let dragged = shown[next(shown.count)]
            var order = shown
            for i in order.indices.reversed() where i > 0 { order.swapAt(i, next(i + 1)) }
            let gap = CGFloat([0, 8][next(2)])
            let desks = [(trees[0], screen), (trees[1], second)]
            let pointer = CGPoint(x: CGFloat(next(1800)), y: CGFloat(next(600)))
            let s = scene(desks, drag: dragged, at: pointer, order: order, visible: visible, gap: gap)
            func layout() -> [WindowID: CGRect] {
                var f: [WindowID: CGRect] = [:]
                for (tree, area) in desks { f.merge(computeLayout(tree, in: area, gap: gap, visible: visible)) { a, _ in a } }
                return f
            }
            let before = layout()
            guard let plan = DragDrop.plan(s) else {
                XCTAssertEqual(layout(), before, "asking changes nothing")
                continue
            }
            plans += 1
            switch plan.drop {
            case .trade: kinds.insert("trade")
            case .join: kinds.insert("join")
            case .split: kinds.insert("split")
            }
            XCTAssertEqual(layout(), before, "asking changes nothing")
            XCTAssertFalse(s.tiles[dragged]?.contains(pointer) ?? true, "never over its own tile")
            XCTAssertTrue(DragDrop.carryOut(plan.drop, of: dragged, in: trees, visible: visible), "round \(round): \(plan.drop)")
            let after = layout()
            XCTAssertEqual(after[dragged], plan.rect, "round \(round): \(plan.drop)")
            XCTAssertNotEqual(after, before, "a plan is only made for a drop that changes something")
            XCTAssertEqual(trees.flatMap(\.windows).sorted(), all.sorted(), "no window is lost or doubled")
            for tree in trees { assertCanonical(tree.root) }
        }
        XCTAssertGreaterThan(plans, 150)
        XCTAssertEqual(kinds, ["trade", "join", "split"])
    }

    // MARK: The outline

    func testTheOutlineIsTheSizeOfTheWindowToCome() {
        let rect = CGRect(x: 500, y: 38, width: 500, height: 300)
        let outline = DragDrop.outline(for: rect, lineWidth: 2, cornerRadius: 16)
        XCTAssertEqual(outline.bounds, rect, "the line lies inside the frame")
        XCTAssertEqual(outline.lineWidth, 2)
        XCTAssertEqual(outline.outerRadius, 16, "its outer edge is as round as a window")
        // A sliver of a tile still gets an outline that makes sense.
        let sliver = DragDrop.outline(for: CGRect(x: 0, y: 0, width: 3, height: 400), lineWidth: 2, cornerRadius: 16)
        XCTAssertEqual(sliver.bounds, CGRect(x: 0, y: 0, width: 3, height: 400))
        XCTAssertGreaterThanOrEqual(sliver.cornerRadius, 0)
    }
}
