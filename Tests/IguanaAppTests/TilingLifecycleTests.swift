import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// Windows opening and closing on one desktop: each makes room for the others.
final class TilingLifecycleTests: ScenarioTestCase {
    func testOneWindowFillsTheDesktop() {
        let safari = mac.system.launch("Safari")
        let window = mac.system.open(safari, title: "Docs")
        mac.settle()

        XCTAssertFrame(window.rect, mac.usable(), "inside the outer gap, under the menu bar")
        XCTAssertEqual(mac.usable(), CGRect(x: 8, y: 33, width: 1424, height: 859))
        XCTAssertEqual(mac.tiles.keys.sorted(), [window.id])
        XCTAssertEqual(mac.focused, window.id)
    }

    func testASecondWindowTakesHalfBesideTheFirst() {
        let safari = mac.system.launch("Safari")
        let first = mac.system.open(safari, title: "One")
        mac.settle()
        let second = mac.system.open(mac.system.launch("Notes"), title: "Two")
        mac.settle()

        XCTAssertFrame(first.rect, CGRect(x: 8, y: 33, width: 708, height: 859))
        XCTAssertFrame(second.rect, CGRect(x: 724, y: 33, width: 708, height: 859), "to the right, one inner gap away")
        XCTAssertEqual(mac.tiledInReadingOrder, [first.id, second.id])
    }

    func testAThirdWindowSplitsTheFocusedTileTheOtherWay() {
        let app = mac.system.launch("Terminal")
        let first = mac.system.open(app)
        mac.settle()
        let second = mac.system.open(app)
        mac.settle()
        let third = mac.system.open(app)
        mac.settle()

        // The second window was focused and is taller than wide, so the third opens below it.
        XCTAssertFrame(first.rect, CGRect(x: 8, y: 33, width: 708, height: 859))
        XCTAssertEqual(second.rect.minX, 724, accuracy: 1)
        XCTAssertEqual(third.rect.minX, 724, accuracy: 1)
        XCTAssertEqual(second.rect.maxY + 8, third.rect.minY, accuracy: 1)
        XCTAssertEqual(third.rect.maxY, mac.usable().maxY, accuracy: 1)
    }

