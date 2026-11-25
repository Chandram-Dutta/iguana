import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// How windows get to their tiles: which of them glide, which are placed at once, and which
/// are not sent anywhere.
final class MotionScenarioTests: ScenarioTestCase {
    private let left = CGRect(x: 8, y: 33, width: 708, height: 859)
    private let right = CGRect(x: 724, y: 33, width: 708, height: 859)

    func testANewWindowIsPlacedAtOnceAndTheOthersGlide() {
        let first = mac.system.open(mac.system.launch("Safari"))
        mac.settle()
        mac.mover.clearRecord()
        let second = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 300, y: 200, width: 640, height: 480))
        mac.settle()

        let moves = Dictionary(uniqueKeysWithValues: mac.mover.moves.map { ($0.window, $0) })
        XCTAssertEqual(mac.mover.moves.count, 2)
        XCTAssertEqual(moves[first.id], .init(window: first.id, from: mac.usable(), to: left, duration: 0.16), "the window that was there glides aside")
        XCTAssertEqual(moves[second.id], .init(window: second.id, from: CGRect(x: 300, y: 200, width: 640, height: 480), to: right, duration: 0),
                       "the new one is put on its tile at once")
    }

    func testAChangeOfAFewPointsIsMadeAtOnce() {
        let (a, b) = openTwo()
        mac.mover.clearRecord()

        // The gap between the windows goes from 8 to 16 points: each window changes by 4.
        mac.writeConfig("[gaps]\ninner = 16\n")

        XCTAssertFrame(a.rect, CGRect(x: 8, y: 33, width: 704, height: 859))
        XCTAssertFrame(b.rect, CGRect(x: 728, y: 33, width: 704, height: 859))
        XCTAssertEqual(mac.mover.moves.count, 2)
        XCTAssertEqual(mac.mover.moves.map(\.duration), [0, 0], "too small a change to glide")
    }

    func testTheGlideLastsAsLongAsTheConfigSays() {
        replaceScenario(Scenario(config: "[animation]\nduration = 0.3\n"))
        let (a, b) = openTwo()
        mac.mover.clearRecord()

        mac.system.close(b)
        mac.settle()

        XCTAssertFrame(a.rect, mac.usable())
        XCTAssertEqual(mac.mover.moves, [.init(window: a.id, from: left, to: mac.usable(), duration: 0.3)])
    }

    func testNothingGlidesWhenAnimationIsSwitchedOff() {
        replaceScenario(Scenario(config: "[animation]\nenabled = false\n"))
        let (a, b) = openTwo()
        mac.mover.clearRecord()

        mac.system.close(b)
        mac.settle()

        XCTAssertFrame(a.rect, mac.usable())
        XCTAssertEqual(mac.mover.moves, [.init(window: a.id, from: left, to: mac.usable(), duration: 0)])
    }

    func testNothingGlidesWhenTheSystemReducesMotion() {
        let (a, b) = openTwo()
        mac.mover.clearRecord()
        mac.system.reduceMotion = true

        mac.system.close(b)
        mac.settle()

        XCTAssertFrame(a.rect, mac.usable())
        XCTAssertEqual(mac.mover.moves, [.init(window: a.id, from: left, to: mac.usable(), duration: 0)])
    }

    func testArrivingOnADesktopPlacesEverythingAtOnce() {
        let display = mac.system.displayList[0]
        mac.system.addDesktop(to: display)
        mac.system.open(mac.system.launch("Safari"))
        mac.settle()
        // Two windows side by side on the second desktop.
        mac.system.showDesktop(2)
        mac.settle()
        let (c, d) = openTwo()
        XCTAssertFrame(c.rect, left)
        // Back on the first desktop, one of them closes without being seen.
        mac.system.showDesktop(1)
        mac.settle()
        mac.system.close(d)
        mac.settle()
        XCTAssertFrame(c.rect, left, "a window on a desktop that is not showing is not touched")
        mac.mover.clearRecord()

        mac.system.showDesktop(2)
        mac.settle()

        XCTAssertFrame(c.rect, mac.usable())
        XCTAssertEqual(mac.mover.moves, [.init(window: c.id, from: left, to: mac.usable(), duration: 0)],
                       "the desktop is in order when it comes into view, with nothing still gliding")
    }

    func testTheFirstLayoutAfterIguanaStartsPlacesWindowsAtOnce() {
        let (a, b) = openTwo()
        // While tiling is paused the user moves a window, and then Iguana is started again.
        XCTAssertEqual(mac.run("pause"), "ok: paused")
        a.setPosition(CGPoint(x: 200, y: 300))
        mac.settle()
        mac.mover.clearRecord()

        mac.relaunch()

        XCTAssertFrame(a.rect, left, "back on the tile it had: the layout was remembered")
        XCTAssertFrame(b.rect, right)
        XCTAssertEqual(mac.mover.moves.map(\.window), [a.id])
        XCTAssertEqual(mac.mover.moves.first?.duration, 0)
    }

    func testAWindowAlreadyOnItsWayIsNotSentAgain() {
        let a = mac.system.open(mac.system.launch("Safari"))
        mac.settle()
        mac.mover.clearRecord()
        let b = mac.system.open(mac.system.launch("Notes"))
        // The new window is noticed.
        mac.scheduler.advance(by: 0)

        // The screen is looked at twice before either app has answered.
        mac.wm.refresh()
        XCTAssertEqual(mac.mover.destination(of: a.id), left)
        mac.wm.refresh()
        XCTAssertEqual(mac.mover.moves.map(\.window).sorted(), [a.id, b.id], "each was asked once")

        mac.settle()
        XCTAssertEqual(mac.mover.moves.count, 2)
        XCTAssertNil(mac.mover.destination(of: a.id), "and has arrived")
    }

    func testAWindowBeingDraggedIsNotMovedWhenTheOthersMakeRoom() {
        let (a, b) = openTwo()
        let c = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        mac.mover.clearRecord()

        // The user holds the first window, a little off its tile, while another window closes.
        let held = CGPoint(x: 60, y: 90)
        mac.system.drag(a, to: held)
        mac.settle()
        mac.system.close(c)
        mac.settle()

        XCTAssertEqual(a.rect.origin, held, "the window in the user's hand stays there")
        XCTAssertEqual(mac.mover.moves, [.init(window: b.id, from: CGRect(x: 724, y: 33, width: 708, height: 426), to: right, duration: 0.16)],
                       "the others make room all the same")

        mac.system.releaseMouse()
        mac.settle()
        XCTAssertFrame(a.rect, left)
    }

    private func openTwo() -> (FakeWindow, FakeWindow) {
        let a = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        let b = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        return (a, b)
    }
}

