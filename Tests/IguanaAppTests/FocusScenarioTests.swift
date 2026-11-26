import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// What the focus tests share: a few words for arranging windows and for looking at who has
/// the keyboard.
class FocusScenarioTestCase: ScenarioTestCase {
    /// The window that has the keyboard on the made-up Mac, whatever the window manager believes.
    var keyWindow: FakeWindow? { mac.system.frontmost?.focusedWindow }

    /// Launch an app and open one window of it. The window takes the keyboard, as a new one does.
    @discardableResult
    func open(_ app: String, bundleID: String? = nil, title: String = "", frame: CGRect? = nil) -> FakeWindow {
        let window = mac.system.open(mac.system.launch(app, bundleID: bundleID), title: title, frame: frame)
        mac.settle()
        return window
    }

    /// Two tiles side by side. The right one was opened last and has the keyboard.
    func sideBySide() -> (left: FakeWindow, right: FakeWindow) {
        let left = open("Safari", title: "Docs")
        let right = open("Notes", title: "Shopping")
        return (left, right)
    }

    /// Have the window manager look at the screen again, as it does after any event.
    func look() {
        mac.wm.scheduleRefresh()
        mac.settle()
    }

    func middle(of window: FakeWindow) -> CGPoint {
        CGPoint(x: window.rect.midX, y: window.rect.midY)
    }
}

/// `focus left|right|up|down`: which window it goes to.
final class FocusDirectionScenarioTests: FocusScenarioTestCase {
    func testFocusGoesToTheNeighbourInThatDirection() {
        let app = mac.system.launch("Terminal")
        let left = mac.system.open(app, title: "left")
        mac.settle()
        let top = mac.system.open(app, title: "top right")
        mac.settle()
        let bottom = mac.system.open(app, title: "bottom right")
        mac.settle()
        XCTAssertEqual(mac.focused, bottom.id, "the window opened last has the keyboard")

        XCTAssertEqual(mac.run("focus up"), "ok")
        XCTAssertEqual(mac.focused, top.id)
        XCTAssertTrue(keyWindow === top, "the keyboard went with it")

        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.focused, left.id)

