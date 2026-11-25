import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// The windows of a stack overlap. Which is above which decides whether each still shows its strip.
final class StackOrderScenarioTests: FocusScenarioTestCase {
    private var first: FakeWindow!
    private var second: FakeWindow!
    private var third: FakeWindow!

    override func makeScenario() -> Scenario {
        Scenario(config: "[layout]\nauto-split = false\n")
    }

    /// Three windows of one app in one stack. The third was opened last and is in front.
    override func setUp() {
        super.setUp()
        let app = mac.system.launch("Terminal")
        first = mac.system.open(app, title: "one")
        mac.settle()
        second = mac.system.open(app, title: "two")
        mac.settle()
        third = mac.system.open(app, title: "three")
        mac.settle()
        XCTAssertEqual(mac.run("stack"), "ok: stacked")
    }

    private var frontToBack: [CGWindowID] { mac.system.order.map(\.id) }

    func testTheWindowsOfAStackAreRaisedSoThatEveryStripShows() {
        XCTAssertEqual(frontToBack, [third.id, second.id, first.id])
        XCTAssertEqual([first.raises, second.raises, third.raises], [0, 0, 0], "in order as they opened: nothing to do")

        // A click brings the first window in front of the other two. The second is now behind
        // the third, with its strip covered.
        mac.system.click(first)
        mac.settle()
        XCTAssertEqual(frontToBack, [first.id, second.id, third.id], "each window is above the one further from the focused one")
        XCTAssertEqual([first.raises, second.raises, third.raises], [1, 1, 0], "only the windows that were out of order were raised")
        XCTAssertTrue(keyWindow === first, "the focused window was raised last and still has the keyboard")
        XCTAssertEqual(mac.focused, first.id)

        // The middle one: both others show a strip beside it whichever is above the other.
        mac.system.click(second)
        mac.settle()
        XCTAssertEqual(frontToBack, [second.id, first.id, third.id])
        XCTAssertEqual([first.raises, second.raises, third.raises], [1, 1, 0])

        mac.system.click(third)
        mac.settle()
        XCTAssertEqual(frontToBack, [third.id, second.id, first.id])
        XCTAssertTrue(keyWindow === third)
    }

    func testAStackThatWillNotComeRightIsLeftAloneAfterThreeTries() {
        // The app stops answering for its second window, then the user clicks through the stack.
        second.answers = false
        mac.system.click(first)
        mac.system.click(third)
        mac.settle()
        XCTAssertEqual(frontToBack, [third.id, first.id, second.id], "the second window did not come forward")
        XCTAssertEqual(third.raises, 1, "the first try")

        look()
        XCTAssertEqual(third.raises, 2)
        XCTAssertTrue(mac.logged("stack:").isEmpty)
        look()
        XCTAssertEqual(third.raises, 3)
        XCTAssertEqual(mac.logged("stack:"), ["stack: raising [\(second.id), \(third.id)] twice did not put the stack around window \(third.id) in order; trying once more, then leaving it"])

        look()
        look()
        XCTAssertEqual(third.raises, 3, "three tries, then it is left as it is")
        XCTAssertEqual(mac.logged("stack:").count, 1)

        // A command is the user doing something: the stack gets three more tries.
        XCTAssertEqual(mac.run("split auto"), "ok: automatic")
        XCTAssertEqual(third.raises, 4, "the first of them at once")
        for _ in 1...4 { look() }
        XCTAssertEqual(third.raises, 6)
        XCTAssertEqual(mac.logged("stack:").count, 2)

        // So is letting go of the mouse. By now the app answers again.
        second.answers = true
        mac.system.releaseMouse()
        look()
        XCTAssertEqual(frontToBack, [third.id, second.id, first.id])
        XCTAssertEqual(third.raises, 7)
        look()
        XCTAssertEqual(third.raises, 7, "in order: nothing more to do")
    }
}

/// A window picked by name: a click in the menu bar's menu, `focus --window`, the window switcher.
final class FocusWindowScenarioTests: FocusScenarioTestCase {
    func testAWindowPickedInTheMenuGetsTheFocus() {
        let (left, right) = sideBySide()

        mac.wm.focusWindow(left.id)
        mac.settle()

        XCTAssertEqual(mac.focused, left.id)
        XCTAssertTrue(keyWindow === left)
        XCTAssertEqual(mac.system.focusRequests, [left.id])
        XCTAssertEqual(mac.system.order.map(\.id), [left.id, right.id])
    }

