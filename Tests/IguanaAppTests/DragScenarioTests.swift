import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// The user's hand on a tiled window: dragging an edge to resize it, and carrying it by its
/// title bar to drop it somewhere else.
final class DragScenarioTests: ScenarioTestCase {
    private let left = CGRect(x: 8, y: 33, width: 708, height: 859)
    private let right = CGRect(x: 724, y: 33, width: 708, height: 859)

    // MARK: Resizing by hand

    func testDraggingAnEdgeSidewaysAndLettingGoKeepsTheNewWidths() {
        let (a, b) = mac.openTwo()

        mac.system.resize(a, to: CGRect(x: 8, y: 33, width: 908, height: 859))
        mac.settle()
        mac.drop()

        XCTAssertFrame(a.rect, CGRect(x: 8, y: 33, width: 908, height: 859), "as wide as the user made it")
        XCTAssertFrame(b.rect, CGRect(x: 924, y: 33, width: 508, height: 859), "the neighbour takes the rest")
    }

    func testDraggingACornerChangesTheWidthAndTheHeightAtOnce() {
        let (a, b, c) = mac.openThree()

        // The bottom-left corner of the window at the top right, pulled out and down.
        mac.system.resize(b, to: CGRect(x: 524, y: 33, width: 908, height: 626))
        mac.settle()
        mac.drop()

        XCTAssertEqual(b.rect.width, 908, accuracy: 2)
        XCTAssertEqual(b.rect.height, 626, accuracy: 2)
        XCTAssertEqual(a.rect.width, 508, accuracy: 2, "the column on the left gave up the width")
        XCTAssertEqual(c.rect.width, b.rect.width, accuracy: 1, "the window below is in the same column")
        XCTAssertEqual(c.rect.minY, b.rect.maxY + 8, accuracy: 1)
    }

    func testNothingIsMovedWhileTheButtonIsDown() {
        let (a, b) = mac.openTwo()
        var told: [Bool] = []
        mac.wm.onDrag = { told.append($0) }
        mac.mover.clearRecord()

        let held = CGRect(x: 8, y: 33, width: 908, height: 859)
        mac.system.resize(a, to: held)
        mac.settle()
        // The edge is dragged a little further before it is let go.
        let further = CGRect(x: 8, y: 33, width: 1008, height: 859)
        mac.system.resize(a, to: further)
        mac.scheduler.advance(by: 5)

        XCTAssertEqual(a.rect, further, "the window is the user's while they hold it")
        XCTAssertFrame(b.rect, right, "the neighbour waits")
        XCTAssertTrue(mac.mover.moves.isEmpty)
        XCTAssertEqual(told, [true], "the drag is announced once, when it begins")
        XCTAssertEqual(mac.wm.dragging?.id, a.id)
        XCTAssertEqual(mac.wm.dragging?.start, left, "it started from its tile")

        mac.drop()
        XCTAssertEqual(told, [true, false])
        XCTAssertNil(mac.wm.dragging)
        XCTAssertEqual(b.rect.minX, a.rect.maxX + 8, accuracy: 1, "now the neighbour makes room")
    }

    func testAWindowHeldAtItsMinimumSizeIsDraggedFromItsRealSize() {
        // A window that is taller than the desktop: its tile is 859 points high, the window 1000.
        let tall = mac.system.open(mac.system.launch("Simulator"))
        tall.minSize = CGSize(width: 0, height: 1000)
        mac.settle()
        let other = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        XCTAssertEqual(tall.rect.size, CGSize(width: 708, height: 1000))
        XCTAssertFrame(mac.tiles[tall.id], left)

        // Carried by its title bar to the middle of the other tile.
        mac.carry(tall, pointerAt: CGPoint(x: right.midX, y: right.midY))
        XCTAssertEqual(mac.wm.dragging?.start.size, tall.rect.size, "the drag starts from the size the window has, not from the tile")

        mac.drop()
        // The 141 points between the tile and the window were not taken for a resize: this
        // was a move, and the two traded places.
        XCTAssertEqual(mac.tiledInReadingOrder, [other.id, tall.id])
        XCTAssertEqual(tall.rect.minX, right.minX, accuracy: 1)
        XCTAssertFrame(other.rect, left)
    }

    func testAWindowThatTookALittleLessThanItsTileCanStillBeCarried() {
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        let other = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        // A terminal is as big as a whole number of rows and columns of text. Asked to fill its
        // tile, it came out a few points smaller.
        terminal.rect.size = CGSize(width: 700, height: 850)

        mac.carry(terminal, pointerAt: CGPoint(x: right.midX, y: right.midY))
        mac.drop()

        XCTExpectFailure("a window smaller than its tile by more than 3 points is taken for one being resized: it cannot be dropped, and letting go changes the proportions") {
            XCTAssertEqual(mac.tiledInReadingOrder, [other.id, terminal.id], "carried to the middle of the other tile, the two trade places")
            XCTAssertEqual(mac.tiles[other.id]?.width ?? 0, 708, accuracy: 1, "and the halves stay halves")
        }
    }

