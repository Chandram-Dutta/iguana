import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// What the command tests share: windows opened one after the other, and the frames a layout
/// should give them, worked out from the usable area and the gap.
///
/// Windows opened with `open(_:)` land as auto-split puts them. Two are side by side. A third
/// opens under the second, which is taller than wide. A fourth opens beside the third, which is
/// wider than tall. The window opened last has the focus.
class LayoutCommandTestCase: ScenarioTestCase {
    /// The built-in gap between two tiles.
    let gap: CGFloat = 8

    /// The area windows are tiled into: x 8, y 33, 1424 by 859 on the display of 1440 by 900.
    var area: CGRect { mac.usable() }

    /// Open `count` windows of one app, each when the one before has its tile.
    @discardableResult
    func open(_ count: Int, of name: String = "Terminal") -> [FakeWindow] {
        let app = mac.system.apps.first { $0.localizedName == name } ?? mac.system.launch(name)
        return (0..<count).map { _ in
            let window = mac.system.open(app)
            mac.settle()
            return window
        }
    }

    /// The user clicks a window, and the window manager hears of it.
    func click(_ window: FakeWindow) {
        mac.system.click(window)
        mac.settle()
    }

    private func cut(_ rect: CGRect, _ shares: [CGFloat], sideBySide: Bool) -> [CGRect] {
        // The gaps come off first; the tiles share what is left.
        let room = (sideBySide ? rect.width : rect.height) - gap * CGFloat(shares.count - 1)
        let whole = shares.reduce(0, +)
        var start = sideBySide ? rect.minX : rect.minY
        return shares.map { share in
            let length = room * share / whole
            defer { start += length + gap }
            return sideBySide
                ? CGRect(x: start, y: rect.minY, width: length, height: rect.height)
                : CGRect(x: rect.minX, y: start, width: rect.width, height: length)
        }
    }

    /// `rect` (the usable area when nil) cut into tiles side by side, one gap apart, each with
    /// its share of the room. `columns(1, 1)` is two halves.
    func columns(_ shares: CGFloat..., of rect: CGRect? = nil) -> [CGRect] {
        cut(rect ?? area, shares, sideBySide: true)
    }

    /// The same, top to bottom.
    func rows(_ shares: CGFloat..., of rect: CGRect? = nil) -> [CGRect] {
        cut(rect ?? area, shares, sideBySide: false)
    }
}

/// The commands that rearrange the tiles of a desktop.
final class LayoutCommandTests: LayoutCommandTestCase {
    // MARK: move

    func testMoveTradesPlacesWithTheWindowBesideAndStopsAtTheEdge() {
        let w = open(2)

        XCTAssertEqual(mac.run("move left"), "ok")
        XCTAssertFrame(w[1].rect, CGRect(x: 8, y: 33, width: 708, height: 859))
        XCTAssertFrame(w[0].rect, CGRect(x: 724, y: 33, width: 708, height: 859))
        XCTAssertEqual(mac.focused, w[1].id, "the focus goes with the window")

        // There is one display, so the edge of the layout is as far as it goes.
        XCTAssertEqual(mac.run("move left"), "ok: already at the edge")
        XCTAssertEqual(mac.tiledInReadingOrder, [w[1].id, w[0].id])
        XCTAssertFrame(w[1].rect, columns(1, 1)[0])
    }

    func testMoveInsideAColumnTradesPlacesAndSidewaysLeavesIt() {
        let w = open(3)
        let right = rows(1, 1, of: columns(1, 1)[1])
        XCTAssertFrame(w[1].rect, right[0])
        XCTAssertFrame(w[2].rect, right[1])

        XCTAssertEqual(mac.run("move up"), "ok")
        XCTAssertFrame(w[2].rect, right[0])
        XCTAssertFrame(w[1].rect, right[1])
        XCTAssertFrame(w[0].rect, columns(1, 1)[0], "the other column is as it was")
        XCTAssertEqual(mac.run("move down"), "ok")
        XCTAssertFrame(w[2].rect, right[1])

        // Sideways it leaves the column it shared and stands between the other two.
        XCTAssertEqual(mac.run("move left"), "ok")
        let thirds = columns(1, 1, 1)
        XCTAssertFrame(w[0].rect, thirds[0])
        XCTAssertFrame(w[2].rect, thirds[1])
        XCTAssertFrame(w[1].rect, thirds[2], "alone in its column, so it has the whole height")
        XCTAssertEqual(mac.focused, w[2].id)
    }

