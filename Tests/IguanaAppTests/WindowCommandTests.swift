import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// The commands that say where a window goes, or take one out of the layout: `split`, `zoom`,
/// `float` and `close`. Then `undo` and `redo`, and how windows travel to their places.
final class WindowCommandTests: LayoutCommandTestCase {
    // MARK: split and auto-split

    func testSplitVerticalPutsTheNextWindowBelowAndIsUsedOnce() {
        let first = open(1)[0]

        // A window this wide would get the next one beside it.
        XCTAssertEqual(mac.run("split vertical"), "ok: the next window opens below it")
        let second = open(1)[0]
        XCTAssertFrame(first.rect, rows(1, 1)[0])
        XCTAssertFrame(second.rect, rows(1, 1)[1])

        // The hint is spent. The third goes where auto-split puts it: beside the wide second one.
        let third = open(1)[0]
        XCTAssertFrame(first.rect, rows(1, 1)[0])
        XCTAssertFrame(second.rect, columns(1, 1, of: rows(1, 1)[1])[0])
        XCTAssertFrame(third.rect, columns(1, 1, of: rows(1, 1)[1])[1])
    }

    func testSplitHorizontalPutsTheNextWindowBesideUnlessAutoTakesItBack() {
        let w = open(2)

        // The focused window is taller than wide: left alone, the next one would open below it.
        XCTAssertEqual(mac.run("split horizontal"), "ok: the next window opens beside it")
        let third = open(1)[0]
        let thirds = columns(1, 1, 1)
        XCTAssertFrame(w[0].rect, thirds[0])
        XCTAssertFrame(w[1].rect, thirds[1])
        XCTAssertFrame(third.rect, thirds[2])

        // The same hint again, and then taken back.
        mac.run("split horizontal")
        XCTAssertEqual(mac.run("split auto"), "ok: automatic")
        let fourth = open(1)[0]
        XCTAssertFrame(third.rect, rows(1, 1, of: thirds[2])[0])
        XCTAssertFrame(fourth.rect, rows(1, 1, of: thirds[2])[1], "below, as auto-split has it")
    }

    func testAHintWaitsForAWindowThatOpensBesideItsOwnWindow() {
        let w = open(2)
        XCTAssertEqual(mac.run("split horizontal --window \(w[0].id)"), "ok: the next window opens beside it")

        // This one opens beside the focused window, which has no hint.
        let third = open(1)[0]
        XCTAssertFrame(third.rect, rows(1, 1, of: columns(1, 1)[1])[1])

        // The next opens beside the first window, and now the hint is used.
        click(w[0])
        let fourth = open(1)[0]
        let thirds = columns(1, 1, 1)
        XCTAssertFrame(w[0].rect, thirds[0])
        XCTAssertFrame(fourth.rect, thirds[1])
        XCTAssertFrame(w[1].rect, rows(1, 1, of: thirds[2])[0])
        XCTAssertFrame(third.rect, rows(1, 1, of: thirds[2])[1])
    }

    func testWithAutoSplitOffNewWindowsLineUpBesideEachOther() {
        let w = open(2)

        // The setting is read as soon as the file is saved.
        XCTAssertEqual(mac.writeConfig("[layout]\nauto-split = false\n"), "ok: loaded \(mac.configURL.path)")
        let third = open(1)[0]
        let thirds = columns(1, 1, 1)
        XCTAssertFrame(w[0].rect, thirds[0])
        XCTAssertFrame(w[1].rect, thirds[1], "no longer split along its longer side")
        XCTAssertFrame(third.rect, thirds[2])

        // A hint still says where one window goes.
        XCTAssertEqual(mac.run("split vertical"), "ok: the next window opens below it")
        let fourth = open(1)[0]
        XCTAssertFrame(third.rect, rows(1, 1, of: thirds[2])[0])
        XCTAssertFrame(fourth.rect, rows(1, 1, of: thirds[2])[1])
        XCTAssertFrame(w[0].rect, thirds[0])
    }

    // MARK: zoom

    func testZoomFillsTheDesktopAndTheOthersKeepTheirTiles() {
        let w = open(2)

        XCTAssertEqual(mac.run("zoom"), "ok")
        XCTAssertFrame(w[1].rect, area)
        XCTAssertFrame(w[0].rect, columns(1, 1)[0])
        XCTAssertEqual(mac.tiles.keys.sorted(), [w[0].id], "the zoomed window is not on its tile")
        XCTAssertEqual(mac.system.order.first?.id, w[1].id, "and it is in front")

        XCTAssertEqual(mac.run("zoom"), "ok")
        XCTAssertFrame(w[1].rect, columns(1, 1)[1])
        XCTAssertEqual(mac.tiles.count, 2)
    }

