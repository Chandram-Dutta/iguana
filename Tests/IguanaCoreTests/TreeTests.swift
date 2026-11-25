import CoreGraphics
import XCTest
@testable import IguanaCore

/// The layout tree: windows going in and out, moving, joining, flipping, swapping, resizing, and saving it.
final class TreeTests: XCTestCase, TestScreen {
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

    func testSameSlotInsertReplacesOnScreen() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.changeShare(of: 1, .delta(0.2))
        let before = frames(t)[1]
        t.insert(7, after: 1, sameSlot: true)          // window 7 is a tab that replaced window 1
        XCTAssertEqual(frames(t, visible: [7, 2])[7], before)
        XCTAssertEqual(frames(t, visible: [1, 2])[1], before)
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