        // Both windows on the right touch the left one. The one level with its top wins.
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, top.id)

        XCTAssertEqual(mac.run("focus down"), "ok")
        XCTAssertEqual(mac.focused, bottom.id)
        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertTrue(keyWindow === left)
    }

    func testFocusSaysSoWhenThereIsNowhereToGo() {
        XCTAssertEqual(mac.run("focus left"), "ok: no windows here")
        XCTAssertNil(mac.focused)

        let (_, right) = sideBySide()
        for direction in ["right", "up", "down"] {
            XCTAssertEqual(mac.run("focus \(direction)"), "ok: nothing in that direction")
        }
        XCTAssertEqual(mac.focused, right.id, "the focus stays where it is")
        XCTAssertTrue(mac.system.focusRequests.isEmpty, "and no window was asked to take it")
    }

    func testFocusTakesTheFrontWindowWhenTheKeyboardIsInAWindowIguanaLeavesAlone() {
        mac.system.addDisplay("External", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let (left, right) = sideBySide()
        // A film in native fullscreen on the other display. Iguana does not take such a window in.
        let film = mac.system.open(mac.system.launch("TV"), frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        film.fullscreen = true
        mac.settle()
        XCTAssertTrue(keyWindow === film)
        XCTAssertNil(mac.tiles[film.id])

        // There is no place to start from, so the window in front of the others gets the focus.
        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.focused, right.id)
        XCTAssertTrue(keyWindow === right)
        XCTAssertEqual(mac.system.focusRequests, [right.id])
        XCTAssertEqual(left.raises, 0)
    }

    func testAFloatingWindowTakesPartWhereItIs() {
        let (left, right) = sideBySide()
        // The built-in rules float Calculator. It lies across the gap between the two tiles.
        let floating = open("Calculator", bundleID: "com.apple.calculator", frame: CGRect(x: 500, y: 300, width: 400, height: 300))
        XCTAssertNil(mac.tiles[floating.id])
        XCTAssertEqual(floating.rect, CGRect(x: 500, y: 300, width: 400, height: 300), "left where it opened")

        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.focused, left.id)
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, floating.id, "it is nearer than the tile on the right")
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, right.id)
        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertTrue(keyWindow === floating)
    }

    func testFocusCrossesToTheOtherDisplay() {
        mac.system.addDisplay("External", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let near = open("Safari")
        let far = open("Notes", frame: CGRect(x: 1700, y: 200, width: 600, height: 400))
        XCTAssertGreaterThanOrEqual(far.rect.minX, 1440, "tiled on the display it opened on")
        XCTAssertEqual(mac.focused, far.id)

        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.focused, near.id)
        XCTAssertTrue(keyWindow === near)
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertTrue(keyWindow === far)
        XCTAssertEqual(mac.run("focus right"), "ok: nothing in that direction")
    }

    func testInsideAStackFocusStepsThroughTheWindowsInOrder() {
        replaceScenario(Scenario(config: "[layout]\nauto-split = false\n"))
        let app = mac.system.launch("Terminal")
        let first = mac.system.open(app, title: "one")
        mac.settle()
        let second = mac.system.open(app, title: "two")
        mac.settle()
        let third = mac.system.open(app, title: "three")
        mac.settle()
        XCTAssertEqual(mac.run("stack"), "ok: stacked")
        // Each window starts one strip further right, and they all overlap.
        XCTAssertEqual(second.rect.minX - first.rect.minX, 32, accuracy: 1)
        XCTAssertEqual(third.rect.minX - second.rect.minX, 32, accuracy: 1)
        XCTAssertGreaterThan(first.rect.maxX, third.rect.minX)

        // By the picture the first window is as near as the second. The layout says the second is next.
        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.focused, second.id)
        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.focused, first.id)
        XCTAssertEqual(mac.run("focus left"), "ok: nothing in that direction", "the stack ends here and nothing is beyond it")

        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, second.id)
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertTrue(keyWindow === third)
        XCTAssertEqual(mac.run("focus right"), "ok: nothing in that direction")
    }

    func testAStackEnteredFromTheSideGivesTheWindowItHasInFront() {
        let app = mac.system.launch("Terminal")
        let beside = mac.system.open(app, title: "beside")
        mac.settle()
        let upper = mac.system.open(app, title: "upper")
        mac.settle()
        let lower = mac.system.open(app, title: "lower")
        mac.settle()
        // The two windows on the right become a stack that runs downwards.
        XCTAssertEqual(mac.run("stack"), "ok: stacked")
        XCTAssertEqual(lower.rect.minY - upper.rect.minY, 32, accuracy: 1)
        XCTAssertEqual(beside.rect.minX, 8, accuracy: 1)

        mac.system.click(beside)
        mac.settle()
        // The upper window is level with the one on the left. The lower one is in front.
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.focused, lower.id, "the window the user sees")

        XCTAssertEqual(mac.run("focus up"), "ok")
        XCTAssertEqual(mac.focused, upper.id, "up and down step through the stack")
        XCTAssertEqual(mac.run("focus up"), "ok: nothing in that direction")

        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.focused, beside.id, "across the stack, focus leaves it")
        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertTrue(keyWindow === upper, "back to the window that is in front now")
    }
}

/// How a window is given the focus, and what happens when macOS does not go along.
final class FocusDeliveryScenarioTests: FocusScenarioTestCase {
    func testFocusAsksForTheWindowItselfAndRaisesIt() {
        let (left, right) = sideBySide()

        XCTAssertEqual(mac.run("focus left"), "ok")

        XCTAssertEqual(mac.system.focusRequests, [left.id], "asked for once, directly")
        XCTAssertEqual(left.raises, 1)
        XCTAssertEqual(left.app.activations, 0, "the app's other windows were not brought forward with it")
        XCTAssertTrue(mac.system.frontmost === left.app)
        XCTAssertTrue(left.app.focusedWindow === left)
        XCTAssertEqual(mac.system.order.map(\.id), [left.id, right.id], "it is in front")
        XCTAssertTrue(mac.system.warps.isEmpty, "the pointer stays where it is unless mouse-follows-focus is on")
    }

    func testFocusGoesThroughTheAppWhenTheDirectRouteFails() {
        let (left, _) = sideBySide()
        mac.system.directFocusWorks = false

        XCTAssertEqual(mac.run("focus left"), "ok")

        XCTAssertEqual(mac.system.focusRequests, [left.id], "the direct route was tried first")
        XCTAssertEqual(left.app.activations, 1, "then the app was brought forward")
        XCTAssertEqual(left.raises, 1)
        XCTAssertTrue(keyWindow === left)
        XCTAssertEqual(mac.focused, left.id)
    }

