import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// Which window the window manager takes to have the focus, as the user and the apps move it.
final class FocusBeliefScenarioTests: FocusScenarioTestCase {
    func testAClickMovesTheFocus() {
        let (left, right) = sideBySide()
        XCTAssertEqual(mac.focused, right.id)

        mac.system.click(left)
        mac.settle()

        XCTAssertEqual(mac.focused, left.id)
        XCTAssertTrue(mac.system.focusRequests.isEmpty, "the window manager follows a click, it does not repeat it")
        XCTAssertEqual(left.raises, 0)
        // Commands act on the window that was clicked.
        XCTAssertEqual(mac.run("focus left"), "ok: nothing in that direction")
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, right.id)
    }

    func testAnAppWhoseKeyWindowIsOnAnotherDesktopCountsByItsWindowHere() {
        mac.system.addDesktop(to: mac.system.displayList[0])
        let safari = mac.system.launch("Safari")
        let here = mac.system.open(safari, title: "Here")
        mac.settle()
        let notes = open("Notes")
        mac.system.showDesktop(2)
        mac.settle()
        let there = mac.system.open(safari, title: "There")
        mac.settle()
        XCTAssertEqual(mac.focused, there.id)

        mac.system.showDesktop(1)
        mac.settle()

        // Safari is still the app in front, and still says its key window is the one on desktop 2.
        XCTAssertTrue(keyWindow === there)
        XCTAssertEqual(mac.system.order.map(\.id), [there.id, notes.id, here.id])
        XCTAssertEqual(mac.focused, here.id, "Safari's window on this desktop, though Notes is in front of it")
        XCTAssertEqual(mac.run("focus right"), "ok", "and commands start from it")
        XCTAssertEqual(mac.focused, notes.id)
    }

    func testWithNoKeyWindowTheWindowInFrontCounts() {
        let (left, right) = sideBySide()
        mac.system.click(left)
        mac.settle()

        // The user clicks the desktop: Finder comes forward, and it has no window.
        let finder = mac.system.launch("Finder")
        finder.comeForward()
        look()

        XCTAssertNil(keyWindow)
        XCTAssertEqual(mac.focused, left.id)
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, right.id)
    }

    func testWhenTheFocusedWindowClosesTheWindowInFrontHasTheFocus() {
        let (left, right) = sideBySide()
        let third = open("Mail")
        mac.system.click(left)
        mac.settle()
        mac.system.click(third)
        mac.settle()

        mac.system.close(third)
        mac.settle()

        // Mail is still the app in front and has no window left.
        XCTAssertEqual(mac.focused, left.id, "the window that was in front of the other")
        XCTAssertNotEqual(mac.focused, right.id)
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, right.id)
    }

    func testNoWindowHasTheFocusWhenNoneIsShowing() {
        let only = open("Safari")
        XCTAssertEqual(mac.focused, only.id)

        mac.system.minimise(only)
        mac.settle()
        XCTAssertNil(mac.focused)
        XCTAssertEqual(mac.run("focus left"), "ok: no windows here")
        XCTAssertEqual(mac.run("float"), "error: no focused window")

        mac.system.unminimise(only)
        mac.settle()
        XCTAssertEqual(mac.focused, only.id)
    }

    func testARequestIsBelievedUntilMacOSHasConfirmedOrRefusedIt() {
        let (left, right) = sideBySide()
        mac.system.focusSticks = false
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")

        // A look at the screen while the request is still open: macOS has not caught up yet.
        mac.wm.scheduleRefresh()
        mac.scheduler.advance(by: 0.05)
        XCTAssertTrue(keyWindow === right)
        XCTAssertEqual(mac.focused, left.id, "what was asked for, not what macOS says so far")

        // It never takes. Once the tries are used up, what macOS says counts again.
        mac.scheduler.advance(by: 1)
        XCTExpectFailure("giving up asks for no new look, so the request goes on being believed until something else happens") {
            XCTAssertEqual(mac.focused, right.id)
        }
        look()
        XCTAssertEqual(mac.focused, right.id)
    }
}

/// `focus recent`: back to the window that had the focus before.
final class FocusRecentScenarioTests: FocusScenarioTestCase {
    func testFocusRecentGoesBackAndForthBetweenTheLastTwoWindows() {
        let first = open("Safari")
        let second = open("Notes")
        let third = open("Mail")
        XCTAssertEqual(mac.focused, third.id)

        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertEqual(mac.focused, second.id)
        XCTAssertTrue(keyWindow === second)
        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertEqual(mac.focused, third.id)
        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertTrue(keyWindow === second)
        XCTAssertEqual(first.raises, 0, "the window before those two is not part of it")

        // A click counts like any other way of moving the focus.
        mac.system.click(first)
        mac.settle()
        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertEqual(mac.focused, second.id, "the window that had the focus before the click")
    }

    func testFocusRecentPassesOverAWindowThatIsNotOnScreen() {
        let first = open("Safari")
        let second = open("Notes")
        let third = open("Mail")

        mac.system.minimise(second)
        mac.settle()
        XCTAssertEqual(mac.focused, third.id)

        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertEqual(mac.focused, first.id)
        XCTAssertTrue(second.minimised, "it stays in the Dock")
    }

    func testFocusRecentNeverGoesToAnotherDesktop() {
        mac.system.addDesktop(to: mac.system.displayList[0])
        let here = open("Safari")
        mac.system.showDesktop(2)
        mac.settle()
        let there = open("Notes")
        XCTAssertEqual(mac.focused, there.id)
        mac.system.showDesktop(1)
        mac.settle()
        XCTAssertEqual(mac.focused, here.id)

        XCTAssertEqual(mac.run("focus recent"), "ok: no other recent window")
        XCTAssertEqual(mac.system.displayList[0].current, 0, "still on the first desktop")
        XCTAssertTrue(mac.system.focusRequests.isEmpty)
    }

    func testFocusRecentPassesOverADialogButNotAStandardWindowOfAFixedSize() {
        let app = mac.system.launch("Preview")
        let document = mac.system.open(app, title: "Report")
        mac.settle()
        let dialog = mac.system.open(app, title: "Print", frame: CGRect(x: 400, y: 300, width: 400, height: 200))
        dialog.subrole = kAXDialogSubrole
        mac.settle()
        XCTAssertEqual(mac.focused, dialog.id)
        let second = open("Notes")

        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertEqual(mac.focused, document.id, "the dialog had the focus more recently, and does not count")

        // A standard window that cannot be resized is not tiled, and still is a window to go back to.
        let fixed = mac.system.open(mac.system.launch("Clock"), frame: CGRect(x: 300, y: 200, width: 230, height: 320))
        fixed.resizable = false
        mac.settle()
        XCTAssertNil(mac.tiles[fixed.id])
        mac.system.click(second)
        mac.settle()
        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertEqual(mac.focused, fixed.id)
    }

    func testAClosedWindowIsForgotten() {
        let first = open("Safari")
        let second = open("Notes")
        let third = open("Mail")

        mac.system.close(second)
        mac.settle()
        XCTAssertEqual(mac.run("focus recent"), "ok")
        XCTAssertEqual(mac.focused, first.id, "not the window that closed")

        mac.system.close(third)
        mac.settle()
        XCTAssertEqual(mac.run("focus recent"), "ok: no other recent window")
        XCTAssertEqual(mac.focused, first.id)
    }
}
