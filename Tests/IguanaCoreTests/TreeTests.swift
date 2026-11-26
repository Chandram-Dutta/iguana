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

    // MARK: Native tabs

    func testATabThatComesForwardTakesTheLeafOfTheTabItReplaces() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.changeShare(of: 1, .delta(0.2))
        let before = frames(t)[1]
        XCTAssertTrue(t.insert(7, after: 1, sameSlot: true))          // window 7 is a tab that replaced window 1
        XCTAssertEqual(t.windows, [7, 2], "the two tabs are one leaf")
        XCTAssertEqual(frames(t)[7], before)
        XCTAssertFalse(t.contains(1), "the tab that is not in front has no leaf")
        XCTAssertEqual(t.inFront(of: 1), 7)
        XCTAssertNil(t.inFront(of: 7))
        XCTAssertNil(t.inFront(of: 2))
        XCTAssertNil(t.inFront(of: 99))

        // The first tab is chosen again.
        XCTAssertTrue(t.insert(1, after: 7, sameSlot: true))
        XCTAssertEqual(t.windows, [1, 2])
        XCTAssertEqual(frames(t)[1], before)
        XCTAssertEqual(t.inFront(of: 7), 1)
        XCTAssertFalse(t.insert(1, after: 1, sameSlot: true), "a window does not replace itself")
    }

    func testATabFindsItsWindowWhereItWasPutWhileAnotherTabWasInFront() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        t.insert(4, after: 3, split: .vertical)
        t.insert(7, after: 1, sameSlot: true)
        // With tab 7 in front the window is made wider, moved to the right and swapped.
        t.changeShare(of: 7, .delta(0.2))
        XCTAssertTrue(t.move(7, .right))
        XCTAssertTrue(t.swap(7, 4))
        XCTAssertEqual(t.windows, [2, 4, 3, 7])
        let there = frames(t)[7]
        let layout = t.describe { $0 == 7 ? "the tabbed window" : "window \($0)" }

        t.insert(1, after: 7, sameSlot: true)
        XCTAssertEqual(t.windows, [2, 4, 3, 1])
        XCTAssertEqual(frames(t)[1], there, "tab 1 has the place its window has now")
        XCTAssertEqual(t.describe { $0 == 1 ? "the tabbed window" : "window \($0)" }, layout, "and nothing else in the layout has changed")
    }

    func testThreeTabsAreOneLeaf() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.insert(7, after: 1, sameSlot: true)
        t.insert(8, after: 7, sameSlot: true)
        XCTAssertEqual(t.windows, [8, 2])
        XCTAssertEqual(t.inFront(of: 1), 8)
        XCTAssertEqual(t.inFront(of: 7), 8)

        t.changeShare(of: 8, .delta(0.2))
        let there = frames(t)[8]
        // Straight back to the first one, past the second.
        t.insert(1, after: 8, sameSlot: true)
        XCTAssertEqual(t.windows, [1, 2])
        XCTAssertEqual(frames(t)[1], there)
        XCTAssertEqual(t.inFront(of: 7), 1)
        XCTAssertEqual(t.inFront(of: 8), 1)
    }

    func testTheFocusGoesWithTheTabThatComesForward() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.focused = 1
        t.insert(7, after: 1, sameSlot: true)
        XCTAssertEqual(t.focused, 7, "new windows go on opening next to this window")
        t.focused = 2
        t.insert(1, after: 7, sameSlot: true)
        XCTAssertEqual(t.focused, 2)
    }

    func testClosingTheTabInFrontLeavesItsLeafToTheTabThatWasInFrontBefore() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.insert(7, after: 1, sameSlot: true)
        t.insert(8, after: 7, sameSlot: true)
        t.changeShare(of: 8, .delta(0.2))
        t.focused = 8
        let there = frames(t)[8]

        XCTAssertTrue(t.remove(8))
        XCTAssertEqual(t.windows, [7, 2], "the window is still there, with another tab")
        XCTAssertEqual(frames(t)[7], there)
        XCTAssertEqual(t.inFront(of: 1), 7)
        XCTAssertNil(t.focused)

        XCTAssertTrue(t.remove(7))
        XCTAssertEqual(t.windows, [1, 2])
        XCTAssertEqual(frames(t)[1], there)
        XCTAssertTrue(t.remove(1))
        XCTAssertEqual(t.windows, [2], "its last tab closed, the window is gone")
    }

    func testClosingATabThatIsNotInFrontChangesNothing() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.insert(7, after: 1, sameSlot: true)
        let before = t.snapshot

        XCTAssertTrue(t.remove(1))
        XCTAssertEqual(t.snapshot, before)
        XCTAssertNil(t.inFront(of: 1))
        XCTAssertFalse(t.remove(1), "it is not known any more")
        // No leaf is kept for a tab that has closed.
        t.remove(7)
        XCTAssertEqual(t.windows, [2])
    }

    func testPruneDropsTheTabsThatAreGoneBeforeItGivesALeafAway() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.insert(7, after: 1, sameSlot: true)
        t.insert(8, after: 7, sameSlot: true)
        // The tab in front and the one that was in front before it close together.
        t.prune { $0 != 8 && $0 != 7 }
        XCTAssertEqual(t.windows, [1, 2], "the leaf goes to the tab that is left")
        XCTAssertNil(t.inFront(of: 7))
        t.prune { $0 != 1 }
        XCTAssertEqual(t.windows, [2])
    }

    func testAWindowThatGetsALeafOfItsOwnIsNoLongerATab() {
        // A tab that is dragged out of its window is a window of its own.
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.insert(7, after: 1, sameSlot: true)
        XCTAssertTrue(t.insert(1, after: 2))
        XCTAssertEqual(t.windows, [7, 2, 1])
        XCTAssertNil(t.inFront(of: 1))
        t.remove(7)
        XCTAssertEqual(t.windows, [2, 1], "so it does not take the leaf of the window it left")

        // The same when it is put somewhere as a drop does.
        for put in [{ (t: Tree) in t.place(1, beside: 2, on: .right) }, { (t: Tree) in t.place(1, nextTo: 2) }] {
            let t = Tree()
            [1, 2].forEach { t.insert($0) }
            t.insert(7, after: 1, sameSlot: true)
            XCTAssertTrue(put(t))
            XCTAssertEqual(t.windows, [7, 2, 1])
            XCTAssertNil(t.inFront(of: 1))
        }
    }

    func testAWindowKeepsItsTabsWhereverItIsPut() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        t.insert(7, after: 1, sameSlot: true)
        // Dropped on an edge, dropped on a stack, and the whole desktop arranged.
        XCTAssertTrue(t.place(7, beside: 3, on: .down))
        XCTAssertTrue(t.place(7, nextTo: 2))
        t.arrange(.rows, order: [3, 7, 2])
        XCTAssertEqual(t.windows, [3, 7, 2])
        XCTAssertEqual(t.inFront(of: 1), 7)
        let there = frames(t)[7]
        t.insert(1, after: 7, sameSlot: true)
        XCTAssertEqual(frames(t)[1], there)
    }

    func testTheTabInFrontTakesThePlaceAnEarlierArrangementHasForItsWindow() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        let even = t.snapshot
        let first = frames(t)[1]
        t.insert(7, after: 1, sameSlot: true)
        t.changeShare(of: 7, .delta(0.2))
        t.move(7, .right)
        XCTAssertEqual(t.windows, [2, 7, 3])

        // Undo goes back to an arrangement from when the other tab was in front.
        t.restore(even)
        XCTAssertEqual(t.windows, [7, 2, 3], "it is the tab in front now that is put there")
        XCTAssertEqual(frames(t)[7], first)
        XCTAssertEqual(t.inFront(of: 1), 7)

        // An arrangement the window is not in at all forgets its tabs with it.
        t.remove(2)
        let without = Tree()
        [2, 3].forEach { without.insert($0) }
        t.restore(without.snapshot)
        XCTAssertEqual(t.windows, [2, 3])
        XCTAssertNil(t.inFront(of: 1))
        XCTAssertFalse(t.remove(1))
    }

    func testRandomOperationsWithTabsKeepEveryWindowInOnePlace() {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let t = Tree()
        /// The tabs that are not in front, by the tab that is. Every window with a leaf is a key.
        var tabs: [WindowID: [WindowID]] = [:]
        var nextID: WindowID = 1
        for _ in 0..<1000 {
            let fronts = tabs.keys.sorted()
            let pick = fronts.isEmpty ? nil : fronts[next(fronts.count)]
            let waiting = tabs.values.flatMap { $0 }.sorted()
            switch next(9) {
            case 0:
                t.insert(nextID, after: pick, split: [nil, .horizontal, .vertical][next(3)])
                tabs[nextID] = []
                nextID += 1
            case 1:
                // A new tab in a window.
                if let pick {
                    XCTAssertTrue(t.insert(nextID, after: pick, sameSlot: true))
                    tabs[nextID] = (tabs.removeValue(forKey: pick) ?? []) + [pick]
                    nextID += 1
                }
            case 2:
                // A tab that is not in front comes forward.
                if !waiting.isEmpty {
                    let tab = waiting[next(waiting.count)]
                    guard let front = t.inFront(of: tab) else { return XCTFail("tab \(tab) is not known") }
                    XCTAssertTrue(t.insert(tab, after: front, sameSlot: true))
                    tabs[tab] = (tabs.removeValue(forKey: front) ?? []).filter { $0 != tab } + [front]
                }
            case 3:
                // The tab in front closes.
                if let pick, tabs.count > 1 {
                    t.remove(pick)
                    var others = tabs.removeValue(forKey: pick) ?? []
                    if let last = others.popLast() { tabs[last] = others }
                }
            case 4:
                // A tab that is not in front closes, or is dragged out of its window.
                if !waiting.isEmpty {
                    let tab = waiting[next(waiting.count)]
                    for (front, others) in tabs { tabs[front] = others.filter { $0 != tab } }
                    if next(2) == 0 {
                        XCTAssertTrue(t.remove(tab))
                    } else {
                        XCTAssertTrue(t.insert(tab, after: pick))
                        tabs[tab] = []
                    }
                }
            case 5: if let pick { t.move(pick, Direction.allCases[next(4)]) }
            case 6: if let pick { t.join(pick, with: Direction.allCases[next(4)]) }
            case 7: if let pick, let other = fronts.last, pick != other { t.place(pick, beside: other, on: Direction.allCases[next(4)]) }
            default: if let pick, let other = fronts.last { t.swap(pick, other) }
            }
            XCTAssertEqual(Set(t.windows), Set(tabs.keys))
            XCTAssertEqual(t.windows.count, tabs.count, "no window has two leaves")
            for (front, others) in tabs {
                XCTAssertNil(t.inFront(of: front))
                for tab in others {
                    XCTAssertEqual(t.inFront(of: tab), front)
                    XCTAssertFalse(t.contains(tab))
                }
            }
            assertCanonical(t.root, isRoot: true)
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