    func testAFocusThatDoesNotTakeIsTriedAgainThroughTheAppThenGivenUp() {
        let (left, right) = sideBySide()
        mac.system.focusSticks = false

        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertEqual(mac.system.focusRequests, [left.id])
        XCTAssertEqual(left.app.activations, 0)
        XCTAssertEqual(left.raises, 1)
        XCTAssertTrue(keyWindow === right, "macOS said yes and changed nothing")

        mac.scheduler.advance(by: 0.12)
        XCTAssertEqual(left.app.activations, 1, "the second try goes through the app")
        XCTAssertEqual(left.raises, 2)

        mac.scheduler.advance(by: 0.12)
        XCTAssertEqual(left.app.activations, 2, "and so does the third")
        XCTAssertEqual(left.raises, 3)

        mac.scheduler.advance(by: 0.12)
        mac.settle()
        XCTAssertEqual(left.app.activations, 2, "three tries, then it is left alone")
        XCTAssertEqual(left.raises, 3)
        XCTAssertEqual(mac.system.focusRequests, [left.id], "the direct route was used once")

        // The next look finds the keyboard where it stayed.
        look()
        XCTAssertEqual(mac.focused, right.id)
    }

    func testTheRetriesStopAsSoonAsTheFocusHasTaken() {
        let (left, _) = sideBySide()
        mac.system.focusSticks = false
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")

        // macOS comes round before the second try.
        mac.system.focusSticks = true
        mac.scheduler.advance(by: 0.12)
        XCTAssertEqual(left.app.activations, 1)
        XCTAssertTrue(keyWindow === left)

        mac.settle()
        XCTAssertEqual(left.app.activations, 1, "it was not asked a third time")
        XCTAssertEqual(left.raises, 2)
        look()
        XCTAssertEqual(mac.focused, left.id)
    }

    func testAWindowThatTakesTheKeyboardJustAfterAFocusCommandKeepsIt() {
        let (left, _) = sideBySide()
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertTrue(keyWindow === left, "the focus took at once")

        // Before the window manager has checked, an app that was launching opens its window.
        mac.scheduler.advance(by: 0.05)
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertTrue(keyWindow === mail)
        XCTAssertEqual(left.app.activations, 0)
        XCTAssertEqual(left.raises, 1, "the window that was asked for is not asked again")
        XCTAssertEqual(mac.focused, mail.id, "and the window manager follows the keyboard")
    }

    func testAClickOnAnotherWindowJustAfterAFocusCommandIsNotUndone() {
        let (left, right) = sideBySide()
        let mail = open("Mail")
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertTrue(keyWindow === left)

        // The user clicks a third window before the window manager has checked.
        mac.scheduler.advance(by: 0.05)
        mac.system.click(right)
        mac.settle()

        XCTAssertTrue(keyWindow === right)
        XCTAssertEqual(mac.focused, right.id)
        XCTAssertEqual(left.app.activations, 0)
        XCTAssertEqual(left.raises, 1)
        XCTAssertEqual(mac.system.focusRequests, [left.id])
        XCTAssertEqual(mail.raises, 0)
    }

    func testAClickBackOnTheWindowTheKeyboardCameFromIsNotUndone() {
        let (left, right) = sideBySide()
        // The apps say so when the focus reaches them, as nearly all do.
        mac.system.appsTellOfFocus = true
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")

        // The request took and its app said so. Then the user clicks the window on the right
        // again, still before the check.
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(mac.focused, left.id)
        mac.system.click(right)
        mac.settle()

        XCTAssertTrue(keyWindow === right, "the keyboard is where it was before the command, and by the user's hand")
        XCTAssertEqual(mac.focused, right.id)
        XCTAssertEqual(left.app.activations, 0)
        XCTAssertEqual(left.raises, 1)
    }

    func testARequestMacOSIgnoredIsDroppedWhenTheKeyboardHasGoneElsewhere() {
        let (left, right) = sideBySide()
        mac.system.focusSticks = false
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertTrue(keyWindow === right, "macOS said yes and changed nothing")

        // A new window takes the keyboard. It is not where it was, so this is not for a retry to undo.
        mac.scheduler.advance(by: 0.05)
        mac.system.focusSticks = true
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertTrue(keyWindow === mail)
        XCTAssertEqual(left.app.activations, 0)
        XCTAssertEqual(left.raises, 1)
        XCTAssertEqual(mac.focused, mail.id)
    }

    func testAnAppWithNoWindowThatComesForwardJustAfterAFocusCommandStaysInFront() {
        let (left, right) = sideBySide()
        // The user clicked the desktop: Finder is in front, and no window has the keyboard.
        let finder = mac.system.launch("Finder")
        finder.comeForward()
        look()
        XCTAssertNil(keyWindow)
        XCTAssertEqual(mac.focused, right.id)

        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertTrue(keyWindow === left)

        // A launcher's panel opens. Again no window has the keyboard, and yet it is not where it was.
        mac.scheduler.advance(by: 0.05)
        let launcher = mac.system.launch("Launcher", regular: false)
        launcher.comeForward()
        mac.settle()

        XCTAssertTrue(mac.system.frontmost === launcher)
        XCTAssertEqual(left.app.activations, 0)
        XCTAssertEqual(left.raises, 1)
    }

