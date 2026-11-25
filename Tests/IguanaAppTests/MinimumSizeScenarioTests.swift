import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// Windows that will not get as small as their tile: how Iguana finds that out, lays out
/// around it, and finds out when it is no longer so.
final class MinimumSizeScenarioTests: ScenarioTestCase {
    private let left = CGRect(x: 8, y: 33, width: 708, height: 859)
    private let right = CGRect(x: 724, y: 33, width: 708, height: 859)

    // MARK: Learning a minimum

    func testAWindowThatLandsBiggerThanAskedIsAskedOnceMoreAndBelievedAMomentLater() {
        let wide = mac.system.open(mac.system.launch("Xcode"))
        wide.minSize = CGSize(width: 900, height: 300)
        mac.settle()
        let other = mac.system.open(mac.system.launch("Notes"))

        // The layout has been applied, and the window came out wider than its half.
        mac.scheduler.advance(by: 0.1)
        XCTAssertEqual(wide.rect.width, 900)
        XCTAssertEqual(wide.sizesAsked.filter { $0 == left.size }.count, 2, "asked for its tile's size, then once more")
        XCTAssertFrame(other.rect, right, "nothing is concluded yet: the two overlap")

        // A moment later it still is that wide, so that is its minimum.
        mac.scheduler.advance(by: 0.1)
        XCTAssertFrame(wide.rect, CGRect(x: 8, y: 33, width: 900, height: 859))
        XCTAssertFrame(other.rect, CGRect(x: 916, y: 33, width: 516, height: 859), "the layout flows round it")
        mac.settle()
        XCTAssertEqual(wide.sizesAsked.filter { $0 == left.size }.count, 2, "and it is not asked for the smaller size again")
    }

    func testAWindowThatWillNotGetShorterPushesTheOneBelowDown() {
        let a = mac.system.open(mac.system.launch("Safari"))
        mac.settle()
        let b = mac.system.open(mac.system.launch("Mail"))
        b.minSize = CGSize(width: 0, height: 600)
        mac.settle()
        let c = mac.system.open(mac.system.launch("Notes"))
        mac.settle()

        XCTAssertFrame(a.rect, left)
        XCTAssertFrame(b.rect, CGRect(x: 724, y: 33, width: 708, height: 600), "its minimum, not half the column")
        XCTAssertFrame(c.rect, CGRect(x: 724, y: 641, width: 708, height: 251), "the one below has what is left")
    }

    func testABusyWindowThatAnswersWithItsOldSizeAndThenTakesTheNewOneHasNoMinimum() {
        let busy = mac.system.open(mac.system.launch("Photos"))
        mac.settle()
        XCTAssertFrame(busy.rect, mac.usable())
        let other = mac.system.open(mac.system.launch("Notes"))
        // The new window has been noticed, and the screen is looked at.
        mac.scheduler.advance(by: 0)
        // Photos is busy: asked to take half the desktop, it stays as wide as it was.
        busy.minSize = busy.rect.size
        mac.wm.refresh()
        XCTAssertEqual(busy.rect.width, 1424)
        // By the time it is asked again it has caught up.
        busy.minSize = .zero
        mac.settle()

        XCTAssertFrame(busy.rect, left, "it took the size the second time")
        XCTAssertFrame(other.rect, right, "so the layout is the even one")
    }

    func testAWindowThatDoesNotTakeTheRequestSaysNothingAboutItsMinimum() {
        let busy = mac.system.open(mac.system.launch("Photos"))
        mac.settle()
        // The app hangs: it takes no request and tells nothing.
        busy.answers = false
        let other = mac.system.open(mac.system.launch("Notes"))
        mac.settle()

        XCTAssertEqual(busy.rect.width, 1424, "it could not be made smaller")
        XCTAssertFrame(mac.tiles[busy.id], left, "but that was not taken for a minimum size: its tile is still half the desktop")
        XCTAssertFrame(other.rect, right)

        // It answers again, and the next look puts it on its tile.
        busy.answers = true
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertFrame(busy.rect, left)
    }

    func testAZoomedWindowTeachesNoMinimum() {
        let (a, b) = openTwo()
        // For now the window cannot be narrower than 1500 points, wider than the desktop.
        a.minSize = CGSize(width: 1500, height: 0)
        let asked = a.sizesAsked.count
        XCTAssertEqual(mac.run("zoom --window \(a.id)"), "ok")
        XCTAssertEqual(a.rect.width, 1500)
        XCTAssertEqual(Array(a.sizesAsked.dropFirst(asked)), [mac.usable().size], "a zoomed window that comes out bigger is not asked again")

        // That is over by the time the zoom ends.
        a.minSize = .zero
        XCTAssertEqual(mac.run("zoom --window \(a.id)"), "ok")
        XCTAssertFrame(a.rect, left, "nothing was remembered from the time it was zoomed")
        XCTAssertFrame(b.rect, right)
    }