    // MARK: Carrying a tile and dropping it

    func testDroppingATileOnTheMiddleOfAnotherSwapsThem() {
        let (a, b) = mac.openTwo()

        mac.carry(a, pointerAt: CGPoint(x: right.midX, y: right.midY))
        XCTAssertFrame(b.rect, right, "nothing happens until the window is let go")
        mac.drop()

        XCTAssertFrame(a.rect, right)
        XCTAssertFrame(b.rect, left)
        XCTAssertEqual(mac.tiledInReadingOrder, [b.id, a.id])
    }

    func testDroppingATileOnAnEdgeOfAnotherTakesThatHalf() {
        let (a, b) = mac.openTwo()

        // Near the top edge of the tile on the right.
        mac.carry(a, pointerAt: CGPoint(x: right.midX, y: right.minY + 30))
        mac.drop()

        XCTAssertFrame(a.rect, CGRect(x: 8, y: 33, width: 1424, height: 426), "the top half of what the other had: the whole desktop")
        XCTAssertFrame(b.rect, CGRect(x: 8, y: 467, width: 1424, height: 425), "the other keeps the bottom half")
    }

    func testDroppingATileOntoAStackJoinsTheStack() {
        let (a, b, c) = mac.openThree()
        XCTAssertEqual(mac.run("stack"), "ok: stacked")
        // The two on the right are a stack now: one behind the other, a strip of each showing.
        XCTAssertFrame(b.rect, CGRect(x: 724, y: 33, width: 708, height: 827))
        XCTAssertFrame(c.rect, CGRect(x: 724, y: 65, width: 708, height: 827))

        mac.carry(a, pointerAt: CGPoint(x: right.midX, y: right.midY))
        mac.drop()

        // All three are one stack, and it has the desktop to itself.
        XCTAssertFrame(b.rect, CGRect(x: 8, y: 33, width: 1424, height: 795))
        XCTAssertFrame(c.rect, CGRect(x: 8, y: 65, width: 1424, height: 795))
        XCTAssertFrame(a.rect, CGRect(x: 8, y: 97, width: 1424, height: 795), "the last of the stack, after the window it was dropped on")
    }

    func testATileDroppedWhereNothingIsPlannedGoesBackToItsTile() {
        let (a, b) = mac.openTwo()
        mac.mover.clearRecord()

        // Moved a little: the pointer is still over the window's own tile.
        mac.carry(a, pointerAt: CGPoint(x: left.midX + 60, y: left.minY + 70))
        XCTAssertNotEqual(a.rect, left)
        mac.drop()

        XCTAssertFrame(a.rect, left)
        XCTAssertFrame(b.rect, right)
        XCTAssertEqual(mac.mover.moves.map(\.window), [a.id], "only the window that was let go is moved")
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo", "nothing changed, so nothing was recorded")
    }

    func testDroppingOnAFloatingWindowDoesNothing() {
        let (a, b) = mac.openTwo()
        // A floating window lies over the tile on the right.
        let palette = mac.system.open(mac.system.launch("Palette"), frame: CGRect(x: 800, y: 200, width: 500, height: 400))
        mac.settle()
        XCTAssertEqual(mac.run("float"), "ok: floating")
        palette.setPosition(CGPoint(x: 800, y: 200))
        palette.setSize(CGSize(width: 500, height: 400))
        mac.settle()
        XCTAssertFrame(a.rect, left)

        mac.carry(a, pointerAt: CGPoint(x: 1050, y: 400))
        mac.drop()

        XCTAssertFrame(a.rect, left, "the pointer was on the floating window, not on the tile under it")
        XCTAssertFrame(b.rect, right)
    }

    func testACarriedWindowThatComesBackAtAnotherSizeDoesNotChangeTheProportions() {
        let (a, b) = mac.openTwo()

        // Carried to the top of the screen, where macOS's own tiling makes it fill the screen
        // while the button is still down.
        mac.carry(a, pointerAt: CGPoint(x: 700, y: 10))
        mac.system.resize(a, to: CGRect(x: 0, y: 25, width: 1440, height: 875))
        mac.settle()
        mac.drop()

        XCTAssertFrame(a.rect, left, "back on its tile at the size it had")
        XCTAssertFrame(b.rect, right)
    }