    func testAnAppThatCameForwardWithTheWindowItHadIsAskedAgain() {
        let safari = mac.system.launch("Safari")
        let docs = mac.system.open(safari, title: "Docs")
        mac.settle()
        let downloads = mac.system.open(safari, title: "Downloads")
        mac.settle()
        let notes = open("Notes")
        XCTAssertTrue(safari.focusedWindow === downloads, "the window Safari had the keyboard in last")
        // The direct route fails, and the window is too busy to take a request.
        mac.system.directFocusWorks = false
        docs.answers = false

        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertEqual(mac.focused, docs.id)
        XCTAssertEqual(safari.activations, 1)
        XCTAssertTrue(keyWindow === downloads, "Safari is in front, with the window it had")

        // That is half of what was asked, and nobody else's doing: it is asked again.
        docs.answers = true
        mac.scheduler.advance(by: 0.12)
        XCTAssertEqual(safari.activations, 2)
        XCTAssertTrue(keyWindow === docs)

        mac.settle()
        XCTAssertEqual(safari.activations, 2, "and once it has taken, no more")
        XCTAssertEqual(mac.focused, docs.id)
        XCTAssertEqual(notes.raises, 0)
    }

    func testAFocusCommandBeforeTheLastIsConfirmedTakesOver() {
        let left = open("Safari")
        let top = open("Notes")
        let bottom = open("Mail")
        mac.system.focusSticks = false

        XCTAssertEqual(mac.wm.run(.focus(.up)), "ok")
        XCTAssertEqual(mac.focused, top.id)
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertEqual(mac.focused, left.id, "the second command starts from where the first was going")

        // The time to check the first request comes, 0.12 s after it was made. It is not what
        // is wanted any more.
        mac.scheduler.advance(by: 0.08)
        XCTAssertEqual(top.app.activations, 0)
        XCTAssertEqual(left.app.activations, 0)

        // The second is checked, 0.12 s after it was made.
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(left.app.activations, 1)

        mac.settle()
        XCTAssertEqual(left.app.activations, 2)
        XCTAssertEqual(top.app.activations, 0)
        XCTAssertEqual(top.raises, 1)
        XCTAssertEqual(mac.system.focusRequests, [top.id, left.id])
        XCTAssertTrue(keyWindow === bottom)
        XCTAssertEqual(mac.focused, bottom.id, "none of it took, and the window manager knows")
    }

    func testAFocusCommandGivenAgainIsCheckedFromItsOwnTime() {
        let (left, right) = sideBySide()
        mac.system.focusSticks = false

        // Left, right and left again, faster than one of them can be confirmed.
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(mac.wm.run(.focus(.right)), "ok")
        mac.scheduler.advance(by: 0.03)
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertEqual(left.raises, 2)

        // 0.12 s after the first request, which was for the same window as the third.
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(left.app.activations, 0, "the check of the first request does not speak for the third")

        // 0.12 s after the third.
        mac.scheduler.advance(by: 0.08)
        XCTAssertEqual(left.app.activations, 1, "it is tried again when its own time is up")

        mac.settle()
        XCTAssertEqual(left.app.activations, 2, "and twice at most")
        XCTAssertEqual(left.raises, 4)
        XCTAssertEqual(right.raises, 1)
        XCTAssertEqual(right.app.activations, 0)
        XCTAssertEqual(mac.focused, right.id)
    }

    func testAWindowThatClosesJustAfterItTookTheFocusIsLetGo() {
        let (left, right) = sideBySide()
        let safari = left.app
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertTrue(keyWindow === left)

        mac.scheduler.advance(by: 0.05)
        mac.system.close(left)
        mac.settle()

        XCTAssertEqual(safari.activations, 0)
        XCTAssertEqual(mac.system.focusRequests, [left.id], "nothing was asked for in its place")
        XCTAssertEqual(right.raises, 0)
        XCTAssertEqual(mac.focused, right.id, "the window that is left")
    }