    func testClosingAWindowGivesItsRoomBack() {
        let app = mac.system.launch("Terminal")
        let first = mac.system.open(app)
        mac.settle()
        let second = mac.system.open(app)
        mac.settle()

        mac.system.close(second)
        mac.settle()

        XCTAssertFrame(first.rect, mac.usable())
        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id])
    }

    func testAMinimisedWindowTakesNoRoomAndComesBackToItsPlace() {
        let app = mac.system.launch("Terminal")
        let left = mac.system.open(app)
        mac.settle()
        let right = mac.system.open(app)
        mac.settle()

        mac.system.minimise(left)
        mac.settle()
        XCTAssertFrame(right.rect, mac.usable(), "the window that is left takes the whole desktop")

        mac.system.unminimise(left)
        mac.settle()
        XCTAssertEqual(mac.tiledInReadingOrder, [left.id, right.id], "back on the left, where it was")
        XCTAssertFrame(left.rect, CGRect(x: 8, y: 33, width: 708, height: 859))
    }

    func testAQuittingAppTakesItsWindowsOutOfTheLayout() {
        let terminal = mac.system.launch("Terminal")
        let kept = mac.system.open(terminal)
        mac.settle()
        let notes = mac.system.launch("Notes")
        mac.system.open(notes)
        mac.system.open(notes)
        mac.settle()
        XCTAssertEqual(mac.tiles.count, 3)

        mac.system.quit(notes)
        mac.settle()

        XCTAssertEqual(mac.tiles.keys.sorted(), [kept.id])
        XCTAssertFrame(kept.rect, mac.usable())
        XCTAssertEqual(mac.mover.forgotten, [notes.processIdentifier], "nothing is left on its way to a window that is gone")
    }

    func testDialogsAndFixedSizeWindowsAreLeftAlone() {
        let app = mac.system.launch("Calculator")
        let fixed = mac.system.open(app, frame: CGRect(x: 300, y: 200, width: 230, height: 320))
        fixed.resizable = false
        let dialog = mac.system.open(app, frame: CGRect(x: 400, y: 300, width: 400, height: 200))
        dialog.subrole = kAXDialogSubrole
        mac.settle()

        XCTAssertTrue(mac.tiles.isEmpty)
        XCTAssertEqual(fixed.rect, CGRect(x: 300, y: 200, width: 230, height: 320))
        XCTAssertEqual(dialog.rect, CGRect(x: 400, y: 300, width: 400, height: 200))
        XCTAssertTrue(fixed.sizesAsked.isEmpty && dialog.positionsAsked.isEmpty, "they were never touched")
    }

    func testAnAppWithoutADockIconIsNotWatched() {
        let helper = mac.system.launch("Helper", regular: false)
        let window = mac.system.open(helper, frame: CGRect(x: 100, y: 100, width: 300, height: 300))
        mac.settle()

        XCTAssertTrue(mac.tiles.isEmpty)
        XCTAssertEqual(window.rect, CGRect(x: 100, y: 100, width: 300, height: 300))
    }

    func testNothingIsTouchedWithoutThePermission() {
        replaceScenario(Scenario(start: false))
        mac.system.isTrusted = false
        mac.wm.start()
        let window = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 300, height: 300))
        mac.settle()

        XCTAssertEqual(window.rect, CGRect(x: 100, y: 100, width: 300, height: 300))
        XCTAssertTrue(mac.run("focus left").hasPrefix("error: Iguana needs Accessibility permission"))
        XCTAssertTrue(mac.run("status").contains("waiting for Accessibility permission"), "status still answers")

        // The permission is granted: the next look tiles.
        mac.system.isTrusted = true
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertFrame(window.rect, mac.usable())
    }

    func testPausedLeavesWindowsWhereTheyAre() {
        let app = mac.system.launch("Terminal")
        let first = mac.system.open(app)
        mac.settle()
        XCTAssertEqual(mac.run("pause"), "ok: paused")

        let second = mac.system.open(app, frame: CGRect(x: 50, y: 60, width: 500, height: 400))
        mac.settle()
        XCTAssertFrame(first.rect, mac.usable(), "not moved to make room")
        XCTAssertEqual(second.rect, CGRect(x: 50, y: 60, width: 500, height: 400))

        XCTAssertEqual(mac.run("pause"), "ok: tiling")
        XCTAssertEqual(mac.tiles.count, 2)
        XCTAssertEqual(first.rect.width, second.rect.width, accuracy: 1)
    }

    func testAWindowThatWillNotShrinkKeepsItsMinimumAndTheOthersShareTheRest() {
        let app = mac.system.launch("Xcode")
        let wide = mac.system.open(app)
        wide.minSize = CGSize(width: 900, height: 300)
        mac.settle()
        let other = mac.system.open(mac.system.launch("Notes"))
        mac.settle()

        XCTAssertEqual(wide.rect.width, 900, accuracy: 1, "its minimum, not half the desktop")
        XCTAssertEqual(other.rect.minX, wide.rect.maxX + 8, accuracy: 1, "the other starts where it ends")
        XCTAssertEqual(other.rect.maxX, mac.usable().maxX, accuracy: 1, "and takes what is left")
    }

    func testAnAppThatIsNotReadyIsAskedAgain() {
        let slow = mac.system.launch("Slow")
        slow.readyToBeObserved = false
        // Nothing announces this window: the app could not be observed when it opened.
        let window = mac.system.open(slow)
        mac.settle()
        // The first look lists the app's windows all the same.
        XCTAssertFrame(window.rect, mac.usable())

        slow.readyToBeObserved = true
        let second = mac.system.open(slow)
        mac.scheduler.advance(by: 6)
        XCTAssertEqual(mac.tiles.count, 2, "asked again until it could be observed, then looked at again")
        XCTAssertNotNil(mac.tiles[second.id])
    }
}