/// Windows joining a layout that are not simply new windows: native tabs, a window that comes
/// out of fullscreen, a window that was not a standard window when it was first seen.
final class AdoptionScenarioTests: ScenarioTestCase {
    private let left = CGRect(x: 8, y: 33, width: 708, height: 859)
    private let right = CGRect(x: 724, y: 33, width: 708, height: 859)

    func testANewTabTakesTheTileOfTheTabItReplaces() {
        let terminal = mac.system.launch("Terminal")
        let first = mac.system.open(terminal, title: "zsh")
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        mac.mover.clearRecord()

        let tab = openTab(of: first, title: "vim")
        mac.settle()

        XCTAssertEqual(mac.tiles, [tab.id: left, notes.id: right], "no third tile was opened")
        XCTAssertEqual(tab.rect, left)
        XCTAssertFrame(notes.rect, right)
        XCTAssertTrue(mac.mover.moves.isEmpty, "nothing had to move: the tab is where its window was")

        // The first tab is chosen again.
        select(first, insteadOf: tab)
        mac.settle()
        XCTAssertEqual(mac.tiles, [first.id: left, notes.id: right])
        XCTAssertEqual(first.rect, left)
    }

    func testGoingBackToTheFirstTabKeepsTheSizeItsWindowWasGiven() {
        let terminal = mac.system.launch("Terminal")
        let first = mac.system.open(terminal, title: "zsh")
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        let tab = openTab(of: first, title: "vim")
        mac.settle()
        // The window is made wider by hand while the second tab is in front.
        mac.system.resize(tab, to: CGRect(x: 8, y: 33, width: 908, height: 859))
        mac.settle()
        mac.system.releaseMouse()
        mac.settle()
        XCTAssertEqual(tab.rect.width, 908, accuracy: 1)
        XCTAssertEqual(notes.rect.minX, 924, accuracy: 1)

        // The first tab is chosen again. It is the same window on screen, so it has the same frame.
        first.rect = tab.rect
        select(first, insteadOf: tab)
        mac.settle()

        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, notes.id])
        XCTExpectFailure("a tab in the background keeps the share it had when it was last in front, so the window jumps back to its old width") {
            XCTAssertEqual(first.rect.width, 908, accuracy: 1, "the tab has the place its window has now")
            XCTAssertEqual(notes.rect.minX, 924, accuracy: 1)
        }
    }

    func testATabIsNotSentAwayByARuleThatNamesADesktop() {
        mac.system.addDesktop(to: mac.system.displayList[0])
        let terminal = mac.system.launch("Terminal")
        let first = mac.system.open(terminal, title: "zsh")
        mac.settle()
        // The rule is written with the window open: that one stays where it is.
        mac.writeConfig("[[rule]]\napp = \"com.example.terminal\"\ndesktop = 2\n")
        XCTAssertTrue(mac.system.moveRequests.isEmpty)

        let tab = openTab(of: first, title: "vim")
        mac.settle()
        XCTAssertTrue(mac.system.moveRequests.isEmpty, "a tab stays with its window")
        XCTAssertFrame(tab.rect, mac.usable())

        // A window of its own goes where the rule says.
        let window = mac.system.open(terminal, title: "ssh", frame: CGRect(x: 300, y: 200, width: 500, height: 400))
        mac.settle()
        XCTAssertEqual(mac.system.moveRequests.map(\.window), [window.id])
        XCTAssertEqual(mac.logged("rule: sent window \(window.id) of Terminal to desktop 2").count, 1)
    }

    func testAWindowInFullscreenIsLeftOutUntilItComesBack() {
        // Iguana starts while Keynote is in fullscreen, on a Space of its own.
        replaceScenario(Scenario(start: false))
        let display = mac.system.displayList[0]
        let desktop = display.currentSpace
        let fullscreen = mac.system.addFullscreenSpace(to: display)
        let window = mac.system.open(mac.system.launch("Keynote"), frame: display.frame, on: fullscreen)
        window.fullscreen = true
        mac.system.show(fullscreen, on: display)
        mac.wm.start()
        mac.settle()

        XCTAssertEqual(window.rect, display.frame, "not touched")
        XCTAssertEqual(mac.run("list-windows"), "no windows on this Space", "and not counted as a window yet")

        // The user leaves fullscreen: the window is an ordinary one on the desktop again.
        window.fullscreen = false
        mac.system.put(window, on: desktop)
        mac.system.show(desktop, on: display)
        mac.settle()

        XCTAssertFrame(window.rect, mac.usable())
        XCTAssertEqual(mac.tiles.keys.sorted(), [window.id])
    }

    func testAWindowThatSettlesIntoItsRoleLaterIsPickedUp() {
        // The window is reported while it still is something else than a standard window.
        let slack = mac.system.launch("Slack")
        let late = mac.system.open(slack, frame: CGRect(x: 300, y: 200, width: 500, height: 400))
        late.subrole = kAXUnknownSubrole
        mac.settle()
        let other = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [other.id])
        XCTAssertEqual(late.rect, CGRect(x: 300, y: 200, width: 500, height: 400), "left alone, as a panel would be")

        // By the time the user comes back to the app it is a standard window.
        late.subrole = kAXStandardWindowSubrole
        mac.system.click(late)
        mac.settle()

        XCTAssertEqual(mac.tiles.count, 2)
        XCTAssertFrame(late.rect, mac.tiles[late.id] ?? .zero)
        XCTAssertEqual(late.rect.width, other.rect.width, accuracy: 1, "it has a tile like any other window")
    }

    // MARK: Tabs

    // macOS shows one tab of a window at a time. Each tab is a window of its own, and the ones
    // in the background are not on screen. The made-up Mac has no way of saying that, so here a
    // tab in the background is a window that is off screen as a minimised one is, without its
    // app having said that it was minimised.

    /// The user opens a new tab in `window`: a new window of the same app with the same frame
    /// comes to the front, and `window` goes to the background.
    private func openTab(of window: FakeWindow, title: String) -> FakeWindow {
        let tab = mac.system.open(window.app, title: title, frame: window.rect)
        window.minimised = true
        return tab
    }

    /// The user chooses another tab of the same window.
    private func select(_ tab: FakeWindow, insteadOf front: FakeWindow) {
        front.minimised = true
        tab.minimised = false
        mac.system.click(tab)
    }
}
