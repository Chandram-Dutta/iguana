import CoreGraphics
import XCTest
@testable import IguanaCore

final class TreeTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func frames(_ t: Tree, visible: Set<WindowID>? = nil, gap: CGFloat = 0, mins: [WindowID: CGSize] = [:]) -> [WindowID: CGRect] {
        computeLayout(t, in: screen, gap: gap, visible: visible, minSizes: mins)
    }

    func testFlatInsertSharesTheRowEqually() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1)
        t.insert(3, after: 1)
        XCTAssertEqual(t.windows, [1, 3, 2])
        let f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 333, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 333, y: 0, width: 334, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 667, y: 0, width: 333, height: 600))
    }

    func testDwindleSplitsTheFocusedWindow() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)
        let f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    func testSplitOfLoneWindowTurnsTheRoot() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .vertical)
        XCTAssertEqual(t.root.orientation, .vertical)
        XCTAssertEqual(frames(t)[2], CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    func testRemoveCollapsesContainers() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)
        t.remove(3)
        XCTAssertEqual(t.root.children.count, 2)
        XCTAssertTrue(t.root.children.allSatisfy { $0.windowID != nil })
        XCTAssertEqual(frames(t)[2], CGRect(x: 500, y: 0, width: 500, height: 600))
        t.remove(1)
        t.remove(2)
        XCTAssertTrue(t.isEmpty)
        XCTAssertTrue(frames(t).isEmpty)
    }

    func testMoveSwapsWithNeighbourWindow() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.move(1, .right))
        XCTAssertEqual(t.windows, [2, 1, 3])
        XCTAssertTrue(t.move(1, .right))
        XCTAssertEqual(t.windows, [2, 3, 1])
        XCTAssertFalse(t.move(1, .right), "already at the right edge")
    }

    func testMovePerpendicularWrapsTheRoot() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.move(2, .down))
        XCTAssertEqual(t.root.orientation, .vertical)
        let f = frames(t)
        XCTAssertEqual(f[2], CGRect(x: 0, y: 300, width: 1000, height: 300))
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 300))
    }

    func testMoveIntoAndOutOfAContainer() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)   // 1 | (2 / 3)
        XCTAssertTrue(t.move(1, .right))           // 1 joins the stack
        XCTAssertEqual(t.root.orientation, .vertical)
        XCTAssertEqual(Set(t.windows), [1, 2, 3])
        XCTAssertEqual(frames(t)[1]?.width, 1000)

        XCTAssertTrue(t.move(1, .left))            // 1 leaves the stack to the left
        let f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2]?.minX, 500)
        XCTAssertEqual(f[3]?.minX, 500)
    }

    func testMoveOutOfNestedContainerLandsBesideIt() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)   // 1 | (2 / 3)
        XCTAssertTrue(t.move(3, .left))            // 1 | 3 | 2
        XCTAssertEqual(t.windows, [1, 3, 2])
        XCTAssertEqual(t.root.children.count, 3)
    }

    func testMoveSkipsHiddenWindows() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.move(1, .right, visible: [1, 3]))
        XCTAssertEqual(t.windows, [3, 2, 1])
        XCTAssertFalse(t.move(1, .right, visible: [1, 3]))
    }

    func testLoneVisibleWindowDoesNotMove() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        XCTAssertFalse(t.move(1, .down, visible: [1]))
        XCTAssertFalse(t.move(1, .right, visible: [1]))
    }

    func testJoinStacksTwoWindows() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.join(1, with: .right))
        let f = frames(t)
        XCTAssertEqual(f[2], CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[1], CGRect(x: 0, y: 300, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertFalse(t.join(3, with: .right))
    }

    func testFlipTurnsTheContainer() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        XCTAssertTrue(t.flip(1))
        XCTAssertEqual(frames(t)[2], CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    func testSwap() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.swap(1, 3))
        XCTAssertEqual(t.windows, [3, 2, 1])
        XCTAssertFalse(t.swap(1, 9))
    }

    func testChangeShareByDeltaAndRatio() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        XCTAssertTrue(t.changeShare(of: 1, .delta(0.1)))
        XCTAssertEqual(frames(t)[1]!.width, 600, accuracy: 1)
        XCTAssertTrue(t.changeShare(of: 1, .ratio(0.5)))
        XCTAssertEqual(frames(t)[1]!.width, 300, accuracy: 1)
        t.balance()
        XCTAssertEqual(frames(t)[1]!.width, 500, accuracy: 1)
        XCTAssertFalse(t.changeShare(of: 1, along: .vertical, .delta(0.1)), "nothing to resize against vertically")
    }

    func testShareIsClamped() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        for _ in 0..<40 { t.changeShare(of: 1, .delta(0.1)) }
        let w = frames(t)[2]!.width
        XCTAssertGreaterThan(w, 50)
        XCTAssertLessThan(w, 120)
    }

    func testHiddenWindowsKeepTheirSlotButTakeNoSpace() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        let f = frames(t, visible: [1, 3])
        XCTAssertNil(f[2])
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(frames(t)[2]?.minX, 333, "the slot is still there when it comes back")
    }

    func testSameSlotInsertReplacesOnScreen() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.changeShare(of: 1, .delta(0.2))
        let before = frames(t)[1]
        t.insert(7, after: 1, sameSlot: true)          // window 7 is a tab that replaced window 1
        XCTAssertEqual(frames(t, visible: [7, 2])[7], before)
        XCTAssertEqual(frames(t, visible: [1, 2])[1], before)
    }

    func testGapsAndMinimumSizes() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        let f = frames(t, gap: 10)
        XCTAssertEqual(f[1]!.maxX + 10, f[2]!.minX)
        XCTAssertEqual(f[2]!.maxX + 10, f[3]!.minX)
        XCTAssertEqual(f[3]!.maxX, 1000)

        let m = frames(t, mins: [1: CGSize(width: 600, height: 0)])
        XCTAssertEqual(m[1]!.width, 600)
        XCTAssertEqual(m[3]!.width, 200)
        XCTAssertEqual(m[2]!.width, 200)
    }

    func testResizingStartsFromWhatIsOnScreen() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        let mins: [WindowID: CGSize] = [1: CGSize(width: 600, height: 0)]
        // Shrinking a window that is at its minimum shows nothing, however often it is asked.
        for _ in 0..<10 {
            t.matchWeights(to: frames(t, mins: mins))
            t.changeShare(of: 1, .delta(-0.05))
            XCTAssertEqual(frames(t, mins: mins)[1]!.width, 600)
        }
        // The first step back the other way shows at once, instead of paying off ten unseen ones.
        t.matchWeights(to: frames(t, mins: mins))
        t.changeShare(of: 1, .delta(0.05))
        XCTAssertEqual(frames(t, mins: mins)[1]!.width, 650, accuracy: 1)
    }

    func testMatchingWeightsLeavesAnHonestLayoutAlone() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        t.insert(4, after: 3, split: .vertical)
        t.changeShare(of: 1, .delta(0.1))
        let before = t.snapshot
        t.matchWeights(to: frames(t, gap: 10))
        XCTAssertEqual(t.snapshot, before)
        // Windows that are not on screen keep their weight.
        t.matchWeights(to: frames(t, visible: [1, 2], mins: [1: CGSize(width: 700, height: 0)]), visible: [1, 2])
        XCTAssertEqual(frames(t, visible: [1, 2])[1]!.width, 700, accuracy: 1)
        XCTAssertNotNil(frames(t)[3])
    }

    func testMinimumSizesThatDoNotFitAreScaled() {
        XCTAssertEqual(distribute(total: 100, weights: [1, 1], mins: [80, 80]), [50, 50])
        XCTAssertEqual(distribute(total: 100, weights: [1, 3], mins: [0, 0]), [25, 75])
    }

    func testSnapshotRoundTrip() throws {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)
        t.changeShare(of: 1, .delta(0.1))
        let data = try JSONEncoder().encode(t.snapshot)
        let back = Tree(snapshot: try JSONDecoder().decode(NodeSnapshot.self, from: data))
        XCTAssertEqual(frames(back), frames(t))
        back.prune { $0 != 3 }
        XCTAssertEqual(back.windows, [1, 2])
    }

    func testSnapshotWithDuplicateIdsIsRepaired() {
        let dup = NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: [
            NodeSnapshot(window: 1, orientation: nil, weight: 1, children: nil),
            NodeSnapshot(window: 1, orientation: nil, weight: 1, children: nil),
        ])
        XCTAssertEqual(Tree(snapshot: dup).windows, [1])
    }

    func testRandomOperationsKeepTheTreeConsistent() {
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let t = Tree()
        var alive = Set<WindowID>()
        var nextID: WindowID = 1
        for _ in 0..<3000 {
            let ids = alive.sorted()
            let pick = ids.isEmpty ? nil : ids[next(ids.count)]
            let dir = Direction.allCases[next(4)]
            switch next(8) {
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
            default: if let pick, let other = ids.last { t.swap(pick, other) }
            }
            XCTAssertEqual(Set(t.windows), alive)
            XCTAssertEqual(t.windows.count, alive.count, "no window appears twice")
            assertCanonical(t.root, isRoot: true)
            let f = frames(t)
            XCTAssertEqual(f.count, alive.count)
            let area = f.values.reduce(0) { $0 + $1.width * $1.height }
            if !alive.isEmpty { XCTAssertEqual(area, screen.width * screen.height, accuracy: 1, "windows cover the screen exactly") }
        }
    }

    func assertCanonical(_ n: Node, isRoot: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard let o = n.orientation else { return }
        if !isRoot { XCTAssertGreaterThan(n.children.count, 1, "container with fewer than two children", file: file, line: line) }
        for c in n.children {
            XCTAssertTrue(c.parent === n, file: file, line: line)
            // A stack inside a split that runs the same way (or the other way round) is not the same arrangement twice.
            if c.orientation == o { XCTAssertNotEqual(c.stacked, n.stacked, "nested container arranges its children the same way as its parent", file: file, line: line) }
            XCTAssertGreaterThan(c.weight, 0, file: file, line: line)
            assertCanonical(c, isRoot: false, file: file, line: line)
        }
    }
}