    func testFocusWithAWindowIDFocusesThatWindow() {
        let (left, right) = sideBySide()

        XCTAssertEqual(mac.run("focus --window \(left.id)"), "ok")
        XCTAssertEqual(mac.focused, left.id)
        XCTAssertTrue(keyWindow === left)

        XCTAssertEqual(mac.run("focus --window 9999"), "error: no window 9999")
        XCTAssertTrue(mac.run("focus --window \(right.id) left").hasPrefix("error: 'focus --window ID' takes no direction"))
        XCTAssertEqual(mac.focused, left.id)
    }

    func testNothingIsFocusedForAWindowThatIsGoneOrWithoutThePermission() {
        let (left, right) = sideBySide()

        mac.wm.focusWindow(9999)
        mac.wm.focusFromPointer(9999)
        mac.wm.bringForward(9999)
        mac.settle()
        XCTAssertTrue(mac.system.focusRequests.isEmpty)

        // The permission was taken away while Iguana runs.
        mac.system.isTrusted = false
        mac.wm.focusWindow(left.id)
        mac.wm.focusFromPointer(left.id)
        mac.settle()
        XCTAssertTrue(mac.system.focusRequests.isEmpty)
        XCTAssertEqual(left.raises, 0)
        XCTAssertTrue(keyWindow === right)
    }
}

private extension FakeWindow {
    /// The made-up Mac has no stages. A window in a stage that is not showing is off screen, on
    /// the desktop being shown, and not minimised. This is the nearest to it: off screen, and
    /// nothing says it is in the Dock.
    func setAsideInAnotherStage() {
        minimised = true
        answers = false
    }
}

/// What the window switcher lists, and what choosing a row does.
final class SwitcherScenarioTests: FocusScenarioTestCase {
    private func listed() -> [CGWindowID: Switcher.Window] {
        Dictionary(uniqueKeysWithValues: mac.wm.switcherWindows().windows.map { ($0.id, $0) })
    }

    func testTheSwitcherListsTheWindowUsedBeforeThisOneFirstAndTheFocusedOneLast() {
        let safari = open("Safari", title: "Docs")
        let notes = open("Notes", title: "Shopping")
        let terminal = open("Terminal", title: "zsh")
        mac.system.click(safari)
        mac.settle()

        let (windows, owners) = mac.wm.switcherWindows()

        XCTAssertEqual(windows.map(\.id), [terminal.id, notes.id, safari.id])
        XCTAssertEqual(windows.map(\.app), ["Terminal", "Notes", "Safari"])
        XCTAssertEqual(windows.map(\.title), ["zsh", "Shopping", "Docs"])
        XCTAssertEqual(windows.map(\.focused), [false, false, true])
        XCTAssertTrue(windows.allSatisfy { $0.visibility == .onScreen && $0.desktop == 1 })
        XCTAssertEqual(owners, [safari.id: safari.pid, notes.id: notes.pid, terminal.id: terminal.pid])
    }

    func testWindowsThatNeverHadTheFocusComeAfterThoseThatDidFrontToBack() {
        let mail = mac.system.launch("Mail")
        // Two windows open at once. Only the one in front ever has the keyboard.
        let inbox = mac.system.open(mail, title: "Inbox")
        let draft = mac.system.open(mail, title: "Draft")
        mac.settle()
        let activity = mac.system.open(mail, title: "Activity", focus: false)
        let terminal = open("Terminal", title: "zsh")

        XCTAssertEqual(mac.wm.switcherWindows().windows.map(\.id), [draft.id, inbox.id, activity.id, terminal.id])
    }