    func testMoveIntoTheColumnNextDoorJoinsItsWindows() {
        let w = open(3)
        click(w[0])

        XCTAssertEqual(mac.run("move right"), "ok")

        // Nothing is left beside the column, so its three windows have the whole width.
        let thirds = rows(1, 1, 1)
        XCTAssertFrame(w[1].rect, thirds[0])
        XCTAssertFrame(w[2].rect, thirds[1])
        XCTAssertFrame(w[0].rect, thirds[2], "the newcomer goes last")
    }

    func testMoveAcrossTheLayoutTakesAWholeSideOfTheDesktop() {
        let w = open(2)

        XCTAssertEqual(mac.run("move up"), "ok")

        XCTAssertFrame(w[1].rect, CGRect(x: 8, y: 33, width: 1424, height: 426), "across the top")
        XCTAssertFrame(w[0].rect, CGRect(x: 8, y: 467, width: 1424, height: 425), "the other below it")
    }

    // MARK: join

    func testJoinPutsAWindowUnderItsNeighbour() {
        let w = open(3)
        mac.run("arrange columns")
        click(w[0])

        XCTAssertEqual(mac.run("join right"), "ok")

        // The first two share the left half, the neighbour on top. The third keeps the rest.
        let halves = columns(1, 1)
        XCTAssertFrame(w[1].rect, rows(1, 1, of: halves[0])[0])
        XCTAssertFrame(w[0].rect, rows(1, 1, of: halves[0])[1])
        XCTAssertFrame(w[2].rect, halves[1])
        XCTAssertEqual(mac.focused, w[0].id)

        // Nothing is to the left of it or below it.
        XCTAssertEqual(mac.run("join left"), "ok: no neighbour in that direction")
        XCTAssertEqual(mac.run("join down"), "ok: no neighbour in that direction")
        XCTAssertFrame(w[0].rect, rows(1, 1, of: halves[0])[1])
    }

    // MARK: resize

    func testResizeGrowAndShrinkMoveTheSharedEdgeByAStep() {
        let w = open(2)

        // One step is 5% of the 1416 points the two share.
        XCTAssertEqual(mac.run("resize grow"), "ok")
        XCTAssertFrame(w[0].rect, columns(0.45, 0.55)[0])
        XCTAssertFrame(w[1].rect, columns(0.45, 0.55)[1])
        XCTAssertEqual(w[1].rect.width, 779, accuracy: 1)
        XCTAssertEqual(w[1].rect.maxX, area.maxX, accuracy: 1, "the outer edge stays put")

        XCTAssertEqual(mac.run("resize shrink"), "ok")
        XCTAssertFrame(w[1].rect, columns(1, 1)[1])
        XCTAssertEqual(mac.run("resize shrink width"), "ok")
        XCTAssertFrame(w[0].rect, columns(0.55, 0.45)[0])
        XCTAssertFrame(w[1].rect, columns(0.55, 0.45)[1])

        // Side by side there is a width to trade, and no height.
        XCTAssertEqual(mac.run("resize grow height"), "ok: nothing to resize against")
        XCTAssertFrame(w[1].rect, columns(0.55, 0.45)[1])
    }