final class StackTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func frames(_ t: Tree, visible: Set<WindowID>? = nil, gap: CGFloat = 0, mins: [WindowID: CGSize] = [:], peek: CGFloat = 32) -> [WindowID: CGRect] {
        computeLayout(t, in: screen, gap: gap, visible: visible, minSizes: mins, peek: peek)
    }

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
}

final class FocusTests: XCTestCase {
    func testNearestPrefersOverlapThenDistance() {
        let frames: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 500, height: 600),
            2: CGRect(x: 500, y: 0, width: 500, height: 300),
            3: CGRect(x: 500, y: 300, width: 500, height: 300),
        ]
        XCTAssertEqual(nearestWindow(from: frames[1]!, direction: .right, among: frames, excluding: 1), 2)
        XCTAssertEqual(nearestWindow(from: frames[3]!, direction: .left, among: frames, excluding: 3), 1)
        XCTAssertEqual(nearestWindow(from: frames[2]!, direction: .down, among: frames, excluding: 2), 3)
        XCTAssertNil(nearestWindow(from: frames[1]!, direction: .left, among: frames, excluding: 1))
        XCTAssertNil(nearestWindow(from: frames[2]!, direction: .up, among: frames, excluding: 2))
    }
}

final class ConfigTests: XCTestCase {
    func testTOMLBasics() throws {
        let doc = try TOML.parse("""
        # comment
        name = "a \\"b\\""   # trailing
        n = 1_000
        f = -0.5
        on = true
        list = [1, 2,
                3]
        point = { x = 1, y = 2 }
        a.b = 'lit'

        [t.sub]
        "quoted key" = 1

        [[item]]
        v = 1
        [[item]]
        v = 2
        """)
        XCTAssertEqual(doc["name"], .string("a \"b\""))
        XCTAssertEqual(doc["n"], .int(1000))
        XCTAssertEqual(doc["f"], .double(-0.5))
        XCTAssertEqual(doc["on"], .bool(true))
        XCTAssertEqual(doc["list"], .array([.int(1), .int(2), .int(3)]))
        XCTAssertEqual(doc["point"], .table(["x": .int(1), "y": .int(2)]))
        XCTAssertEqual(doc["a"], .table(["b": .string("lit")]))
        XCTAssertEqual(doc["t"], .table(["sub": .table(["quoted key": .int(1)])]))
        XCTAssertEqual(doc["item"], .array([.table(["v": .int(1)]), .table(["v": .int(2)])]))
    }