    func testAZoomedWindowKeepsItsPlaceInTheLayoutUntilAnotherIsZoomed() {
        let w = open(2)
        mac.run("zoom")

        // The layout changes underneath. The zoomed window still fills the desktop.
        XCTAssertEqual(mac.run("move left"), "ok")
        XCTAssertFrame(w[1].rect, area)
        XCTAssertFrame(w[0].rect, columns(1, 1)[1])

        // One window is zoomed at a time: the first goes to the tile it was moved to.
        click(w[0])
        XCTAssertEqual(mac.run("zoom"), "ok")
        XCTAssertFrame(w[0].rect, area)
        XCTAssertFrame(w[1].rect, columns(1, 1)[0])
        XCTAssertEqual(mac.system.order.first?.id, w[0].id)
    }

    // MARK: float

    func testFloatTakesAWindowOutOfTheLayoutAndPutsItBack() {
        let w = open(2)
        let was = w[1].rect

        XCTAssertEqual(mac.run("float"), "ok: floating")
        XCTAssertFrame(w[0].rect, area, "the other window takes the room")
        XCTAssertEqual(w[1].rect, was, "it stays where it was")
        XCTAssertEqual(mac.tiles.keys.sorted(), [w[0].id])

        // A floating window is the user's to put anywhere.
        mac.system.drag(w[1], to: CGPoint(x: 300, y: 200))
        mac.system.releaseMouse()
        mac.settle()
        XCTAssertEqual(w[1].rect.origin, CGPoint(x: 300, y: 200))

        XCTAssertEqual(mac.run("float"), "ok: tiled")
        XCTAssertFrame(w[0].rect, columns(1, 1)[0])
        XCTAssertFrame(w[1].rect, columns(1, 1)[1])
        XCTAssertEqual(mac.focused, w[1].id)
    }

    func testFloatRefusesAWindowThatCannotBeTiled() {
        let app = mac.system.launch("Finder")
        let dialog = mac.system.open(app, frame: CGRect(x: 400, y: 300, width: 400, height: 200))
        dialog.subrole = kAXDialogSubrole
        mac.settle()

        XCTAssertEqual(mac.run("float"), "error: this window cannot be tiled")
        XCTAssertEqual(mac.run("zoom"), "error: the focused window is not tiled")
        XCTAssertEqual(dialog.rect, CGRect(x: 400, y: 300, width: 400, height: 200))
    }

    // MARK: close

    func testClosePressesTheCloseButtonOfTheFocusedWindow() {
        let w = open(2)

        // A window without the button cannot be closed this way, and the command says so.
        w[1].hasCloseButton = false
        XCTAssertEqual(mac.run("close"), "error: this window has no close button")
        XCTAssertNotNil(mac.system.window(w[1].id))
        XCTAssertEqual(mac.tiles.count, 2)

        w[1].hasCloseButton = true
        XCTAssertEqual(mac.run("close"), "ok")
        XCTAssertNil(mac.system.window(w[1].id), "the window is gone")
        XCTAssertFrame(w[0].rect, area)
        XCTAssertEqual(mac.focused, w[0].id)
    }

    // MARK: undo and redo

    func testUndoTakesChangesBackOneAtATimeAndRedoMakesThemAgain() {
        let w = open(2)
        let (a, b) = (w[0], w[1])
        mac.run("flip")
        mac.run("resize grow")
        XCTAssertFrame(b.rect, rows(0.45, 0.55)[1])

        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertFrame(a.rect, rows(1, 1)[0], "the sizes are taken back")
        XCTAssertFrame(b.rect, rows(1, 1)[1])
        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertFrame(a.rect, columns(1, 1)[0], "then the flip")
        XCTAssertFrame(b.rect, columns(1, 1)[1])
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")

        XCTAssertEqual(mac.run("redo"), "ok: redone")
        XCTAssertFrame(b.rect, rows(1, 1)[1])
        XCTAssertEqual(mac.run("redo"), "ok: redone")
        XCTAssertFrame(a.rect, rows(0.45, 0.55)[0])
        XCTAssertFrame(b.rect, rows(0.45, 0.55)[1])
        XCTAssertEqual(mac.run("redo"), "ok: nothing to redo")

        // A new change after an undo leaves nothing to make again.
        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertEqual(mac.run("move up"), "ok")
        XCTAssertEqual(mac.run("redo"), "ok: nothing to redo")
        XCTAssertFrame(b.rect, rows(1, 1)[0])
        XCTAssertFrame(a.rect, rows(1, 1)[1])
        XCTAssertEqual(mac.focused, b.id, "the focus was never moved")
    }

    func testOnlyAChangeToTheLayoutIsAStepToUndo() {
        let w = open(2)
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")
        XCTAssertEqual(mac.run("redo"), "ok: nothing to redo")

        mac.run("move right")       // already at the edge
        mac.run("balance")          // already balanced
        mac.run("join up")          // no neighbour
        mac.run("split vertical")   // a hint for later
        mac.run("zoom")             // the tiles stay as they are

        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")
        XCTAssertFrame(w[1].rect, area, "still zoomed")
    }