    func testResizeWidthAndHeightEachMoveTheirOwnEdge() {
        let w = open(3)
        let halves = columns(1, 1)

        XCTAssertEqual(mac.run("resize grow height"), "ok")
        XCTAssertFrame(w[1].rect, rows(0.45, 0.55, of: halves[1])[0])
        XCTAssertFrame(w[2].rect, rows(0.45, 0.55, of: halves[1])[1])
        XCTAssertFrame(w[0].rect, halves[0], "the window beside the column is not part of this")

        // Its width is the width of its column, so the whole column grows.
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        let wider = columns(0.45, 0.55)
        XCTAssertFrame(w[0].rect, wider[0])
        XCTAssertFrame(w[1].rect, rows(0.45, 0.55, of: wider[1])[0])
        XCTAssertFrame(w[2].rect, rows(0.45, 0.55, of: wider[1])[1])

        // With no axis named it is the nearest edge that moves: the one inside the column.
        XCTAssertEqual(mac.run("resize shrink"), "ok")
        XCTAssertFrame(w[2].rect, rows(1, 1, of: wider[1])[1])
        XCTAssertFrame(w[0].rect, wider[0])
    }

    func testAResizeThatChangedNothingIsNotAStepToUndo() {
        let wide = open(1)[0]
        wide.minSize = CGSize(width: 900, height: 300)
        let other = open(1, of: "Notes")[0]
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1, "held at its minimum")