    func testAWindowThatClosesWhileItIsHeldEndsTheDrag() {
        let (a, b) = mac.openTwo()
        var told: [Bool] = []
        mac.wm.onDrag = { told.append($0) }

        mac.carry(a, pointerAt: CGPoint(x: right.midX, y: right.midY))
        mac.system.close(a)
        mac.settle()
        mac.drop()

        XCTAssertEqual(told, [true, false])
        XCTAssertNil(mac.wm.dragging)
        XCTAssertFrame(b.rect, mac.usable(), "the window that is left has the desktop")
    }

    // MARK: Two displays

    func testDroppedOnTheEdgeOfATileOnAnotherDisplayItLandsInThatLayout() {
        let (a, b) = mac.openTwo()
        let external = mac.system.addDisplay("External", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let c = mac.system.open(mac.system.launch("Music"), frame: CGRect(x: 1700, y: 200, width: 640, height: 480))
        mac.settle()
        XCTAssertFrame(c.rect, mac.usable(external))

        // Most of the window is still on the built-in display. The pointer is over the left
        // edge of the tile on the other one.
        mac.system.drag(a, to: CGPoint(x: 900, y: 390))
        mac.system.pointerLocation = CGPoint(x: 1500, y: 400)
        mac.settle()
        // Letting go, Iguana puts the window on the other display, and macOS has it on the
        // desktop shown there from then on.
        mac.system.releaseMouse()
        mac.settle()

        let there = mac.usable(external)
        XCTAssertFrame(a.rect, CGRect(x: there.minX, y: there.minY, width: 948, height: there.height), "the left half of the other display")
        XCTAssertFrame(c.rect, CGRect(x: there.minX + 956, y: there.minY, width: 948, height: there.height))
        XCTAssertFrame(b.rect, mac.usable(), "the window left behind has its display to itself")
    }

    func testDroppedOnADisplayWithNoTilesItJoinsThatDisplay() {
        let (a, b) = mac.openTwo()
        let external = mac.system.addDisplay("External", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        mac.settle()

        mac.carry(a, pointerAt: CGPoint(x: 2400, y: 500))
        mac.drop()

        XCTAssertFrame(a.rect, mac.usable(external), "it is the first window of that display's layout")
        XCTAssertFrame(b.rect, mac.usable())
    }

    // MARK: What letting go would do

    func testTheDropPlanSaysWhatLettingGoWouldDo() {
        let (a, b) = mac.openTwo()
        let middle = CGPoint(x: right.midX, y: right.midY)

        let carried = mac.wm.dropPlan(dragging: a.id, from: left, now: left.offsetBy(dx: 400, dy: 80), at: middle)
        XCTAssertEqual(carried, DropPlan(drop: .trade(b.id), rect: right))

        // The same pointer, but it is the window's edge that is being dragged.
        let resized = mac.wm.dropPlan(dragging: a.id, from: left, now: CGRect(x: 8, y: 33, width: 1070, height: 859), at: middle)
        XCTAssertNil(resized, "a resize is not a drop")
    }

    func testNoDropIsPlannedWhilePaused() {
        let (a, _) = mac.openTwo()
        XCTAssertEqual(mac.run("pause"), "ok: paused")
        var told: [Bool] = []
        mac.wm.onDrag = { told.append($0) }

        mac.carry(a, pointerAt: CGPoint(x: right.midX, y: right.midY))
        XCTAssertNil(mac.wm.dropPlan(dragging: a.id, from: left, now: a.rect, at: CGPoint(x: right.midX, y: right.midY)))
        XCTAssertNil(mac.wm.dragging, "a window moved while tiling is paused is not a drag of a tile")
        let put = a.rect
        mac.drop()

        XCTAssertEqual(a.rect, put, "it stays where the user put it")
        XCTAssertTrue(told.isEmpty)
    }

    func testNoDropIsPlannedForAWindowThatHasNoTile() {
        let (a, b, c) = mac.openThree()
        XCTAssertEqual(mac.run("float --window \(a.id)"), "ok: floating")
        XCTAssertEqual(mac.run("zoom --window \(b.id)"), "ok")
        XCTAssertFrame(b.rect, mac.usable(), "zoomed, it fills the desktop")
        XCTAssertEqual(mac.tiles.keys.sorted(), [c.id], "neither the floating window nor the zoomed one is on a tile")
        let overTheTile = CGPoint(x: mac.tiles[c.id]!.midX, y: mac.tiles[c.id]!.midY)

        // The zoomed window, as if it were carried over the tile that is left.
        XCTAssertNil(mac.wm.dropPlan(dragging: b.id, from: b.rect, now: b.rect.offsetBy(dx: 300, dy: 200), at: overTheTile))

        // The floating window is carried there by hand.
        let from = a.rect
        mac.carry(a, pointerAt: overTheTile)
        XCTAssertNil(mac.wm.dropPlan(dragging: a.id, from: from, now: a.rect, at: overTheTile))
        XCTAssertNil(mac.wm.dragging, "moving a floating window is not a drag of a tile")
        let put = a.rect
        mac.drop()
        XCTAssertEqual(a.rect, put, "it stays where it is put")
        XCTAssertEqual(mac.tiles.keys.sorted(), [c.id])
    }

    // MARK: Undo

    func testADropIsRecordedForUndo() {
        let (a, b) = mac.openTwo()
        mac.carry(a, pointerAt: CGPoint(x: right.midX, y: right.midY))
        mac.drop()
        XCTAssertEqual(mac.tiledInReadingOrder, [b.id, a.id])

        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertFrame(a.rect, left)
        XCTAssertFrame(b.rect, right)
        XCTAssertEqual(mac.run("redo"), "ok: redone")
        XCTAssertEqual(mac.tiledInReadingOrder, [b.id, a.id])
    }

    func testAResizeByHandIsRecordedForUndo() {
        let (a, b) = mac.openTwo()
        mac.system.resize(a, to: CGRect(x: 8, y: 33, width: 908, height: 859))
        mac.settle()
        mac.drop()
        XCTAssertEqual(a.rect.width, 908, accuracy: 1)

        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertFrame(a.rect, left)
        XCTAssertFrame(b.rect, right)
    }

    // MARK: Whose frame change it is

    func testFramesTheManagerAskedForAreNotTakenForTheUsers() {
        var told: [Bool] = []
        mac.wm.onDrag = { told.append($0) }
        let (a, b, c) = mac.openThree()
        let asked = mac.mover.moves.count

        // Every window said it moved and changed size. None of that started anything.
        mac.scheduler.advance(by: 10)
        XCTAssertEqual(mac.scheduler.pending, 0)
        XCTAssertEqual(mac.mover.moves.count, asked, "no move answers a move")
        XCTAssertTrue(told.isEmpty)
        for window in [a, b, c] { XCTAssertFrame(window.rect, mac.tiles[window.id] ?? .zero, "each window is on its tile") }

        // Looking again finds every window in place and asks for nothing.
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertEqual(mac.mover.moves.count, asked)
    }

    func testAWindowTheManagerMovesWhileTheButtonIsDownIsNotTakenForADrag() {
        let (a, b) = mac.openTwo()
        // The user is holding the mouse down on something else: a slider, a text selection.
        mac.system.leftMouseIsDown = true

        let c = mac.system.open(mac.system.launch("Music"))
        mac.settle()

        XCTAssertNil(mac.wm.dragging, "the windows that made room were moved by Iguana, not by the user")
        XCTAssertEqual(mac.tiles.count, 3)
        for window in [a, b, c] { XCTAssertFrame(window.rect, mac.tiles[window.id] ?? .zero) }
    }

    func testAWindowThatMovesWithTheButtonUpIsPutBack() {
        let (a, b) = mac.openTwo()
        mac.mover.clearRecord()

        // The app moves and resizes its own window. Nobody is holding it.
        a.setPosition(CGPoint(x: 120, y: 140))
        a.setSize(CGSize(width: 500, height: 400))
        mac.settle()

        XCTAssertFrame(a.rect, left)
        XCTAssertFrame(b.rect, right)
        XCTAssertNil(mac.wm.dragging)
        XCTAssertEqual(mac.mover.moves.map(\.window), [a.id])
        XCTAssertEqual(mac.mover.moves.first?.duration, 0.16, "it glides back")
    }
}

private extension Scenario {
    /// Two windows of two apps, side by side: the first on the left.
    func openTwo() -> (FakeWindow, FakeWindow) {
        let a = system.open(system.launch("Safari"), title: "One")
        settle()
        let b = system.open(system.launch("Notes"), title: "Two")
        settle()
        return (a, b)
    }

    /// Three windows: the first on the left, the second above the third on the right.
    func openThree() -> (FakeWindow, FakeWindow, FakeWindow) {
        let (a, b) = openTwo()
        let c = system.open(system.launch("Terminal"), title: "Three")
        settle()
        return (a, b, c)
    }

    /// The user takes a window by the middle of its title bar and carries it until the pointer
    /// is at `point`. The button stays down.
    func carry(_ window: FakeWindow, pointerAt point: CGPoint) {
        system.drag(window, to: CGPoint(x: point.x - window.rect.width / 2, y: point.y - 10))
        settle()
    }

    /// The user lets go of the mouse button.
    func drop() {
        system.releaseMouse()
        settle()
    }
}