    func testTOMLErrorsCarryTheLine() {
        XCTAssertThrowsError(try TOML.parse("a = 1\nb = oops\n")) { e in
            XCTAssertEqual((e as? TOMLError)?.line, 2)
        }
        XCTAssertThrowsError(try TOML.parse("a = \"open\n"))
        XCTAssertThrowsError(try TOML.parse("a = 1 2\n"))
        XCTAssertThrowsError(try TOML.parse("a = 1\n[a]\n"))
        XCTAssertEqual(try TOML.parse("a = 1\r\nb = 2\r\n"), ["a": .int(1), "b": .int(2)], "Windows line endings")
    }

    func testOptionIsTheNameOfTheKeyAndTheOldSpellingIsStillRead() throws {
        let option = try KeyCombo.parse("option-shift-h")
        XCTAssertEqual(option.modifiers, [.option, .shift])
        XCTAssertEqual(try KeyCombo.parse("opt-shift-h"), option)
        XCTAssertEqual(try KeyCombo.parse("alt-shift-h"), option, "configs written for other window managers keep working")
        // The built-in shortcuts are written with the name Iguana uses.
        XCTAssertFalse(Config.defaultText.contains("alt-"))
        XCTAssertTrue(Config.default.bindings.allSatisfy { $0.source.hasPrefix("option-") })
    }