        XCTAssertEqual(mac.run("resize grow height"), "ok: nothing to resize against")
        XCTAssertEqual(other.rect.minX, wide.rect.maxX + gap, accuracy: 1)

        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1)
        XCTAssertEqual(mac.focused, other.id)

        // The weights are as they were, not as the screen has them: without its minimum the
        // wide window has its half again.
        wide.minSize = .zero
        XCTAssertEqual(mac.run("balance"), "ok")
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo", "they were equal all along")
        XCTAssertFrame(wide.rect, columns(1, 1)[0])
    }

    func testAResizeFromAMinimumSizeIsOneStepAndIsUndoneExactly() {
        let wide = open(1)[0]
        wide.minSize = CGSize(width: 900, height: 300)
        let other = open(1, of: "Notes")[0]
        let room = area.width - gap
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1, "held at its minimum")
        XCTAssertEqual(other.rect.width, room - 900, accuracy: 1)

        // The step starts from what is on screen: 5% of the room less than the other has now.
        XCTAssertEqual(mac.run("resize shrink width"), "ok")
        XCTAssertEqual(other.rect.width, room - 900 - 0.05 * room, accuracy: 1)
        XCTAssertEqual(wide.rect.width, 900 + 0.05 * room, accuracy: 1)

        // Matching the weights to the screen and changing them are one step, not two.
        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1)
        XCTAssertEqual(other.rect.width, room - 900, accuracy: 1)
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")

        XCTAssertEqual(mac.run("redo"), "ok: redone")
        XCTAssertEqual(wide.rect.width, 900 + 0.05 * room, accuracy: 1)
        XCTAssertEqual(mac.run("redo"), "ok: nothing to redo")

        // Taken back, the weights are the equal ones from before, so `balance` has nothing to
        // change. It asks the window about its minimum again: with none, there are two halves.
        XCTAssertEqual(mac.run("undo"), "ok: undone")
        wide.minSize = .zero
        XCTAssertEqual(mac.run("balance"), "ok")
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")
        XCTAssertFrame(wide.rect, columns(1, 1)[0])
        XCTAssertFrame(other.rect, columns(1, 1)[1])
    }

    // MARK: flip

    func testFlipTurnsTheContainerTheWindowIsIn() {
        let w = open(2)

        XCTAssertEqual(mac.run("flip"), "ok")
        XCTAssertFrame(w[0].rect, CGRect(x: 8, y: 33, width: 1424, height: 426))
        XCTAssertFrame(w[1].rect, CGRect(x: 8, y: 467, width: 1424, height: 425))
        XCTAssertEqual(mac.run("flip"), "ok")
        XCTAssertFrame(w[0].rect, columns(1, 1)[0])
        XCTAssertFrame(w[1].rect, columns(1, 1)[1])

        // A third window opens under the second. Their column is the container now, and it
        // becomes a row: side by side with the first window, which keeps half of the room.
        let third = open(1)[0]
        XCTAssertEqual(mac.run("flip"), "ok")
        let row = columns(2, 1, 1)
        XCTAssertFrame(w[0].rect, row[0])
        XCTAssertFrame(w[1].rect, row[1])
        XCTAssertFrame(third.rect, row[2])
    }

    // MARK: stack

    func testStackOverlapsTheWindowsAndLeavesAStripOfEach() {
        let w = open(2)

        XCTAssertEqual(mac.run("stack"), "ok: stacked")
        // Each has the whole width less one strip of 32 points. The second starts one strip in.
        XCTAssertFrame(w[0].rect, CGRect(x: 8, y: 33, width: 1392, height: 859))
        XCTAssertFrame(w[1].rect, CGRect(x: 40, y: 33, width: 1392, height: 859))
        XCTAssertEqual(mac.system.order.first?.id, w[1].id, "the focused window is in front")

        // A window that opens beside one in a stack joins it. A hint has nothing to say there.
        XCTAssertEqual(mac.run("split vertical"), "ok: new windows join the stack this window is in")
        let third = open(1)[0]
        XCTAssertFrame(w[0].rect, CGRect(x: 8, y: 33, width: 1360, height: 859))
        XCTAssertFrame(w[1].rect, CGRect(x: 40, y: 33, width: 1360, height: 859))
        XCTAssertFrame(third.rect, CGRect(x: 72, y: 33, width: 1360, height: 859))

        XCTAssertEqual(mac.run("stack"), "ok: unstacked")
        for (window, frame) in zip(w + [third], columns(1, 1, 1)) { XCTAssertFrame(window.rect, frame) }
    }

    func testStackOnlyStacksTheContainerTheWindowIsInWithTheStripOfTheConfig() {
        replaceScenario(Scenario(config: "[layout]\nstack-peek = 60\n"))
        let w = open(3)
        let halves = columns(1, 1)

        XCTAssertEqual(mac.run("stack"), "ok: stacked")

        // The column stacks top to bottom: the strip of the window behind shows above the other.
        XCTAssertFrame(w[1].rect, CGRect(x: halves[1].minX, y: 33, width: halves[1].width, height: 859 - 60))
        XCTAssertFrame(w[2].rect, CGRect(x: halves[1].minX, y: 33 + 60, width: halves[1].width, height: 859 - 60))
        XCTAssertFrame(w[0].rect, halves[0], "the window beside the stack keeps its tile")
    }

    func testAClickOnTheBackOfAStackPutsItsWindowsInOrder() {
        let w = open(3)
        mac.run("arrange columns")
        mac.run("stack")
        XCTAssertEqual(mac.system.order.map(\.id), [w[2].id, w[1].id, w[0].id])

        // The click brings the first window forward, over the third. The second is now behind
        // both, and its strip is covered.
        click(w[0])

        XCTAssertEqual(mac.system.order.map(\.id), w.map(\.id), "each window is above the one further from the front")
        XCTAssertEqual(mac.focused, w[0].id)
        XCTAssertEqual(w[2].raises, 0, "the one at the back is not touched")
    }

    func testAStackThatWillNotComeRightIsLeftAloneAfterThreeTries() {
        let w = open(3)
        mac.run("arrange columns")
        mac.run("stack")
        // The app of the second window is busy: it does not come forward when asked.
        w[1].answers = false
        click(w[0])

        // The window manager looks again, as it does whenever anything happens.
        for _ in 0..<5 {
            mac.wm.scheduleRefresh()
            mac.settle()
        }

        XCTAssertEqual(w[0].raises, 3, "raised behind the second window three times, then no more")
        XCTAssertEqual(mac.logged("did not put the stack around window \(w[0].id) in order").count, 1)

        // When the user does something, it tries again.
        w[1].answers = true
        mac.run("balance")
        XCTAssertEqual(mac.system.order.map(\.id), w.map(\.id))
    }

    func testAskingHowThingsAreIsNotTheUserDoingSomething() {
        let w = open(3)
        mac.run("arrange columns")
        mac.run("stack")
        w[1].answers = false
        click(w[0])
        func look() {
            mac.wm.scheduleRefresh()
            mac.settle()
        }
        for _ in 0..<5 { look() }
        XCTAssertEqual(w[0].raises, 3, "three tries, then the stack is left alone")

        // A status bar asks every second or so. That must not start the tries again, or a
        // stack that never comes right is raised for as long as the bar is running.
        for _ in 0..<3 {
            for report in ["list-windows", "list-windows --json", "list-spaces", "tree", "status"] {
                XCTAssertFalse(mac.run(report).hasPrefix("error"), report)
                look()
            }
        }
        XCTAssertEqual(mac.run("subscribe focus-changed"), "error: subscribe only works from the command line")
        look()
        XCTAssertEqual(w[0].raises, 3, "no report had the stack raised again")
        XCTAssertEqual(mac.logged("did not put the stack around window \(w[0].id) in order").count, 1)

        // A command that does something still starts them again. The first try is made at once.
        XCTAssertEqual(mac.run("split auto"), "ok: automatic")
        XCTAssertEqual(w[0].raises, 4)
        for _ in 0..<5 { look() }
        XCTAssertEqual(w[0].raises, 6, "and again no more than three")

        // So does one that is about Iguana and not about the windows: it is the user at the keyboard.
        XCTAssertEqual(mac.run("mode default"), "ok")
        look()
        XCTAssertEqual(w[0].raises, 7)
        XCTAssertEqual(mac.run("list-windows").hasPrefix("error"), false)
        for _ in 0..<5 { look() }
        XCTAssertEqual(w[0].raises, 9)
    }

    // MARK: balance

    func testBalanceGivesEveryWindowAnEqualShareAgain() {
        let w = open(3)
        let before = w.map(\.rect)
        mac.run("resize grow width")
        mac.run("resize grow width")
        mac.run("resize grow height")
        XCTAssertFrame(w[0].rect, columns(0.4, 0.6)[0])

        XCTAssertEqual(mac.run("balance"), "ok")

        for (window, frame) in zip(w, before) { XCTAssertFrame(window.rect, frame) }
    }

    func testBalanceAsksAWindowAgainWhetherItStillHasItsMinimum() {
        let wide = open(1)[0]
        wide.minSize = CGSize(width: 900, height: 300)
        let other = open(1, of: "Notes")[0]
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1)

        // While it will not shrink, balancing leaves it at its minimum.
        XCTAssertEqual(mac.run("balance"), "ok")
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1)
        XCTAssertEqual(other.rect.minX, wide.rect.maxX + gap, accuracy: 1)

        // The app now lets the window get smaller. The minimum Iguana once saw is out of date.
        wide.minSize = .zero
        XCTAssertEqual(mac.run("balance"), "ok")
        XCTAssertFrame(wide.rect, columns(1, 1)[0])
        XCTAssertFrame(other.rect, columns(1, 1)[1])
    }

    // MARK: arrange

    func testArrangeColumnsAndRowsLineUpEveryWindowAndUndoAStackAndAZoom() {
        let w = open(3)
        mac.run("stack")
        mac.run("zoom")
        XCTAssertFrame(w[2].rect, area)

        XCTAssertEqual(mac.run("arrange columns"), "ok")
        // 1424 less two gaps is 1408: a third each, to the nearest point.
        XCTAssertFrame(w[0].rect, CGRect(x: 8, y: 33, width: 469, height: 859))
        XCTAssertFrame(w[1].rect, CGRect(x: 485, y: 33, width: 470, height: 859))
        XCTAssertFrame(w[2].rect, CGRect(x: 963, y: 33, width: 469, height: 859))
        XCTAssertEqual(mac.tiles.count, 3, "no window is zoomed any more")

        XCTAssertEqual(mac.run("arrange rows"), "ok")
        for (window, frame) in zip(w, rows(1, 1, 1)) { XCTAssertFrame(window.rect, frame) }
        XCTAssertEqual(mac.focused, w[2].id)
    }

    func testArrangeGridMakesRowsOfTwoAndGivesAnOddWindowTheWholeLastRow() {
        let w = open(4)
        let top = columns(1, 1, of: rows(1, 1)[0]), bottom = columns(1, 1, of: rows(1, 1)[1])

        // In the order a page is read: the first window, the one beside it, then the two below.
        XCTAssertEqual(mac.run("arrange grid"), "ok")
        XCTAssertFrame(w[0].rect, top[0])
        XCTAssertFrame(w[1].rect, top[1])
        XCTAssertFrame(w[2].rect, bottom[0])
        XCTAssertFrame(w[3].rect, bottom[1])

        // Three windows side by side make a row of two and a row of one.
        mac.system.close(w[3])
        mac.settle()
        mac.run("arrange columns")
        XCTAssertEqual(mac.run("arrange grid"), "ok")
        XCTAssertFrame(w[0].rect, top[0])
        XCTAssertFrame(w[1].rect, top[1])
        XCTAssertFrame(w[2].rect, rows(1, 1)[1])
    }

    func testArrangeMainGivesTheFocusedWindowSixtyPerCentOnTheLeft() {
        let w = open(3)

        XCTAssertEqual(mac.run("arrange main"), "ok")

        let parts = columns(0.6, 0.4)
        XCTAssertFrame(w[2].rect, parts[0])
        XCTAssertEqual(w[2].rect.width, 0.6 * 1416, accuracy: 1)
        XCTAssertFrame(w[0].rect, rows(1, 1, of: parts[1])[0], "the others top to bottom on the right")
        XCTAssertFrame(w[1].rect, rows(1, 1, of: parts[1])[1])
        XCTAssertEqual(mac.focused, w[2].id)
    }

    func testArrangeKeepsAPlaceForAWindowThatIsNotOnScreen() {
        let w = open(3)
        mac.system.minimise(w[1])
        mac.settle()

        XCTAssertEqual(mac.run("arrange rows"), "ok")
        XCTAssertFrame(w[0].rect, rows(1, 1)[0])
        XCTAssertFrame(w[2].rect, rows(1, 1)[1])

        // It comes back after the last window, in the same arrangement.
        mac.system.unminimise(w[1])
        mac.settle()
        let thirds = rows(1, 1, 1)
        XCTAssertFrame(w[0].rect, thirds[0])
        XCTAssertFrame(w[2].rect, thirds[1])
        XCTAssertFrame(w[1].rect, thirds[2])
    }

    // MARK: Nothing to do

    func testAWindowThatIsAloneHasNothingToBeArrangedWith() {
        let only = open(1)[0]
        let expected: [(command: String, reply: String)] = [
            ("move left", "ok: already at the edge"), ("move right", "ok: already at the edge"),
            ("move up", "ok: already at the edge"), ("move down", "ok: already at the edge"),
            ("join left", "ok: no neighbour in that direction"),
            ("resize grow", "ok: nothing to resize against"), ("resize shrink width", "ok: nothing to resize against"),
            ("stack", "ok: no other window to stack with"),
            ("arrange columns", "ok: nothing to arrange"), ("arrange rows", "ok: nothing to arrange"),
            ("arrange grid", "ok: nothing to arrange"),
            // One window can be the main one, and balanced, and flipped. It shows nothing.
            ("arrange main", "ok"), ("balance", "ok"), ("flip", "ok"),
        ]

        for (command, reply) in expected {
            XCTAssertEqual(mac.run(command), reply, command)
            XCTAssertFrame(only.rect, area, command)
        }
    }
}