    func testTheSwitcherSaysWhyAWindowCannotBeSeen() {
        let second = mac.system.addDesktop(to: mac.system.displayList[0])
        let safari = mac.system.launch("Safari")
        let shown = mac.system.open(safari, title: "Docs")
        mac.settle()
        let sheet = mac.system.open(safari, title: "Save", frame: CGRect(x: 400, y: 300, width: 400, height: 200))
        sheet.subrole = kAXDialogSubrole
        let clock = mac.system.open(mac.system.launch("Clock"), title: "World Clock", frame: CGRect(x: 300, y: 200, width: 230, height: 320))
        clock.resizable = false
        mac.settle()
        let notes = open("Notes", title: "Shopping")
        mac.system.minimise(notes)
        let mail = open("Mail", title: "Inbox")
        mac.system.hide(mail.app)
        let terminal = mac.system.open(mac.system.launch("Terminal"), title: "zsh", on: second)
        mac.settle()

        var found = listed()
        XCTAssertEqual(found[shown.id]?.visibility, .onScreen)
        XCTAssertEqual(found[clock.id]?.visibility, .onScreen, "a standard window of a fixed size is listed, though it is not tiled")
        XCTAssertNil(found[sheet.id], "a dialog is not")
        XCTAssertEqual(found[notes.id]?.visibility, .minimised)
        XCTAssertEqual(found[mail.id]?.visibility, .hidden)
        XCTAssertEqual(found[terminal.id]?.visibility, .elsewhere)
        XCTAssertEqual(found[terminal.id]?.desktop, 2)
        XCTAssertEqual(found[notes.id]?.desktop, 1, "a window in the Dock still belongs to its desktop")
        XCTAssertEqual(found.count, 5)

        // Stage Manager does not make a window on another desktop a window in another stage.
        mac.system.stageManager.isOn = true
        found = listed()
        XCTAssertEqual(found[terminal.id]?.visibility, .elsewhere)
        XCTAssertEqual(found[notes.id]?.visibility, .minimised)
    }

    func testWithStageManagerAWindowSetAsideOnThisDesktopIsInAnotherStage() {
        let (left, right) = sideBySide()
        mac.system.stageManager.isOn = true
        left.setAsideInAnotherStage()
        look()

        XCTAssertEqual(listed()[left.id]?.visibility, .otherStage)
        XCTAssertEqual(listed()[left.id]?.desktop, 1)
        XCTAssertEqual(listed()[right.id]?.visibility, .onScreen)

        // Choosing it asks macOS for the window, which brings its stage forward.
        mac.wm.bringForward(left.id)
        XCTAssertEqual(mac.system.focusRequests, [left.id])
        mac.settle()

        // Without Stage Manager there is no telling where such a window went.
        mac.system.stageManager.isOn = false
        XCTAssertEqual(listed()[left.id]?.visibility, .elsewhere)
    }

    func testChoosingAMinimisedWindowBringsItOutOfTheDock() {
        let (left, right) = sideBySide()
        mac.system.minimise(left)
        mac.settle()
        XCTAssertFrame(right.rect, mac.usable())

        mac.wm.bringForward(left.id)
        mac.settle()

        XCTAssertFalse(left.minimised)
        XCTAssertEqual(mac.focused, left.id)
        XCTAssertTrue(keyWindow === left)
        XCTAssertEqual(mac.tiledInReadingOrder, [left.id, right.id], "back on its tile")
    }

    func testChoosingAWindowOfAHiddenAppShowsTheApp() {
        let (left, right) = sideBySide()
        mac.system.hide(left.app)
        mac.settle()
        XCTAssertEqual(mac.focused, right.id)

        mac.wm.bringForward(left.id)
        mac.settle()

        XCTAssertFalse(left.app.isHidden)
        XCTAssertEqual(mac.focused, left.id)
        XCTAssertTrue(keyWindow === left)
        XCTAssertEqual(mac.system.focusRequests, [left.id], "the window itself was asked for, not just its app")
    }

    func testChoosingAWindowOnAnotherDesktopAsksMacOSForIt() {
        let second = mac.system.addDesktop(to: mac.system.displayList[0])
        let elsewhere = mac.system.open(mac.system.launch("Terminal"), title: "zsh", on: second)
        open("Notes")

        mac.wm.bringForward(elsewhere.id)
        mac.settle()

        // Going to the desktop the window is on is what macOS does when a window is given the focus.
        XCTAssertEqual(mac.system.focusRequests, [elsewhere.id])
        XCTAssertEqual(elsewhere.raises, 1)
        XCTAssertTrue(keyWindow === elsewhere)
        XCTAssertTrue(mac.system.pressed.isEmpty, "Iguana presses no Mission Control shortcut for it")
    }
}
