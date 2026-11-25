import CoreGraphics
import XCTest
@testable import IguanaCore

/// Stacks: windows that overlap in one tile, how focus steps through them, and which one is in front.
final class StackTests: XCTestCase, TestScreen {
    func win(_ id: WindowID) -> NodeSnapshot { NodeSnapshot(window: id, orientation: nil, weight: 1, children: nil) }
    func split(_ o: Orientation, _ kids: NodeSnapshot...) -> NodeSnapshot { NodeSnapshot(window: nil, orientation: o, weight: 1, children: kids) }
    func stack(_ o: Orientation, _ kids: NodeSnapshot...) -> NodeSnapshot {
        NodeSnapshot(window: nil, orientation: o, weight: 1, children: kids, stacked: true)
    }
    /// A stack of these windows that fills the screen.
    func stackOf(_ ids: WindowID..., orientation: Orientation = .horizontal) -> Tree {
        Tree(snapshot: NodeSnapshot(window: nil, orientation: orientation, weight: 1, children: ids.map(win), stacked: true))
    }

    func testStackTogglesTheContainerOfTheWindow() {
        let t = Tree()
        t.insert(1)
        XCTAssertNil(t.toggleStack(1), "one window has nothing to stack with")
        XCTAssertNil(t.toggleStack(9))
        [2, 3].forEach { t.insert($0) }
        XCTAssertEqual(t.toggleStack(2), true)
        XCTAssertTrue(t.root.stacked)
        XCTAssertEqual(t.windows, [1, 2, 3], "the order stays")
        XCTAssertEqual(t.toggleStack(3), false)
        XCTAssertEqual(frames(t)[2], CGRect(x: 333, y: 0, width: 334, height: 600), "and it is the row it was")

        // Only the container that holds the window: 1 | (2 / 3) with 3 focused stacks 2 and 3.
        let nested = Tree()
        nested.insert(1)
        nested.insert(2, after: 1, split: .horizontal)
        nested.insert(3, after: 2, split: .vertical)
        XCTAssertEqual(nested.toggleStack(3), true)
        XCTAssertFalse(nested.root.stacked)
        let f = frames(nested)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 568))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 32, width: 500, height: 568))
    }

    func testStackedWindowsOverlapAndEachKeepsAStrip() {
        let t = stackOf(1, 2, 3)
        var f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 936, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 32, y: 0, width: 936, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 64, y: 0, width: 936, height: 600))

        f = frames(t, peek: 100)
        XCTAssertEqual(f[2], CGRect(x: 100, y: 0, width: 800, height: 600))

        // The gap is between tiles. Inside a stack there is none; around it there is.
        f = frames(t, gap: 10)
        XCTAssertEqual(f[3], CGRect(x: 64, y: 0, width: 936, height: 600))
        let beside = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2))))
        f = frames(beside, gap: 10)
        XCTAssertEqual(f[9], CGRect(x: 0, y: 0, width: 495, height: 600))
        XCTAssertEqual(f[1], CGRect(x: 505, y: 0, width: 463, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 537, y: 0, width: 463, height: 600))

        // Flipped, the strips are at the top and the bottom.
        XCTAssertTrue(t.flip(2))
        XCTAssertTrue(t.root.stacked, "flipping a stack leaves it a stack")
        f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 1000, height: 536))
        XCTAssertEqual(f[3], CGRect(x: 0, y: 64, width: 1000, height: 536))
    }

    func testOnlyTheWindowsOnScreenTakePartInAStack() {
        let t = stackOf(1, 2, 3)
        let two = frames(t, visible: [1, 3])
        XCTAssertNil(two[2])
        XCTAssertEqual(two[1], CGRect(x: 0, y: 0, width: 968, height: 600))
        XCTAssertEqual(two[3], CGRect(x: 32, y: 0, width: 968, height: 600))
        XCTAssertEqual(frames(t, visible: [2]), [2: screen], "a stack of one fills its container")
        XCTAssertTrue(frames(t, visible: []).isEmpty)
    }

    func testAStackNeverLeavesItsContainer() {
        let t = stackOf(1, 2, 3)
        // Window 2 cannot be as narrow as the others: it is as wide as it must be and ends at the edge.
        var f = frames(t, mins: [2: CGSize(width: 980, height: 0)])
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 936, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 20, y: 0, width: 980, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 64, y: 0, width: 936, height: 600))
        // A minimum that does not fit at all gets the whole container and no more.
        f = frames(t, mins: [3: CGSize(width: 4000, height: 0)])
        XCTAssertEqual(f[3], screen)

        // More strips than there is room for: they shrink, and the window in front keeps half.
        let small = CGRect(x: 10, y: 10, width: 20, height: 12)
        let tiny = computeLayout(stackOf(1, 2, 3), in: small)
        XCTAssertEqual(tiny[1], CGRect(x: 10, y: 10, width: 10, height: 12))
        XCTAssertEqual(tiny[3], CGRect(x: 20, y: 10, width: 10, height: 12))
        XCTAssertTrue(tiny.values.allSatisfy { small.contains($0) })

        // Beside a tile, the stack asks for room for its widest window and the strips of the rest.
        let beside = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2))))
        f = frames(beside, mins: [1: CGSize(width: 600, height: 0)])
        XCTAssertEqual(f[9], CGRect(x: 0, y: 0, width: 368, height: 600))
        XCTAssertEqual(f[1], CGRect(x: 368, y: 0, width: 600, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 400, y: 0, width: 600, height: 600))
    }

    func testANewWindowJoinsTheStackOfTheFocusedOne() {
        let t = stackOf(1, 2, 3)
        // With auto-split the window manager asks for a split along the longer side. A stack takes the window as it is.
        XCTAssertTrue(t.insert(4, after: 2, split: .vertical))
        XCTAssertEqual(t.windows, [1, 2, 4, 3])
        XCTAssertEqual(t.root.children.count, 4)
        XCTAssertTrue(t.root.stacked)
        XCTAssertEqual(frames(t)[4], CGRect(x: 64, y: 0, width: 904, height: 600))
        XCTAssertTrue(t.insert(5, after: 3, split: .horizontal))
        XCTAssertEqual(t.root.children.count, 5)
    }

    func testAStackOfOneIsATileAgain() {
        let t = stackOf(1, 2, 3)
        t.remove(2)
        XCTAssertTrue(t.root.stacked)
        t.remove(3)
        XCTAssertFalse(t.root.stacked, "the last window is not a stack")
        t.insert(4, after: 1, split: .horizontal)
        XCTAssertEqual(frames(t)[4], CGRect(x: 500, y: 0, width: 500, height: 600))

        let nested = Tree(snapshot: split(.horizontal, win(9), stack(.vertical, win(1), win(2))))
        nested.remove(2)
        XCTAssertEqual(nested.root.children.count, 2)
        XCTAssertTrue(nested.root.children.allSatisfy { $0.windowID != nil })
    }

    func testAStackAndASplitThatRunTheSameWayStayApart() {
        // 9 | stack(1, 2), all left to right. Merging the two would put 9 in the stack.
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2))))
        XCTAssertEqual(t.root.children.count, 2)
        XCTAssertFalse(t.root.stacked)
        XCTAssertEqual(t.root.children[1].stacked, true)
        // Unstacked, it is one row of three.
        XCTAssertEqual(t.toggleStack(1), false)
        XCTAssertEqual(t.root.children.count, 3)
        XCTAssertEqual(frames(t)[2], CGRect(x: 750, y: 0, width: 250, height: 600))

        // A stack inside a stack that runs the same way is one stack.
        let double = Tree(snapshot: stack(.horizontal, win(9), stack(.horizontal, win(1), win(2))))
        XCTAssertEqual(double.root.children.count, 3)
        XCTAssertTrue(double.root.stacked)
    }

    func testMoveReordersAStackAndLeavesItAtItsEnds() {
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2), win(3))))
        XCTAssertTrue(t.move(1, .right))
        XCTAssertEqual(t.windows, [9, 2, 1, 3])
        XCTAssertEqual(t.root.children.count, 2, "still a stack of three beside 9")
        XCTAssertTrue(t.move(1, .right))
        XCTAssertEqual(t.windows, [9, 2, 3, 1])
        // At the end of the stack the next step leaves it.
        XCTAssertTrue(t.move(1, .right))
        XCTAssertEqual(t.root.children.count, 3)
        XCTAssertEqual(frames(t)[1]?.maxX, 1000)
        XCTAssertEqual(frames(t)[2]?.width, frames(t)[3]?.width)
        // And the step back enters it again, at the end it came from.
        XCTAssertTrue(t.move(1, .left))
        XCTAssertEqual(t.windows, [9, 2, 3, 1])
        XCTAssertEqual(t.root.children.count, 2)
        // Across the stack's direction a window leaves it.
        XCTAssertTrue(t.move(3, .down))
        XCTAssertEqual(t.root.orientation, .vertical)
        XCTAssertEqual(frames(t)[3], CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    func testResizeAndBalanceTreatAStackAsOneTile() {
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2), win(3))))
        XCTAssertTrue(t.changeShare(of: 2, .delta(0.1)))
        var f = frames(t)
        XCTAssertEqual(f[9]!.width, 400, accuracy: 1)
        XCTAssertEqual(f[1]!.width, 536, accuracy: 1)
        XCTAssertEqual(f[1]!.width, f[3]!.width, "the windows of the stack stay the same size")
        // What is on screen says nothing about shares inside a stack.
        let before = t.snapshot
        t.matchWeights(to: f)
        XCTAssertEqual(t.snapshot, before)
        t.balance()
        f = frames(t)
        XCTAssertEqual(f[9]!.width, 500, accuracy: 1)
        XCTAssertEqual(t.root.children[1].stacked, true)

        let alone = stackOf(1, 2, 3)
        XCTAssertFalse(alone.changeShare(of: 2, .delta(0.1)), "a stack that fills the desktop has nothing to resize against")
        XCTAssertFalse(alone.changeShare(of: 2, along: .horizontal, .ratio(1.2)))
    }

    func testJoinInsideAndIntoAStack() {
        // Joining two windows of a stack makes them one member of it, split the other way.
        let t = stackOf(1, 2, 3)
        XCTAssertTrue(t.join(3, with: .left))
        XCTAssertEqual(t.root.children.count, 2)
        var f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 968, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 32, y: 0, width: 968, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 32, y: 300, width: 968, height: 300))

        // Joining a window with a stack beside it puts it in the stack.
        let beside = Tree(snapshot: split(.horizontal, win(9), stack(.vertical, win(1), win(2))))
        XCTAssertTrue(beside.join(9, with: .right))
        XCTAssertTrue(beside.root.stacked)
        XCTAssertEqual(beside.windows, [1, 2, 9])
        f = frames(beside)
        XCTAssertEqual(f[9], CGRect(x: 0, y: 64, width: 1000, height: 536))
    }

    func testTheStackSurvivesSavingAndOldStateStillLoads() throws {
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.vertical, win(1), win(2), win(3))))
        t.changeShare(of: 9, .delta(0.1))
        let data = try JSONEncoder().encode(t.snapshot)
        let back = Tree(snapshot: try JSONDecoder().decode(NodeSnapshot.self, from: data))
        XCTAssertEqual(back.snapshot, t.snapshot)
        XCTAssertEqual(frames(back), frames(t))
        XCTAssertEqual(frames(back)[2], CGRect(x: 600, y: 32, width: 400, height: 536))

        // State written before stacks existed has no such field, and a layout without a stack still writes none.
        let old = #"{"orientation":"horizontal","weight":1,"children":[{"window":1,"weight":1},{"window":2,"weight":2}]}"#
        let loaded = Tree(snapshot: try JSONDecoder().decode(NodeSnapshot.self, from: Data(old.utf8)))
        XCTAssertFalse(loaded.root.stacked)
        XCTAssertEqual(frames(loaded)[2], CGRect(x: 333, y: 0, width: 667, height: 600))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(loaded.snapshot), as: UTF8.self).contains("stacked"))
        XCTAssertTrue(t.describe().contains("vertical stack"))
    }

    // MARK: Focus

    func target(_ t: Tree, from id: WindowID, _ dir: Direction, visible: Set<WindowID>? = nil, front: [WindowID] = []) -> WindowID? {
        let f = frames(t, visible: visible, gap: 8)
        return focusTarget(from: id, at: f[id]!, direction: dir, among: f, trees: [t], visible: visible, frontToBack: front)
    }

    func testFocusStepsThroughAStackInItsOrder() {
        // 9 | stack(1, 3, 2) | 8
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(3), win(2)), win(8)))
        let f = frames(t, gap: 8)
        // What is on screen cannot tell 3 from 2 here: both overlap 1 and both reach further right.
        XCTAssertEqual(nearestWindow(from: f[1]!, direction: .right, among: f, excluding: 1), 2)
        XCTAssertEqual(target(t, from: 1, .right), 3)
        XCTAssertEqual(target(t, from: 3, .right), 2)
        XCTAssertEqual(target(t, from: 2, .left), 3)
        XCTAssertEqual(target(t, from: 3, .left), 1)
        // At the ends it carries on to the neighbour outside the stack.
        XCTAssertEqual(target(t, from: 2, .right), 8)
        XCTAssertEqual(target(t, from: 1, .left), 9)
        // Coming in along the stack, the first window is the one at that end.
        XCTAssertEqual(target(t, from: 9, .right), 1)
        XCTAssertEqual(target(t, from: 8, .left), 2)
        XCTAssertNil(target(t, from: 3, .up))
        XCTAssertNil(target(t, from: 3, .down))
        // A window that is not on screen is stepped over.
        XCTAssertEqual(target(t, from: 1, .right, visible: [9, 1, 2, 8]), 2)
        XCTAssertEqual(target(t, from: 2, .left, visible: [9, 1, 2, 8]), 1)

        let alone = stackOf(1, 2, 3, orientation: .vertical)
        XCTAssertEqual(target(alone, from: 1, .down), 2)
        XCTAssertEqual(target(alone, from: 3, .up), 2)
        XCTAssertNil(target(alone, from: 3, .down), "the end of the stack and of the screen")
        XCTAssertNil(target(alone, from: 2, .left))
    }

    func testFocusEntersAStackFromTheSideAtTheWindowInFront() {
        // stack(1, 2, 3) above 9. Seen from 9, the three are equally near.
        let t = Tree(snapshot: split(.vertical, stack(.horizontal, win(1), win(2), win(3)), win(9)))
        XCTAssertEqual(target(t, from: 9, .up, front: [9, 3, 1, 2]), 3)
        XCTAssertEqual(target(t, from: 9, .up, front: [2, 9, 3, 1]), 2)
        XCTAssertEqual(target(t, from: 9, .up, visible: [1, 2, 9], front: [3, 9, 1, 2]), 1, "a window that is not on screen is not in front")
        XCTAssertNotNil(target(t, from: 9, .up), "without an order it still goes into the stack")
        // Leaving across the stack works from any of its windows.
        for id: WindowID in [1, 2, 3] { XCTAssertEqual(target(t, from: id, .down), 9) }
    }

    func testFocusInsideAStackThatHoldsASplit() {
        // stack( 1 above 2 , 3 ): the first member of the stack is itself two tiles.
        let t = Tree(snapshot: stack(.horizontal, split(.vertical, win(1), win(2)), win(3)))
        let f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 968, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 32, y: 0, width: 968, height: 600))
        // On screen 3 overlaps 1 and reaches further down, so with a gap between the tiles it
        // looks nearer than 2, which really is the window below.
        let gapped = frames(t, gap: 8)
        XCTAssertEqual(nearestWindow(from: gapped[1]!, direction: .down, among: gapped, excluding: 1), 3)
        XCTAssertEqual(target(t, from: 1, .down), 2)
        XCTAssertEqual(target(t, from: 2, .up), 1)
        XCTAssertEqual(target(t, from: 1, .right), 3)
        XCTAssertEqual(target(t, from: 2, .right), 3)
        XCTAssertEqual(target(t, from: 3, .left), 2)
        XCTAssertNil(target(t, from: 3, .right))
        XCTAssertNil(target(t, from: 2, .down))
    }

    // MARK: Which window is in front

    func testTheNearerWindowOfAStackHasToBeAboveTheFurtherOne() {
        let t = stackOf(1, 2, 3)
        // Window i covers the strips of everything beyond it, so with 1 in front 2 must be above 3.
        XCTAssertEqual(t.stackRaiseOrder(focused: 1, frontToBack: [1, 2, 3]), [])
        XCTAssertEqual(t.stackRaiseOrder(focused: 1, frontToBack: [1, 3, 2]), [2, 1])
        XCTAssertEqual(t.stackRaiseOrder(focused: 3, frontToBack: [3, 1, 2]), [2, 3])
        // The middle one has nothing on either side that could be covered.
        XCTAssertEqual(t.stackRaiseOrder(focused: 2, frontToBack: [2, 3, 1]), [])
        XCTAssertEqual(t.stackRaiseOrder(focused: 2, frontToBack: [2, 1, 3]), [])
        // The focused window is in front of its stack, whatever else is.
        XCTAssertEqual(t.stackRaiseOrder(focused: 2, frontToBack: [1, 2, 3]), [2])
        XCTAssertEqual(t.stackRaiseOrder(focused: 3, frontToBack: [1, 2, 3]), [2, 3])
        // Windows that are not part of the stack do not matter, wherever they are.
        XCTAssertEqual(t.stackRaiseOrder(focused: 1, frontToBack: [7, 1, 8, 2, 9, 3]), [])
        // Nor does one that is not on screen.
        XCTAssertEqual(t.stackRaiseOrder(focused: 1, frontToBack: [1, 3], visible: [1, 3]), [])
        XCTAssertEqual(t.stackRaiseOrder(focused: 1, frontToBack: [3, 1], visible: [1, 3]), [1])

        let five = stackOf(1, 2, 3, 4, 5)
        XCTAssertEqual(five.stackRaiseOrder(focused: 3, frontToBack: [3, 2, 4, 1, 5]), [])
        XCTAssertEqual(five.stackRaiseOrder(focused: 3, frontToBack: [3, 1, 2, 5, 4]), [4, 1, 2, 3])
        XCTAssertEqual(five.stackRaiseOrder(focused: 3, frontToBack: [3, 2, 1, 5, 4]), [4, 1, 2, 3], "only what is at the back and in order is left alone")
        XCTAssertEqual(five.stackRaiseOrder(focused: 3, frontToBack: [3, 5, 4, 2, 1]), [4, 1, 2, 3])
        XCTAssertEqual(five.stackRaiseOrder(focused: 3, frontToBack: [3, 4, 5, 1, 2]), [2, 3])
    }

    func testRaisingInTheGivenOrderAlwaysPutsTheStackRight() {
        var seed: UInt64 = 11
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let t = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), split(.vertical, win(2), stack(.vertical, win(3), win(4))), win(5), win(6))))
        for _ in 0..<300 {
            var order: [WindowID] = [1, 2, 3, 4, 5, 6, 9]
            for i in order.indices.reversed() where i > 0 { order.swapAt(i, next(i + 1)) }
            let focused = order[next(order.count)]
            let raise = t.stackRaiseOrder(focused: focused, frontToBack: order)
            if focused == 9 {
                XCTAssertEqual(raise, [], "a window outside the stack leaves it as it is")
                continue
            }
            // Raising a window puts it in front of everything.
            for id in raise { order = [id] + order.filter { $0 != id } }
            if !raise.isEmpty { XCTAssertEqual(order.first, focused, "the focused window is raised last") }
            XCTAssertEqual(t.stackRaiseOrder(focused: focused, frontToBack: order), [], "after \(raise) with \(focused) focused")
        }
    }

    func testOutsideAStackNothingIsRaised() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertEqual(t.stackRaiseOrder(focused: 2, frontToBack: [3, 1, 2]), [])
        let beside = Tree(snapshot: split(.horizontal, win(9), stack(.horizontal, win(1), win(2), win(3))))
        XCTAssertEqual(beside.stackRaiseOrder(focused: 9, frontToBack: [9, 1, 3, 2]), [], "only the stack the focus is in is put in order")
        XCTAssertEqual(beside.stackRaiseOrder(focused: 7, frontToBack: [9, 1, 3, 2]), [])
    }

    func testRandomOperationsWithStacksKeepEveryWindowOnScreen() {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        func assertCanonical(_ n: Node, isRoot: Bool) {
            guard let o = n.orientation else {
                XCTAssertFalse(n.stacked, "a window is never stacked")
                return
            }
            if !isRoot { XCTAssertGreaterThan(n.children.count, 1) }
            if n.children.count < 2 { XCTAssertFalse(n.stacked, "a stack of one") }
            for c in n.children {
                XCTAssertTrue(c.parent === n)
                if c.orientation == o { XCTAssertNotEqual(c.stacked, n.stacked) }
                assertCanonical(c, isRoot: false)
            }
        }
        let t = Tree()
        var alive = Set<WindowID>()
        var nextID: WindowID = 1
        for _ in 0..<3000 {
            let ids = alive.sorted()
            let pick = ids.isEmpty ? nil : ids[next(ids.count)]
            let dir = Direction.allCases[next(4)]
            switch next(9) {
            case 0, 1:
                t.insert(nextID, after: pick, split: [nil, .horizontal, .vertical][next(3)])
                alive.insert(nextID)
                nextID += 1
            case 2:
                if let pick, alive.count > 1 {
                    t.remove(pick)
                    alive.remove(pick)
                }
            case 3: if let pick { t.move(pick, dir) }
            case 4: if let pick { t.join(pick, with: dir) }
            case 5: if let pick { t.flip(pick) }
            case 6: if let pick { t.changeShare(of: pick, .delta(Double(next(5) - 2) * 0.05)) }
            case 7: if let pick { t.toggleStack(pick) }
            default: if let pick, let other = ids.last { t.swap(pick, other) }
            }
            XCTAssertEqual(Set(t.windows), alive)
            XCTAssertEqual(t.windows.count, alive.count, "no window appears twice")
            assertCanonical(t.root, isRoot: true)
            let hidden = Set(ids.filter { _ in next(4) == 0 })
            for visible in [nil, alive.subtracting(hidden)] as [Set<WindowID>?] {
                let f = frames(t, visible: visible)
                XCTAssertEqual(Set(f.keys), visible ?? alive)
                for (id, frame) in f {
                    XCTAssertTrue(screen.insetBy(dx: -1, dy: -1).contains(frame), "window \(id) at \(frame) left the screen")
                }
                // Focus never points at the window it starts from, or at one that is not shown.
                if let pick, let origin = f[pick] {
                    let to = focusTarget(from: pick, at: origin, direction: dir, among: f, trees: [t], visible: visible, frontToBack: ids.reversed())
                    XCTAssertNotEqual(to, pick)
                    if let to { XCTAssertNotNil(f[to]) }
                }
            }
            let back = Tree(snapshot: t.snapshot)
            XCTAssertEqual(back.snapshot, t.snapshot, "a saved layout loads as it was")
        }
    }

    // MARK: The command, its shortcut and the setting

    func testStackCommandShortcutAndPeek() throws {
        XCTAssertEqual(try Command.parse("stack"), .stack)
        XCTAssertThrowsError(try Command.parse("stack left"))
        XCTAssertEqual(Config.default.stackPeek, 32)
        XCTAssertTrue(Config.default.bindings.contains { $0.source == "option-s" && $0.command == .stack })

        let (wide, none) = try Config.load("[layout]\nstack-peek = 64\n")
        XCTAssertEqual(wide.stackPeek, 64)
        XCTAssertTrue(none.isEmpty)
        for bad in ["4", "121", "\"wide\""] {
            let (kept, warnings) = try Config.load("[layout]\nstack-peek = \(bad)\n")
            XCTAssertEqual(kept.stackPeek, 32, bad)
            XCTAssertEqual(warnings.count, 1, bad)
        }
    }
}