    func testUndoLeavesOutAWindowThatHasClosedSince() {
        let w = open(3)
        mac.run("move left")
        XCTAssertEqual(mac.tiledInReadingOrder, [w[0].id, w[2].id, w[1].id])
        mac.system.close(w[0])
        mac.settle()

        XCTAssertEqual(mac.run("undo"), "ok: undone")

        // The second over the third, as before the move. The first is not brought back.
        XCTAssertEqual(mac.tiles.keys.sorted(), [w[1].id, w[2].id])
        XCTAssertFrame(w[1].rect, rows(1, 1)[0])
        XCTAssertFrame(w[2].rect, rows(1, 1)[1])
    }

    func testUndoPassesOverAStepThatWouldChangeNothing() {
        let w = open(3)
        mac.run("move left")
        mac.system.close(w[2])
        mac.settle()
        let before = [w[0].rect, w[1].rect]
        XCTAssertFrame(w[1].rect, columns(1, 1)[1])

        // Taking the move back could only put the closed window back, and that one stays gone.
        XCTExpectFailure("undo answers 'undone' for a step that, with the closed window left out, is the layout on screen already") {
            XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")
        }
        XCTAssertEqual([w[0].rect, w[1].rect], before)
    }

    func testUndoKeepsAWindowThatHasOpenedSince() {
        let w = open(2)
        mac.run("flip")
        let third = open(1)[0]
        XCTAssertFrame(third.rect, columns(1, 1, of: rows(1, 1)[1])[1])

        // The two are side by side again. The third is placed as a window that has just opened.
        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertFrame(w[0].rect, columns(1, 1)[0])
        XCTAssertFrame(w[1].rect, rows(1, 1, of: columns(1, 1)[1])[0])
        XCTAssertFrame(third.rect, rows(1, 1, of: columns(1, 1)[1])[1])

        // Redo brings back the layout as it was a moment ago, the third window included.
        XCTAssertEqual(mac.run("redo"), "ok: redone")
        XCTAssertFrame(w[0].rect, rows(1, 1)[0])
        XCTAssertFrame(w[1].rect, columns(1, 1, of: rows(1, 1)[1])[0])
        XCTAssertFrame(third.rect, columns(1, 1, of: rows(1, 1)[1])[1])
    }

    func testEveryDesktopHasItsOwnChangesToUndo() {
        let display = mac.system.displayList[0]
        mac.system.addDesktop(to: display)
        let w = open(2)
        mac.run("flip")

        // On the second desktop nothing has been changed.
        mac.system.showDesktop(2)
        mac.settle()
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo")

        mac.system.showDesktop(1)
        mac.settle()
        XCTAssertFrame(w[0].rect, rows(1, 1)[0], "the first desktop is as it was left")
        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertFrame(w[0].rect, columns(1, 1)[0])
        XCTAssertFrame(w[1].rect, columns(1, 1)[1])
    }

    // MARK: How windows get to their places

    func testWindowsGlideToANewPlaceUnlessTheyAreNewOrBarelyMove() {
        let w = open(2)
        func durations(_ window: FakeWindow) -> [Double] { mac.mover.moves.filter { $0.window == window.id }.map(\.duration) }

        mac.mover.clearRecord()
        let third = open(1)[0]
        XCTAssertEqual(durations(w[1]), [0.16], "the window that makes room glides")
        XCTAssertEqual(durations(third), [0], "the new one is placed at once")
        XCTAssertEqual(durations(w[0]), [], "a window that is where it belongs is not asked to move")

        // Half a per cent of the 851 points the two share is 4 points: too little for a glide.
        mac.writeConfig("[layout]\nresize-step = 0.005\n")
        mac.mover.clearRecord()
        XCTAssertEqual(mac.run("resize grow"), "ok")
        XCTAssertEqual(third.rect.height, 425 + 4, accuracy: 1)
        XCTAssertEqual(durations(w[1]), [0])
        XCTAssertEqual(durations(third), [0])
    }

    func testNothingGlidesWhenMotionIsSwitchedOff() {
        open(2)
        func durations() -> Set<Double> { Set(mac.mover.moves.map(\.duration)) }

        mac.mover.clearRecord()
        mac.run("flip")
        XCTAssertEqual(durations(), [0.16])

        // Reduce Motion in System Settings.
        mac.system.reduceMotion = true
        mac.mover.clearRecord()
        mac.run("flip")
        XCTAssertEqual(durations(), [0])

        // Or the setting of Iguana's own.
        mac.system.reduceMotion = false
        mac.writeConfig("[animation]\nenabled = false\n")
        mac.mover.clearRecord()
        mac.run("flip")
        XCTAssertEqual(durations(), [0])
    }
}
