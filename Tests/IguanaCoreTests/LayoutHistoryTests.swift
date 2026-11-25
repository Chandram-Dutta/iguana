import XCTest
@testable import IguanaCore

/// `undo` and `redo`: the steps kept for each layout, and putting a layout back in a tree.
final class LayoutHistoryTests: XCTestCase {
    func win(_ id: WindowID, _ weight: Double = 1) -> NodeSnapshot { NodeSnapshot(window: id, orientation: nil, weight: weight, children: nil) }
    func split(_ o: Orientation, _ kids: NodeSnapshot...) -> NodeSnapshot { NodeSnapshot(window: nil, orientation: o, weight: 1, children: kids) }
    /// A different layout for every number.
    func layout(_ n: Int) -> NodeSnapshot { split(.horizontal, win(1, Double(n + 1)), win(2)) }

    func testUndoAndRedoGoBackAndForth() {
        var h = LayoutHistory()
        let a = layout(0), b = layout(1), c = layout(2)
        h.record(key: "d", before: a, after: b)
        h.record(key: "d", before: b, after: c)
        XCTAssertEqual(h.undo(key: "d", current: c), b)
        XCTAssertEqual(h.undo(key: "d", current: b), a)
        XCTAssertNil(h.undo(key: "d", current: a), "nothing older to go back to")
        XCTAssertEqual(h.redo(key: "d", current: a), b)
        XCTAssertEqual(h.redo(key: "d", current: b), c)
        XCTAssertNil(h.redo(key: "d", current: c))
        XCTAssertEqual(h.undo(key: "d", current: c), b, "what was redone can be undone again")
    }

    func testAChangeThatChangedNothingIsNotAStep() {
        var h = LayoutHistory()
        h.record(key: "d", before: layout(0), after: layout(0))
        XCTAssertNil(h.undo(key: "d", current: layout(0)))
    }

    func testANewStepClearsWhatCouldBeRedone() {
        var h = LayoutHistory()
        h.record(key: "d", before: layout(0), after: layout(1))
        XCTAssertEqual(h.undo(key: "d", current: layout(1)), layout(0))
        h.record(key: "d", before: layout(0), after: layout(2))
        XCTAssertNil(h.redo(key: "d", current: layout(2)))
        XCTAssertEqual(h.undo(key: "d", current: layout(2)), layout(0))
    }

    func testRedoBringsBackTheLayoutAsItWasAtTheUndo() {
        var h = LayoutHistory()
        h.record(key: "d", before: layout(0), after: layout(1))
        // A window opened after the step: the layout now has a third window.
        let grown = split(.horizontal, win(1, 2), win(2), win(3))
        XCTAssertEqual(h.undo(key: "d", current: grown), layout(0))
        XCTAssertEqual(h.redo(key: "d", current: layout(0)), grown)
    }

    func testAStepThatWouldChangeNothingIsPassedOver() {
        var h = LayoutHistory()
        h.record(key: "d", before: layout(0), after: layout(1))
        h.record(key: "d", before: layout(1), after: layout(2))
        // Something that is not a step put the layout back as it was before the second step.
        XCTAssertEqual(h.undo(key: "d", current: layout(1)), layout(0))
        XCTAssertNil(h.undo(key: "d", current: layout(0)))
    }

    func testOnlyTheLastFiftyStepsAreKept() {
        var h = LayoutHistory()
        for n in 0..<60 { h.record(key: "d", before: layout(n), after: layout(n + 1)) }
        var current = layout(60)
        var undone: [NodeSnapshot] = []
        while let back = h.undo(key: "d", current: current) {
            undone.append(back)
            current = back
        }
        XCTAssertEqual(LayoutHistory.limit, 50)
        XCTAssertEqual(undone.count, 50)
        XCTAssertEqual(undone.last, layout(10), "the oldest steps are the ones forgotten")
        var redone = 0
        while let forward = h.redo(key: "d", current: current) {
            redone += 1
            current = forward
        }
        XCTAssertEqual(redone, 50)
        XCTAssertEqual(current, layout(60))
    }

    func testEachLayoutHasItsOwnSteps() {
        var h = LayoutHistory()
        h.record(key: "one", before: layout(0), after: layout(1))
        h.record(key: "two", before: layout(5), after: layout(6))
        XCTAssertEqual(h.undo(key: "two", current: layout(6)), layout(5))
        XCTAssertNil(h.undo(key: "two", current: layout(5)))
        XCTAssertNil(h.redo(key: "one", current: layout(1)), "an undo on one layout leaves the other alone")
        h.forget(key: "one")
        XCTAssertNil(h.undo(key: "one", current: layout(1)))
        XCTAssertEqual(h.redo(key: "two", current: layout(5)), layout(6), "forgetting one layout keeps the other's steps")
    }

    // MARK: Putting a layout back

    func testRestorePutsBackStructureWeightsAndStacks() {
        let t = Tree()
        for id: WindowID in 1...4 { t.insert(id, after: id == 1 ? nil : id - 1, split: id == 3 ? .vertical : nil) }
        XCTAssertNotNil(t.toggleStack(3))
        t.changeShare(of: 1, .delta(0.1))
        let saved = t.snapshot

        t.toggleStack(3)
        t.flip(1)
        t.move(4, .left)
        t.balance()
        XCTAssertNotEqual(t.snapshot, saved)

        let root = t.root
        t.restore(saved)
        XCTAssertEqual(t.snapshot, saved)
        XCTAssertFalse(t.root === root, "the arrangement is new, the tree is the same")
        XCTAssertTrue(t.root.children.contains { $0.stacked })
    }

    func testRestoreKeepsTheFocusOnlyOnAWindowThatIsThere() {
        let t = Tree(snapshot: split(.horizontal, win(1), win(2)))
        let saved = t.snapshot
        t.insert(3, after: 2)
        t.focused = 2
        t.restore(saved)
        XCTAssertEqual(t.focused, 2)

        t.insert(3, after: 2)
        t.focused = 3
        t.restore(saved)
        XCTAssertNil(t.focused, "the focused window is not in the layout put back")
        XCTAssertFalse(t.contains(3))
        XCTAssertEqual(t.windows, [1, 2])
    }

    func testRestoreTidiesAnUntrustedSnapshot() {
        let t = Tree()
        t.restore(split(.horizontal, win(1), split(.horizontal, win(2), win(1)), split(.vertical, win(3))))
        XCTAssertEqual(t.windows.sorted(), [1, 2, 3], "a duplicate is dropped")
        XCTAssertTrue(t.root.children.allSatisfy { $0.windowID != nil }, "and the nesting tidied")
    }

    // MARK: Commands and shortcuts

    func testCommandsAndShortcuts() throws {
        XCTAssertEqual(try Command.parse("undo"), .undo)
        XCTAssertEqual(try Command.parse("Redo"), .redo)
        XCTAssertThrowsError(try Command.parse("undo 2"))
        XCTAssertTrue(Command.usage.contains("\nundo "))
        XCTAssertTrue(Command.usage.contains("\nredo "))
        XCTAssertTrue(Config.default.bindings.contains { $0.source == "option-z" && $0.command == .undo })
        XCTAssertTrue(Config.default.bindings.contains { $0.source == "option-shift-z" && $0.command == .redo })
    }
}