    func testMenuBarDesktopsIsOffUntilAskedFor() throws {
        XCTAssertEqual(Config.default.menuBarDesktops, .current)
        let (all, none) = try Config.load("[menu-bar]\ndesktops = \"all\"\n")
        XCTAssertEqual(all.menuBarDesktops, .all)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(try Config.load("[menu-bar]\ndesktops = \"occupied\"\n").0.menuBarDesktops, .occupied)

        let (kept, warnings) = try Config.load("[menu-bar]\ndesktops = \"some\"\nicons = true\n")
        XCTAssertEqual(kept.menuBarDesktops, .current)
        XCTAssertEqual(warnings.count, 2, "one for the value, one for the unknown key")

        // A click on a drawn desktop only switches when that is asked for as well.
        XCTAssertFalse(Config.default.menuBarClickSwitches)
        XCTAssertFalse(all.menuBarClickSwitches)
        XCTAssertTrue(try Config.load("[menu-bar]\ndesktops = \"all\"\nclick-to-switch = true\n").0.menuBarClickSwitches)
    }

    func testDefaultConfigLoadsCleanly() throws {
        let (c, warnings) = try Config.load(Config.defaultText)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.gapInner, 8)
        XCTAssertEqual(c.stripReserve, .auto)
        XCTAssertEqual(c.bindings.count, 41)
        XCTAssertEqual(c.rules.count, 3)
        XCTAssertTrue(c.bindings.contains { $0.source == "option-shift-3" && $0.command == .moveToSpace(.index(3), follow: true) })
        XCTAssertEqual(Config.default, c)
    }

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

    func testConfigOverridesAndWarnings() throws {
        let (c, warnings) = try Config.load("""
        [gaps]
        inner = 0
        outer = { top = 20 }
        bogus = 1
        [layout]
        auto-split = "yes"
        [stage-manager]
        reserve-strip = false
        [bindings]
        cmd-option-left = "focus left"
        option-q = "explode"
        hyper-x = "zoom"
        """)
        XCTAssertEqual(c.gapInner, 0)
        XCTAssertEqual(c.gapOuter.top, 20)
        XCTAssertEqual(c.gapOuter.left, 8)
        XCTAssertTrue(c.autoSplit)
        XCTAssertEqual(c.stripReserve, .off)
        XCTAssertEqual(c.bindings.count, 42, "the file's shortcut is added to the 41 built-in ones")
        XCTAssertTrue(c.bindings.contains { $0.source == "cmd-option-left" && $0.commandText == "focus left" })
        XCTAssertEqual(warnings.count, 4)
    }

    func testFileSettingsLayerOverTheDefaults() throws {
        let (c, warnings) = try Config.load("""
        [bindings]
        option-h = "focus right"    # replaces a built-in shortcut
        option-l = ""               # switches one off
        option-j = false            # also switches one off
        ctrl-option-z = "zoom"      # adds one

        [animation]
        enabled = false
        duration = 0.3
        easing = "linear"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.bindings.first { $0.source == "option-h" }?.command, .focus(.right))
        XCTAssertFalse(c.bindings.contains { $0.source == "option-l" || $0.source == "option-j" })
        XCTAssertTrue(c.bindings.contains { $0.source == "option-k" }, "untouched shortcuts stay")
        XCTAssertEqual(c.bindings.count, 41 - 2 + 1)
        XCTAssertEqual(c.rules, Config.default.rules, "no [[rule]] in the file keeps the built-in rules")
        XCTAssertFalse(c.animate)
        XCTAssertEqual(c.animationDuration, 0.3)
        XCTAssertEqual(c.animationEasing, .linear)

        let (withRules, _) = try Config.load("[[rule]]\napp = \"Preview\"\n")
        XCTAssertEqual(withRules.rules.map(\.app), ["Preview"], "a file with rules lists all of them")

        let (bad, problems) = try Config.load("[animation]\nduration = 9\neasing = \"bouncy\"\n")
        XCTAssertEqual(bad.animationDuration, Config.default.animationDuration)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(try Config.load("").config, Config.default, "an empty file is the defaults")
    }

    func testEasingAndInterpolation() {
        for e in Easing.allCases {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-9)
            XCTAssertEqual(e.apply(-3), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(7), 1, accuracy: 1e-9)
            var last = 0.0
            for i in 1...20 {
                let v = e.apply(Double(i) / 20)
                XCTAssertGreaterThanOrEqual(v, last, "\(e) never goes backwards")
                last = v
            }
        }
        XCTAssertGreaterThan(Easing.easeOut.apply(0.5), 0.5)
        let a = CGRect(x: 0, y: 0, width: 100, height: 100), b = CGRect(x: 100, y: 50, width: 300, height: 200)
        XCTAssertEqual(interpolate(a, b, 0), a)
        XCTAssertEqual(interpolate(a, b, 1), b)
        XCTAssertEqual(interpolate(a, b, 0.5), CGRect(x: 50, y: 25, width: 200, height: 150))
    }

    func testSchemaIsValidJSONAndCoversEveryKey() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let doc = try TOML.parse(Config.defaultText)
        // The default file shows a mode only in comments: none is built in.
        XCTAssertEqual(Set(properties.keys).subtracting(["mode"]), Set(doc.keys), "every top-level section of the default config is in the schema")
        for (section, value) in doc {
            guard section != "bindings", let table = value.tableValue else { continue }
            let described = try XCTUnwrap((properties[section] as? [String: Any])?["properties"] as? [String: Any], section)
            XCTAssertEqual(Set(described.keys), Set(table.keys), "keys of [\(section)]")
        }
        // The shortcut pattern accepts every built-in shortcut.
        let bindings = try XCTUnwrap(properties["bindings"] as? [String: Any])
        let pattern = try XCTUnwrap((bindings["patternProperties"] as? [String: Any])?.keys.first)
        let regex = try NSRegularExpression(pattern: pattern)
        for b in Config.default.bindings {
            XCTAssertNotNil(regex.firstMatch(in: b.source, range: NSRange(b.source.startIndex..., in: b.source)), b.source)
        }
    }

    func testRules() {
        let byID = Rule(app: "com.apple.calculator", title: nil, float: true)
        XCTAssertTrue(byID.matches(bundleID: "com.apple.calculator", appName: "Calculator", title: ""))
        XCTAssertFalse(byID.matches(bundleID: "com.apple.Safari", appName: "Safari", title: ""))
        let byTitle = Rule(app: "safari", title: "^Settings", float: true)
        XCTAssertTrue(byTitle.matches(bundleID: "com.apple.Safari", appName: "Safari", title: "Settings — General"))
        XCTAssertFalse(byTitle.matches(bundleID: "com.apple.Safari", appName: "Safari", title: "Apple"))
    }

    func testCommands() throws {
        XCTAssertEqual(try Command.parse("focus left"), .focus(.left))
        XCTAssertEqual(try Command.parse("  Move   DOWN "), .move(.down))
        XCTAssertEqual(try Command.parse("resize grow"), .resize(axis: nil, grow: 1))
        XCTAssertEqual(try Command.parse("resize height shrink"), .resize(axis: .vertical, grow: -1))
        XCTAssertEqual(try Command.parse("space prev"), .space(.prev))
        XCTAssertEqual(try Command.parse("move-to-space 4"), .moveToSpace(.index(4), follow: true))
        XCTAssertEqual(try Command.parse("move-to-space next --stay"), .moveToSpace(.next, follow: false))
        XCTAssertEqual(try Command.parse("move-to-space --stay 2"), .moveToSpace(.index(2), follow: false))
        XCTAssertEqual(try Command.parse("move-to-space 2 --follow"), .moveToSpace(.index(2), follow: true))
        XCTAssertThrowsError(try Command.parse("space 2 --stay"))
        XCTAssertThrowsError(try Command.parse("move-to-space --stay"))
        XCTAssertThrowsError(try Command.parse("move-to-space 2 --stay --follow"))
        for bad in ["", "focus", "focus north", "space 0", "space 99", "resize", "zoom now", "nope"] {
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
    }

    func testKeyCombos() throws {
        XCTAssertEqual(try KeyCombo.parse("option-shift-h"), KeyCombo(modifiers: [.option, .shift], key: "h"))
        XCTAssertEqual(try KeyCombo.parse("Cmd-Option-Left"), KeyCombo(modifiers: [.cmd, .option], key: "left"))
        XCTAssertEqual(try KeyCombo.parse("option--"), KeyCombo(modifiers: [.option], key: "minus"))
        XCTAssertThrowsError(try KeyCombo.parse("h"))
        XCTAssertThrowsError(try KeyCombo.parse("option-"))
        XCTAssertThrowsError(try KeyCombo.parse("meta-h"))
    }
}

final class TOMLEditorTests: XCTestCase {
    func testASettingWrittenAsItsOwnSectionIsReplacedNotDoubled() throws {
        let text = """
        [gaps]
        inner = 8

        # each edge by itself
        [gaps.outer]
        top = 4
        left = 6
        bottom = 4
        right = 6

        [layout]
        auto-split = true
        """
        // One number for all four edges: the section must go, or the file defines outer twice.
        var uniform = TOMLEditor(text)
        uniform.set(["gaps", "outer"], to: .int(12))
        XCTAssertFalse(uniform.text.contains("[gaps.outer]"))
        var (config, warnings) = try Config.load(uniform.text)
        XCTAssertEqual(config.gapOuter, Edges(all: 12))
        XCTAssertEqual(config.gapInner, 8)
        XCTAssertTrue(config.autoSplit)
        XCTAssertTrue(warnings.isEmpty)

        // Each edge again, now as an inline table: the old section must not win.
        var edges = TOMLEditor(text)
        edges.set(["gaps", "outer"], to: .table(["top": .int(1), "left": .int(2), "bottom": .int(3), "right": .int(4)]))
        (config, warnings) = try Config.load(edges.text)
        XCTAssertEqual(config.gapOuter.top, 1)
        XCTAssertEqual(config.gapOuter.right, 4)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(edges.text.contains("[layout]"), "the sections after it are untouched")
    }

    let original = """
    # my settings
    top = 1

    [gaps]
    inner = 8      # between windows
    outer = { top = 8, left = 8 }

    [bindings]
    option-h = "focus left"
    "option-shift-h" = "move left"   # quoted key

    # floating apps
    [[rule]]
    app = "Calculator"
    float = true

    [[rule]]
    app = "Music"
    """

    func parsed(_ e: TOMLEditor) throws -> [String: TOMLValue] { try TOML.parse(e.text) }

    func testChangingAValueKeepsEverythingElse() throws {
        var e = TOMLEditor(original)
        e.set(["gaps", "inner"], to: .int(12))
        XCTAssertTrue(e.text.contains("inner = 12      # between windows"), "the trailing comment and spacing survive")
        XCTAssertEqual(e.text.replacingOccurrences(of: "inner = 12", with: "inner = 8"), original, "nothing else changed")
        e.set(["bindings", "option-shift-h"], to: .string("move right"))
        XCTAssertTrue(e.text.contains("\"option-shift-h\" = \"move right\"   # quoted key"))
        e.set(["gaps", "outer"], to: .int(4))
        XCTAssertEqual(try parsed(e)["gaps"], .table(["inner": .int(12), "outer": .int(4)]))
    }

    func testAddingKeysAndTables() throws {
        var e = TOMLEditor(original)
        e.set(["gaps", "extra"], to: .bool(true))
        e.set(["bindings", "option-l"], to: .string("focus right"))
        e.set(["animation", "duration"], to: .double(0.25))
        e.set(["animation", "enabled"], to: .bool(false))
        e.set(["other"], to: .string("x"))
        let doc = try parsed(e)
        XCTAssertEqual(doc["gaps"]?.tableValue?["extra"], .bool(true))
        XCTAssertEqual(doc["bindings"]?.tableValue?.count, 3)
        XCTAssertEqual(doc["animation"], .table(["duration": .double(0.25), "enabled": .bool(false)]))
        XCTAssertEqual(doc["other"], .string("x"))
        XCTAssertEqual(doc["top"], .int(1))
        XCTAssertEqual(doc["rule"]?.arrayValue?.count, 2, "rules untouched")
        XCTAssertTrue(e.text.contains("# floating apps"))
        let lines = e.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.firstIndex(of: "extra = true"), lines.firstIndex { $0.hasPrefix("outer") }! + 1, "new key goes to the end of its table")
    }

    func testRemove() throws {
        var e = TOMLEditor(original)
        XCTAssertTrue(e.remove(["bindings", "option-h"]))
        XCTAssertFalse(e.remove(["bindings", "option-h"]))
        XCTAssertFalse(e.remove(["nope", "x"]))
        XCTAssertEqual(try parsed(e)["bindings"]?.tableValue?.keys.sorted(), ["option-shift-h"])
    }

    func testMultiLineValuesAndHashesInStrings() throws {
        var e = TOMLEditor("""
        list = [
          1,   # one
          2,
        ]
        title = "a # b"  # real comment
        after = true
        """)
        e.set(["title"], to: .string("c # d"))
        XCTAssertTrue(e.text.contains("title = \"c # d\"  # real comment"))
        e.set(["list"], to: .array([.int(9)]))
        XCTAssertEqual(try parsed(e), ["list": .array([.int(9)]), "title": .string("c # d"), "after": .bool(true)])
        XCTAssertTrue(e.remove(["title"]))
        XCTAssertEqual(try parsed(e).keys.sorted(), ["after", "list"])
    }

    func testReplacingRules() throws {
        var e = TOMLEditor(original)
        e.replaceArrayOfTables("rule", with: [[("app", .string("Preview")), ("title", .string("^Info")), ("float", .bool(true))]])
        let doc = try parsed(e)
        XCTAssertEqual(doc["rule"], .array([.table(["app": .string("Preview"), "title": .string("^Info"), "float": .bool(true)])]))
        XCTAssertTrue(e.text.contains("# floating apps"), "the comment above the rules stays")
        XCTAssertEqual(doc["bindings"]?.tableValue?.count, 2)
        e.replaceArrayOfTables("rule", with: [])
        XCTAssertNil(try parsed(e)["rule"])
        e.replaceArrayOfTables("rule", with: [[("app", .string("A"))], [("app", .string("B"))]])
        XCTAssertEqual(try parsed(e)["rule"]?.arrayValue?.count, 2)
    }

    func testEditingAnEmptyFileAndTheDefaultConfig() throws {
        var empty = TOMLEditor("")
        empty.set(["gaps", "inner"], to: .int(3))
        XCTAssertEqual(try parsed(empty), ["gaps": .table(["inner": .int(3)])])

        var e = TOMLEditor(Config.defaultText)
        e.set(["gaps", "inner"], to: .int(20))
        e.set(["animation", "duration"], to: .double(0.4))
        e.set(["bindings", "option-h"], to: .string(""))
        e.set(["stage-manager", "reserve-strip"], to: .bool(false))
        let (c, warnings) = try Config.load(e.text)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.gapInner, 20)
        XCTAssertEqual(c.animationDuration, 0.4)
        XCTAssertEqual(c.stripReserve, .off)
        XCTAssertFalse(c.bindings.contains { $0.source == "option-h" })
        XCTAssertEqual(e.text.components(separatedBy: "\n").count, Config.defaultText.components(separatedBy: "\n").count, "no lines added or lost")
    }

    func testFormatting() {
        XCTAssertEqual(TOMLEditor.format(.double(0.05)), "0.05")
        XCTAssertEqual(TOMLEditor.format(.double(2)), "2.0")
        XCTAssertEqual(TOMLEditor.format(.string("a\"b\\")), "\"a\\\"b\\\\\"")
        XCTAssertEqual(TOMLEditor.formatKey("option-shift-h"), "option-shift-h")
        XCTAssertEqual(TOMLEditor.formatKey("has space"), "\"has space\"")
    }
}
