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

        // The first tab is chosen again.
        mac.mover.clearRecord()
        select(first, insteadOf: tab)
        mac.settle()

        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, notes.id])
        XCTAssertEqual(first.rect.width, 908, accuracy: 1, "the tab has the place its window has now")
        XCTAssertEqual(notes.rect.minX, 924, accuracy: 1)
        XCTAssertTrue(mac.mover.moves.isEmpty, "nothing had to move")

        // And so has the second, when it is chosen once more.
        select(tab, insteadOf: first)
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [tab.id, notes.id].sorted())
        XCTAssertEqual(tab.rect.width, 908, accuracy: 1)
        XCTAssertTrue(mac.mover.moves.isEmpty)
    }

    func testGoingBackToTheFirstTabFindsTheWindowWhereItWasMoved() {
        let (first, notes, tab) = openTabbedTerminalAndNotes()
        XCTAssertEqual(mac.run("move right"), "ok")
        XCTAssertEqual(mac.tiles, [notes.id: left, tab.id: right])

        mac.mover.clearRecord()
        select(first, insteadOf: tab)
        mac.settle()
        XCTAssertEqual(mac.tiles, [notes.id: left, first.id: right], "the window is on the right now, whichever tab it shows")
        XCTAssertEqual(first.rect, right)
        XCTAssertTrue(mac.mover.moves.isEmpty, "nothing had to move")
    }

    func testGoingBackToTheFirstTabFindsTheWindowWhereItWasDropped() {
        let (first, notes, tab) = openTabbedTerminalAndNotes()
        let music = mac.system.open(mac.system.launch("Music"))
        mac.settle()
        let below = CGRect(x: 724, y: 467, width: 708, height: 425)
        XCTAssertEqual(mac.tiles[music.id], below, "under Notes, on the right")

        // The window is carried to the middle of that tile while the second tab is in front: the two trade places.
        mac.system.drag(tab, to: CGPoint(x: below.midX - tab.rect.width / 2, y: below.midY - 10))
        mac.settle()
        mac.system.releaseMouse()
        mac.settle()
        XCTAssertEqual(mac.tiles[music.id], left)
        XCTAssertEqual(mac.tiles[tab.id], below)

        select(first, insteadOf: tab)
        mac.settle()
        XCTAssertEqual(mac.tiles[first.id], below, "the first tab is where the window was dropped")
        XCTAssertEqual(mac.tiles[music.id], left)
        XCTAssertEqual(mac.tiles.count, 3)
        XCTAssertEqual(mac.tiles[notes.id], CGRect(x: 724, y: 33, width: 708, height: 426))
    }

    func testThreeTabsAreOneTile() {
        let (first, notes, second) = openTabbedTerminalAndNotes()
        let third = openTab(of: second, title: "ssh")
        mac.settle()
        XCTAssertEqual(mac.tiles, [third.id: left, notes.id: right])
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        let wide = third.rect
        XCTAssertEqual(wide.width, 779, accuracy: 1)

        // Straight back to the first tab, past the second.
        select(first, insteadOf: third)
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, notes.id])
        XCTAssertEqual(first.rect, wide)

        select(second, insteadOf: first)
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [notes.id, second.id].sorted())
        XCTAssertEqual(second.rect, wide)
    }

    func testClosingTheTabInFrontLeavesItsPlaceToTheTabThatComesForward() {
        let (first, notes, second) = openTabbedTerminalAndNotes()
        let third = openTab(of: second, title: "ssh")
        mac.settle()
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        let wide = third.rect

        // The tab in front is closed. The app shows the first tab, not the one that was in front before.
        close(third, showing: first)
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, notes.id], "the window is still one tile")
        XCTAssertEqual(first.rect, wide, "in the place it had")
        XCTAssertEqual(notes.rect.minX, wide.maxX + 8, accuracy: 1)

        // The tab that is left is still a tab of this window.
        select(second, insteadOf: first)
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [notes.id, second.id].sorted())
        XCTAssertEqual(second.rect, wide)
    }

    func testATabThatShowsAMomentAfterTheOneInFrontClosedHasItsWindowsPlace() {
        let (first, notes, tab) = openTabbedTerminalAndNotes()
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        let wide = tab.rect

        // The tab in front is gone, and for a moment the window shows none.
        mac.system.close(tab)
        mac.settle()
        XCTAssertEqual(mac.tiles, [notes.id: mac.usable()], "a window that is not on screen takes no room")

        // Then the tab that is left shows, and the screen is looked at again.
        first.offScreen = false
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, notes.id])
        XCTAssertEqual(first.rect, wide, "the place was kept for it")
    }

    func testClosingATabThatIsNotInFrontChangesNothing() {
        let (first, notes, tab) = openTabbedTerminalAndNotes()
        mac.mover.clearRecord()

        mac.system.close(first)
        mac.settle()
        XCTAssertEqual(mac.tiles, [tab.id: left, notes.id: right])
        XCTAssertTrue(mac.mover.moves.isEmpty)

        // The tab that is left is the window now. When it closes, nothing of the window is kept.
        mac.system.close(tab)
        mac.settle()
        XCTAssertEqual(mac.tiles, [notes.id: mac.usable()])
        XCTAssertEqual(mac.wm.treeEntry(containing: notes.id)?.1.windows, [notes.id])
    }

    func testATabDraggedOutOfItsWindowGetsATileOfItsOwn() {
        let (first, notes, tab) = openTabbedTerminalAndNotes()

        // The tab that is not in front becomes a window of its own, somewhere else on screen.
        first.rect = CGRect(x: 300, y: 200, width: 500, height: 400)
        first.offScreen = false
        mac.system.click(first)
        mac.settle()
        XCTAssertEqual(mac.tiles.count, 3, "two windows of the terminal now, and Notes")
        for window in [first, notes, tab] { XCTAssertFrame(window.rect, mac.tiles[window.id] ?? .zero) }

        // It is no tab of that window any more: when the window closes, it stays where it is.
        let own = first.rect
        XCTAssertEqual(mac.run("balance"), "ok")
        mac.system.close(tab)
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, notes.id])
        XCTAssertEqual(first.rect.minY, own.minY, accuracy: 1)
    }

    func testUndoPutsTheWindowBackWhicheverTabIsInFront() {
        let (first, notes, tab) = openTabbedTerminalAndNotes()
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        let wide = tab.rect
        select(first, insteadOf: tab)
        mac.settle()
        XCTAssertEqual(first.rect, wide)

        // The step that is undone was made while the other tab was in front.
        XCTAssertEqual(mac.run("undo"), "ok: undone")
        XCTAssertEqual(mac.tiles, [first.id: left, notes.id: right])
        XCTAssertFrame(first.rect, left)
        XCTAssertEqual(mac.run("redo"), "ok: redone")
        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, notes.id])
        XCTAssertFrame(first.rect, wide)

        // Tabs still take each other's place afterwards.
        select(tab, insteadOf: first)
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [tab.id, notes.id].sorted())
        XCTAssertFrame(tab.rect, wide)
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
    // in the background are not on screen.

    /// A terminal on the left and Notes on the right, and then a second tab in the terminal,
    /// which is the one in front and has the keyboard.
    private func openTabbedTerminalAndNotes(file: StaticString = #filePath, line: UInt = #line) -> (first: FakeWindow, notes: FakeWindow, tab: FakeWindow) {
        let first = mac.system.open(mac.system.launch("Terminal"), title: "zsh")
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        let tab = openTab(of: first, title: "vim")
        mac.settle()
        XCTAssertEqual(mac.tiles, [tab.id: left, notes.id: right], file: file, line: line)
        return (first, notes, tab)
    }

    /// The user opens a new tab in `window`: a new window of the same app with the same frame
    /// comes to the front, and `window` goes to the background.
    private func openTab(of window: FakeWindow, title: String) -> FakeWindow {
        let tab = mac.system.open(window.app, title: title, frame: window.rect)
        window.offScreen = true
        return tab
    }

    /// The user chooses another tab of the same window. It is the same window on screen, so
    /// the tab has the frame the one in front had.
    private func select(_ tab: FakeWindow, insteadOf front: FakeWindow) {
        tab.rect = front.rect
        front.offScreen = true
        tab.offScreen = false
        mac.system.click(tab)
    }

    /// The user closes the tab in front, and the app shows another tab of the window.
    private func close(_ front: FakeWindow, showing tab: FakeWindow) {
        tab.rect = front.rect
        mac.system.close(front)
        tab.offScreen = false
        mac.system.click(tab)
    }
}