    func testAWindowThatClosesWhileItsFocusIsBeingConfirmedIsLetGo() {
        let (left, right) = sideBySide()
        let safari = left.app
        mac.system.focusSticks = false
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertEqual(mac.focused, left.id)

        mac.system.close(left)
        mac.settle()

        XCTAssertEqual(safari.activations, 0, "its app was not brought forward for a window that is gone")
        XCTAssertEqual(left.raises, 1, "and it was not asked again")
        XCTAssertEqual(mac.focused, right.id)

        // The window manager follows the keyboard again.
        mac.system.focusSticks = true
        let third = open("Mail")
        XCTAssertEqual(mac.focused, third.id)
    }
}

/// `mouse-follows-focus`: the pointer goes where the focus goes.
final class MouseFollowsFocusScenarioTests: FocusScenarioTestCase {
    private var told: [CGPoint] = []

    override func makeScenario() -> Scenario {
        Scenario(config: "[layout]\nmouse-follows-focus = true\n")
    }

    override func setUp() {
        super.setUp()
        told = []
        mac.wm.onPointerWarp = { [unowned self] in self.told.append($0) }
    }

    func testThePointerGoesToTheMiddleOfTheFocusedWindow() {
        let (left, right) = sideBySide()
        XCTAssertTrue(mac.system.warps.isEmpty, "a window that opens does not pull the pointer to it")

        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.system.warps, [middle(of: left)])
        XCTAssertEqual(mac.system.pointerLocation, CGPoint(x: 362, y: 462.5))
        XCTAssertEqual(told, [middle(of: left)], "whoever listens to the pointer is told Iguana moved it")

        XCTAssertEqual(mac.run("focus right"), "ok")
        XCTAssertEqual(mac.system.warps, [middle(of: left), middle(of: right)])
        XCTAssertEqual(mac.run("focus right"), "ok: nothing in that direction")
        XCTAssertEqual(mac.system.warps.count, 2, "no focus, no move")
    }

    func testThePointerGoesToAFloatingWindowWhereItIs() {
        let (left, _) = sideBySide()
        let floating = open("Calculator", bundleID: "com.apple.calculator", frame: CGRect(x: 500, y: 300, width: 400, height: 300))

        XCTAssertEqual(mac.run("focus left"), "ok")
        XCTAssertEqual(mac.run("focus right"), "ok")

        XCTAssertEqual(mac.focused, floating.id)
        XCTAssertEqual(mac.system.warps, [middle(of: left), CGPoint(x: 700, y: 450)])
    }

    func testThePointerIsNotMovedWhenTheFocusFollowsIt() {
        let (left, _) = sideBySide()
        mac.system.pointerLocation = CGPoint(x: 100, y: 100)

        // `focus-follows-mouse` found the pointer resting on the left window.
        mac.wm.focusFromPointer(left.id)
        mac.settle()

        XCTAssertEqual(mac.focused, left.id)
        XCTAssertTrue(keyWindow === left)
        XCTAssertTrue(mac.system.warps.isEmpty, "the pointer is where the user wants it already")
        XCTAssertEqual(mac.system.pointerLocation, CGPoint(x: 100, y: 100))
        XCTAssertTrue(told.isEmpty)
    }

    func testThePointerIsNotMovedAgainWhenAnotherWindowTookTheKeyboard() {
        let (left, _) = sideBySide()
        let middle = middle(of: left)
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertEqual(mac.system.warps, [middle])

        // The user has moved the pointer on when a new window takes the keyboard.
        mac.scheduler.advance(by: 0.05)
        mac.system.pointerLocation = CGPoint(x: 1000, y: 500)
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertTrue(keyWindow === mail)
        XCTAssertEqual(mac.system.warps, [middle], "neither back to the window that was asked for, nor on to the new one")
        XCTAssertEqual(mac.system.pointerLocation, CGPoint(x: 1000, y: 500))
        XCTAssertEqual(told.count, 1)
    }

    func testARetryDoesNotMoveThePointerAgain() {
        let (left, _) = sideBySide()
        mac.system.focusSticks = false
        XCTAssertEqual(mac.wm.run(.focus(.left)), "ok")
        XCTAssertEqual(mac.system.warps, [middle(of: left)])

        // The user moves the pointer away while the focus is still being tried.
        mac.system.pointerLocation = CGPoint(x: 1000, y: 500)
        mac.scheduler.advance(by: 0.12)
        mac.scheduler.advance(by: 0.12)
        mac.settle()

        XCTAssertEqual(left.app.activations, 2, "it was tried again twice")
        XCTAssertEqual(mac.system.warps.count, 1)
        XCTAssertEqual(mac.system.pointerLocation, CGPoint(x: 1000, y: 500))
        XCTAssertEqual(told.count, 1)
    }
}