    func testAWindowTheUserGrabsBeforeItIsBelievedIsNotLaidOutAroundWhileHeld() {
        let wide = mac.system.open(mac.system.launch("Xcode"))
        wide.minSize = CGSize(width: 900, height: 300)
        mac.settle()
        let other = mac.system.open(mac.system.launch("Notes"))
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(wide.rect.width, 900, "it landed wider than asked, and that is not believed yet")

        // The user takes hold of it before the moment is up.
        mac.system.drag(wide, to: CGPoint(x: 60, y: 90))
        mac.mover.clearRecord()
        mac.scheduler.advance(by: 5)
        XCTAssertFrame(other.rect, right, "nothing is concluded about a window in the user's hand")
        XCTAssertTrue(mac.mover.moves.isEmpty)

        mac.system.releaseMouse()
        mac.settle()
        XCTAssertEqual(wide.rect.minX, 8, accuracy: 1)
        XCTAssertEqual(other.rect.minX, wide.rect.maxX + 8, accuracy: 1, "let go, the two end up side by side")
        XCTAssertEqual(other.rect.maxX, mac.usable().maxX, accuracy: 1)
    }

    // MARK: Checking a minimum again

    func testBalanceForgetsAMinimumTheWindowNoLongerHas() {
        let (wide, other) = openWideAndOther()
        // The app's sidebar is closed: the window can be narrow now.
        wide.minSize = .zero

        XCTAssertEqual(mac.run("balance"), "ok")
        XCTAssertFrame(wide.rect, left, "it took the smaller size, so it has no minimum any more")
        XCTAssertFrame(other.rect, right)
    }

    func testBalanceKeepsAMinimumTheWindowStillHas() {
        let (wide, other) = openWideAndOther()
        let asked = wide.sizesAsked.count

        XCTAssertEqual(mac.run("balance"), "ok")
        XCTAssertTrue(wide.sizesAsked.dropFirst(asked).contains(left.size), "it was asked for the size it would have without a minimum")
        XCTAssertFrame(wide.rect, CGRect(x: 8, y: 33, width: 900, height: 859), "and did not take it")
        XCTAssertFrame(other.rect, CGRect(x: 916, y: 33, width: 516, height: 859))
    }

    func testResizeChecksAMinimumAgain() {
        let (wide, other) = openWideAndOther()
        wide.minSize = .zero

        // The other window has the focus. It grows by a twentieth of the desktop.
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        XCTAssertEqual(other.rect.width, 516 + 0.05 * 1416, accuracy: 2, "it grew from the size it had on screen")
        XCTAssertEqual(wide.rect.width, 900 - 0.05 * 1416, accuracy: 2, "and the window that was held at its minimum gave way")
        XCTAssertEqual(other.rect.minX, wide.rect.maxX + 8, accuracy: 1)
    }

    func testABusyWindowKeepsItsMinimumWhenItIsCheckedAgain() {
        let (wide, other) = openWideAndOther()
        // It would take any size now, but it is busy and cannot be asked.
        wide.minSize = .zero
        wide.answers = false

        XCTAssertEqual(mac.run("balance --window \(other.id)"), "ok")
        XCTAssertFrame(mac.tiles[wide.id], CGRect(x: 8, y: 33, width: 900, height: 859), "what is known about it stays known")
        XCTAssertFrame(other.rect, CGRect(x: 916, y: 33, width: 516, height: 859))
    }

    func testAMinimumRememberedFromTheLastRunIsCheckedBeforeItShapesALayout() {
        let (wide, other) = openWideAndOther()
        // While Iguana is not running, the window loses its minimum.
        mac.save()
        wide.minSize = .zero
        mac.relaunch()

        XCTAssertFrame(wide.rect, left, "it was asked again, took the smaller size, and the layout is the even one")
        XCTAssertFrame(other.rect, right)
    }

    // MARK: -

    private func openTwo() -> (FakeWindow, FakeWindow) {
        let a = mac.system.open(mac.system.launch("Safari"))
        mac.settle()
        let b = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        return (a, b)
    }

    /// A window that is at least 900 points wide on the left, held at that, and another that
    /// has the rest of the desktop and the focus.
    private func openWideAndOther(file: StaticString = #filePath, line: UInt = #line) -> (FakeWindow, FakeWindow) {
        let wide = mac.system.open(mac.system.launch("Xcode"))
        wide.minSize = CGSize(width: 900, height: 300)
        mac.settle()
        let other = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        XCTAssertFrame(wide.rect, CGRect(x: 8, y: 33, width: 900, height: 859), file: file, line: line)
        XCTAssertFrame(other.rect, CGRect(x: 916, y: 33, width: 516, height: 859), file: file, line: line)
        return (wide, other)
    }
}
