import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

private extension Scenario {
    /// Send a command and stop there, before anything it has put off is done. `run(_:)` lets
    /// everything settle, which hides what happens on the way.
    func send(_ text: String) -> String {
        do {
            let request = try Command.parseRequest(text)
            return wm.run(request.command, window: request.window)
        } catch {
            return "error: \(error)"
        }
    }
}

/// Native Spaces: each desktop keeps a layout of its own, and `space` and `move-to-space` go
/// between them.
final class SpaceScenarioTests: ScenarioTestCase {
    private var display: FakeDisplay { mac.system.displayList[0] }
    private var one: FakeSpace { display.spaces[0] }

    /// A second display to the right of the first, with desktops of its own.
    private func plugInSecondDisplay(desktops: Int = 1) -> FakeDisplay {
        let second = mac.system.addDisplay("LG", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), desktops: desktops)
        mac.settle()
        return second
    }

    /// Open a window and let it take its tile.
    @discardableResult
    private func open(_ app: FakeApp, on space: FakeSpace? = nil) -> FakeWindow {
        let window = mac.system.open(app, on: space)
        mac.settle()
        return window
    }

    private var mouseDowns: [CGPoint] { mac.system.posted.filter { $0.type == .leftMouseDown }.map(\.point) }

    // MARK: A layout for each desktop

    func testEachDesktopKeepsALayoutOfItsOwn() {
        let two = mac.system.addDesktop(to: display)
        let terminal = mac.system.launch("Terminal")
        let left = open(terminal)
        let right = open(terminal)

        mac.system.show(two, on: display)
        mac.settle()
        XCTAssertTrue(mac.tiles.isEmpty, "nothing is tiled on an empty desktop")
        let alone = open(mac.system.launch("Notes"))

        XCTAssertFrame(alone.rect, mac.usable(), "the only window on desktop 2 has all of it")
        XCTAssertFrame(left.rect, CGRect(x: 8, y: 33, width: 708, height: 859), "desktop 1 was not touched")
        XCTAssertFrame(right.rect, CGRect(x: 724, y: 33, width: 708, height: 859))

        mac.system.show(one, on: display)
        mac.settle()
        XCTAssertEqual(mac.tiledInReadingOrder, [left.id, right.id])
        XCTAssertFrame(alone.rect, mac.usable(), "and desktop 2 keeps its own")

        mac.system.show(two, on: display)
        mac.settle()
        XCTAssertEqual(mac.tiledInReadingOrder, [alone.id])
    }

    func testAWindowOnADesktopThatIsNotShowingIsLeftWhereItIs() {
        let two = mac.system.addDesktop(to: display)
        let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let window = mac.system.open(mac.system.launch("Notes"), frame: frame, on: two)
        mac.settle()

        XCTAssertEqual(window.rect, frame)
        XCTAssertTrue(window.positionsAsked.isEmpty && window.sizesAsked.isEmpty, "it was never touched")
        XCTAssertTrue(mac.tiles.isEmpty)

        mac.system.show(two, on: display)
        mac.settle()
        XCTAssertFrame(window.rect, mac.usable(), "it is tiled once its desktop is shown")
    }

    func testAFullscreenSpaceIsLeftAlone() {
        let full = mac.system.addFullscreenSpace(to: display)
        let window = open(mac.system.launch("Safari"))
        XCTAssertFrame(window.rect, mac.usable())

        // The window goes fullscreen: macOS gives it a Space of its own and the whole display.
        window.fullscreen = true
        window.rect = display.frame
        mac.system.put(window, on: full)
        mac.system.show(full, on: display)
        mac.settle()

        XCTAssertEqual(window.rect, display.frame)
        XCTAssertTrue(mac.tiles.isEmpty)
        XCTAssertTrue(mac.run("tree").contains("fullscreen Space (not managed)"))
        XCTAssertTrue(mac.run("list-spaces").contains("showing a fullscreen Space"))

        // Back out of fullscreen, onto the desktop it came from.
        window.fullscreen = false
        mac.system.put(window, on: one)
        mac.system.show(one, on: display)
        mac.settle()
        XCTAssertFrame(window.rect, mac.usable(), "it has its tile again")
    }

    func testAWindowOnScreenThatBelongsToAnotherSpaceIsNotAdopted() {
        // While macOS slides from one Space to the next, the windows of both are on screen.
        // The made-up Mac has no slide. What it can show is the same thing seen from the
        // window manager: a window on screen, over a display that shows a Space it is not on.
        let second = plugInSecondDisplay()
        let frame = CGRect(x: 200, y: 100, width: 600, height: 400)
        let window = mac.system.open(mac.system.launch("Notes"), frame: frame, on: second.currentSpace)
        mac.settle()

        XCTAssertEqual(window.rect, frame, "left alone")
        XCTAssertTrue(mac.tiles.isEmpty)

        // It lives on the desktop it is seen on after all.
        mac.system.put(window, on: one)
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertFrame(window.rect, mac.usable())
    }

    // MARK: space

    func testSpaceGoesToADesktopByNumberOrToTheOneBeside() {
        let two = mac.system.addDesktop(to: display)
        let three = mac.system.addDesktop(to: display)

        XCTAssertEqual(mac.run("space 3"), "ok")
        XCTAssertEqual(mac.system.pressed, [Private.SystemShortcut.desktop(3)])
        XCTAssertEqual(display.currentSpace.id, three.id)

        XCTAssertEqual(mac.run("space prev"), "ok")
        XCTAssertEqual(mac.system.pressed.last, Private.SystemShortcut.spaceLeft)
        XCTAssertEqual(display.currentSpace.id, two.id)

        XCTAssertEqual(mac.run("space next"), "ok")
        XCTAssertEqual(mac.system.pressed.last, Private.SystemShortcut.spaceRight)
        XCTAssertEqual(display.currentSpace.id, three.id)
        XCTAssertEqual(mac.system.pressed.count, 3)
    }

    func testSpaceSaysWhenItDoesNotGo() {
        mac.system.addDesktop(to: display)

        XCTAssertEqual(mac.run("space 1"), "ok: already on desktop 1")
        XCTAssertEqual(mac.run("space 3"), "error: there are only 2 desktops")
        XCTAssertEqual(mac.run("space recent"), "ok: no previous desktop")
        XCTAssertTrue(mac.system.pressed.isEmpty, "no shortcut was pressed for any of them")

        // A Mission Control shortcut that does not fire.
        mac.system.shortcutsWork = false
        XCTAssertEqual(mac.run("space 2"), "error: could not trigger the system shortcut")
        XCTAssertEqual(mac.run("space next"), "error: could not trigger the system shortcut")
        XCTAssertEqual(display.currentSpace.id, one.id)
    }

    func testSpaceRecentGoesBackToTheDesktopShownBefore() {
        let two = mac.system.addDesktop(to: display)
        let three = mac.system.addDesktop(to: display)
        mac.run("space 3")

        XCTAssertEqual(mac.run("space recent"), "ok")
        XCTAssertEqual(mac.system.pressed.last, Private.SystemShortcut.desktop(1))
        XCTAssertEqual(display.currentSpace.id, one.id)

        XCTAssertEqual(mac.run("space recent"), "ok")
        XCTAssertEqual(display.currentSpace.id, three.id, "twice is back where you started")

        // However the desktop changed: a swipe counts as much as a command.
        mac.system.show(two, on: display)
        mac.settle()
        XCTAssertEqual(mac.run("space recent"), "ok")
        XCTAssertEqual(display.currentSpace.id, three.id)
    }

    func testSpaceRecentFromAFullscreenSpaceGoesToTheLastDesktop() {
        let two = mac.system.addDesktop(to: display)
        let full = mac.system.addFullscreenSpace(to: display)
        mac.system.show(two, on: display)
        mac.settle()
        mac.system.show(full, on: display)
        mac.settle()

        XCTAssertEqual(mac.run("space recent"), "ok")
        XCTAssertEqual(mac.system.pressed, [Private.SystemShortcut.desktop(2)], "a fullscreen Space is not a desktop to go back from")
        XCTAssertEqual(display.currentSpace.id, two.id)

        // A desktop can be named from a fullscreen Space too.
        mac.system.show(full, on: display)
        mac.settle()
        XCTAssertEqual(mac.run("space 1"), "ok")
        XCTAssertEqual(display.currentSpace.id, one.id)
    }

    func testDesktopsAreNumberedAcrossTheDisplays() {
        mac.system.addDesktop(to: display)
        let second = plugInSecondDisplay(desktops: 2)
        let four = second.spaces[1]
        // The pointer is on the second display, and no window has the focus.
        mac.system.pointerLocation = CGPoint(x: 2000, y: 500)

        XCTAssertEqual(mac.run("space 3"), "ok: already on desktop 3")
        XCTAssertEqual(mac.run("space 5"), "error: there are only 4 desktops")
        XCTAssertEqual(mac.run("space 4"), "ok")
        XCTAssertEqual(mac.system.pressed, [Private.SystemShortcut.desktop(4)])
        XCTAssertEqual(second.currentSpace.id, four.id)
        XCTAssertEqual(display.currentSpace.id, one.id, "the other display stays on its desktop")
        XCTAssertEqual(mac.run("list-spaces"), """
            Display 1, Built-in Display: showing desktop 1 of 4; this display has 2 desktop(s)
            Display 2, LG: showing desktop 4 of 4; this display has 2 desktop(s)
            """)

        // A focused window says which display is meant, wherever the pointer is.
        open(mac.system.launch("Notes"))
        XCTAssertEqual(mac.run("space 1"), "ok: already on desktop 1")
    }

    // MARK: move-to-space, the quick route

    func testMoveToSpaceTakesTheWindowAndGoesWithIt() {
        let two = mac.system.addDesktop(to: display)
        let terminal = mac.system.launch("Terminal")
        let stays = open(terminal)
        let goes = open(terminal)

        XCTAssertEqual(mac.run("move-to-space 2"), "ok")

        XCTAssertEqual(mac.system.moveRequests.map(\.window), [goes.id])
        XCTAssertEqual(mac.system.moveRequests.map(\.space), [two.id])
        XCTAssertEqual(goes.spaces, [two.id])
        XCTAssertEqual(mac.system.pressed, [Private.SystemShortcut.desktop(2)])
        XCTAssertEqual(display.currentSpace.id, two.id, "the desktop went with it")
        XCTAssertFrame(goes.rect, mac.usable(), "it has desktop 2 to itself")
        XCTAssertEqual(mac.focused, goes.id)
        XCTAssertTrue(mac.system.posted.isEmpty, "nothing was dragged")

        mac.system.show(one, on: display)
        mac.settle()
        XCTAssertEqual(mac.tiledInReadingOrder, [stays.id])
        XCTAssertFrame(stays.rect, mac.usable(), "the window left behind takes the room")
    }

    func testMoveToSpaceStayHandsTheKeyboardToTheNearestWindowLeft() {
        let two = mac.system.addDesktop(to: display)
        let terminal = mac.system.launch("Terminal")
        let left = open(terminal)
        let above = open(terminal)
        let goes = open(terminal)
        XCTAssertEqual(goes.rect.minY, above.rect.maxY + 8, accuracy: 1, "the third window opened below the second")

        XCTAssertEqual(mac.run("move-to-space 2 --stay"), "ok")

        XCTAssertEqual(goes.spaces, [two.id])
        XCTAssertTrue(mac.system.pressed.isEmpty, "no desktop was switched")
        XCTAssertEqual(display.currentSpace.id, one.id)
        XCTAssertEqual(mac.focused, above.id, "the window that was right above it, not the one across the desktop")
        XCTAssertEqual(mac.tiledInReadingOrder, [left.id, above.id])
        XCTAssertFrame(above.rect, CGRect(x: 724, y: 33, width: 708, height: 859), "which takes the room it left")

        mac.system.show(two, on: display)
        mac.settle()
        XCTAssertFrame(goes.rect, mac.usable(), "it joins the layout there when that desktop is shown")
    }

    func testMoveToSpaceNextAndPrevStopAtTheEnds() {
        let two = mac.system.addDesktop(to: display)
        let window = open(mac.system.launch("Notes"))

        XCTAssertEqual(mac.run("move-to-space prev"), "ok: no desktop in that direction")
        XCTAssertEqual(mac.run("move-to-space next"), "ok")
        XCTAssertEqual(window.spaces, [two.id])
        XCTAssertEqual(display.currentSpace.id, two.id)
        XCTAssertEqual(mac.run("move-to-space next"), "ok: no desktop in that direction")

        XCTAssertEqual(mac.run("move-to-space prev --stay"), "ok")
        XCTAssertEqual(window.spaces, [one.id])
        XCTAssertEqual(display.currentSpace.id, two.id, "sent back, and you stay")
        XCTAssertNil(mac.focused, "no window is left here to have the keyboard")
        XCTAssertEqual(mac.run("move-to-space prev"), "error: no focused window")
    }

    func testMoveToSpaceRecentTakesTheWindowBackToTheDesktopBefore() {
        mac.system.addDesktop(to: display)
        let three = mac.system.addDesktop(to: display)
        let other = open(mac.system.launch("Terminal"))
        XCTAssertEqual(mac.run("move-to-space recent"), "ok: no previous desktop")

        mac.run("space 3")
        let window = open(mac.system.launch("Notes"))
        XCTAssertEqual(window.spaces, [three.id])

        XCTAssertEqual(mac.run("move-to-space recent"), "ok")
        XCTAssertEqual(window.spaces, [one.id])
        XCTAssertEqual(display.currentSpace.id, one.id)
        XCTAssertEqual(Set(mac.tiles.keys), [other.id, window.id], "it joins the layout it came to")
        XCTAssertEqual(mac.focused, window.id)
    }

    func testMoveToSpaceSaysWhenThereIsNothingToDo() {
        let two = mac.system.addDesktop(to: display)
        XCTAssertEqual(mac.run("move-to-space 2"), "error: no focused window")

        let window = open(mac.system.launch("Notes"))
        XCTAssertEqual(mac.run("move-to-space 1"), "ok: already on desktop 1")
        XCTAssertEqual(mac.run("move-to-space 3"), "error: there are only 2 desktops")
        XCTAssertEqual(mac.run("move-to-space 2 --window 999"), "error: no window 999")
        XCTAssertEqual(window.spaces, [one.id])

        // Assigned to all desktops in the Dock: it is on desktop 2 as much as on this one.
        window.spaces = [one.id, two.id]
        XCTAssertEqual(mac.run("move-to-space 2 --window \(window.id)"), "ok: already on desktop 2")

        XCTAssertTrue(mac.system.moveRequests.isEmpty)
        XCTAssertFrame(window.rect, mac.usable())
    }

    func testAFullscreenWindowCannotBeSentToAnotherDesktop() {
        mac.system.addDesktop(to: display)
        let full = mac.system.addFullscreenSpace(to: display)
        let window = open(mac.system.launch("Safari"))
        window.fullscreen = true
        window.rect = display.frame
        mac.system.put(window, on: full)
        mac.system.show(full, on: display)
        mac.settle()

        XCTAssertEqual(mac.run("move-to-space 2"), "error: a fullscreen window cannot be sent to another desktop")

        // Named from a desktop, while its fullscreen Space is not being shown.
        mac.system.show(one, on: display)
        mac.settle()
        XCTAssertEqual(mac.run("move-to-space 2 --window \(window.id)"), "error: a fullscreen window cannot be sent to another desktop")
        XCTAssertTrue(mac.system.moveRequests.isEmpty)
        XCTAssertEqual(window.spaces, [full.id])
    }

    func testADesktopOnAnotherDisplayGetsTheWindowOnThatDisplayFirst() {
        mac.system.addDesktop(to: display)
        let second = plugInSecondDisplay(desktops: 2)
        let three = second.spaces[0], four = second.spaces[1]
        let window = open(mac.system.launch("Notes"))
        XCTAssertFrame(window.rect, mac.usable(display))

        XCTAssertEqual(mac.run("move-to-space 4 --stay"), "ok")

        XCTAssertEqual(window.rect.origin, mac.usable(second).origin, "a window has to sit on the display its desktop belongs to")
        XCTAssertEqual(window.spaces, [four.id])
        XCTAssertEqual(second.currentSpace.id, three.id, "neither display changed desktop")
        XCTAssertEqual(display.currentSpace.id, one.id)
        XCTAssertTrue(mac.tiles.isEmpty)

        mac.system.show(four, on: second)
        mac.settle()
        XCTAssertFrame(window.rect, mac.usable(second), "tiled on the second display when its desktop shows")
    }

    func testGoingWithAWindowToADesktopOnAnotherDisplay() {
        let second = plugInSecondDisplay(desktops: 2)
        let three = second.spaces[1]
        let window = open(mac.system.launch("Notes"))
        let before = mac.system.focusRequests.count

        XCTAssertEqual(mac.send("move-to-space 3"), "ok")
        mac.scheduler.advance(by: 1)

        XCTAssertEqual(second.currentSpace.id, three.id, "the other display went to the desktop")
        XCTAssertEqual(display.currentSpace.id, one.id, "this one stays on its own")
        XCTAssertEqual(window.spaces, [three.id])
        XCTAssertFrame(window.rect, mac.usable(second))
        XCTExpectFailure("the focus waits for this display to leave its desktop, which it never does: 3 s pass first (WindowManager+Spaces.swift:106)") {
            XCTAssertEqual(mac.system.focusRequests.count, before + 1, "focused as soon as its desktop shows")
        }

        mac.settle()
        XCTAssertEqual(mac.system.focusRequests.last, window.id, "it is focused in the end")
        XCTAssertEqual(mac.focused, window.id)
    }

    func testMoveToSpaceWithAWindowIDSendsAWindowFromADesktopNotBeingShown() {
        let two = mac.system.addDesktop(to: display)
        let three = mac.system.addDesktop(to: display)
        let here = open(mac.system.launch("Terminal"))
        let away = open(mac.system.launch("Notes"), on: two)

        // Next is counted from the desktop the window is on, not from the one being shown.
        XCTAssertEqual(mac.run("move-to-space next --stay --window \(away.id)"), "ok")
        XCTAssertEqual(away.spaces, [three.id])
        XCTAssertEqual(display.currentSpace.id, one.id)
        XCTAssertEqual(mac.focused, here.id, "the focus stays where it is")
        XCTAssertFrame(here.rect, mac.usable())
        XCTAssertTrue(mac.system.pressed.isEmpty)

        // Brought to the desktop being shown: there is no desktop to go to, and it takes the focus.
        XCTAssertEqual(mac.run("move-to-space 1 --window \(away.id)"), "ok")
        XCTAssertEqual(away.spaces, [one.id])
        XCTAssertTrue(mac.system.pressed.isEmpty)
        XCTAssertEqual(mac.tiledInReadingOrder, [here.id, away.id], "it joins the layout beside the window that was there")
        XCTAssertEqual(mac.focused, away.id)
    }

    // MARK: move-to-space, carried by hand

    func testWithoutTheBridgeTheWindowIsCarriedByItsTitleBar() {
        mac.system.hasMoveBridge = false
        let two = mac.system.addDesktop(to: display)
        let terminal = mac.system.launch("Terminal")
        let stays = open(terminal)
        let goes = open(terminal)
        let pointer = CGPoint(x: 300, y: 600)
        mac.system.pointerLocation = pointer
        // Between the close and the minimise button, where no app puts a control.
        let hold = CGPoint(x: goes.rect.minX + 26, y: goes.rect.minY + 14)

        XCTAssertEqual(mac.send("move-to-space 2"), "ok")
        XCTAssertEqual(mac.system.posted.first?.type, .mouseMoved)
        XCTAssertEqual(mouseDowns, [hold])
        XCTAssertTrue(mac.system.pressed.isEmpty, "the desktop is not switched before the window follows the pointer")
        XCTAssertEqual(mac.send("move-to-space 1"), "error: a move is already in progress")

        mac.scheduler.advance(by: 0.3)
        XCTAssertEqual(mac.system.pressed, [Private.SystemShortcut.desktop(2)])
        XCTAssertEqual(display.currentSpace.id, two.id)
        XCTAssertTrue(mac.system.leftMouseIsDown, "held while the desktop slides across")

        mac.settle()
        XCTAssertFalse(mac.system.leftMouseIsDown)
        XCTAssertEqual(mac.system.posted.last?.type, .leftMouseUp)
        XCTAssertEqual(mac.system.pointerLocation, pointer, "the pointer is put back")
        XCTAssertEqual(goes.spaces, [two.id])
        XCTAssertFrame(goes.rect, mac.usable(), "tiled on desktop 2")
        XCTAssertEqual(mac.focused, goes.id)
        XCTAssertEqual(mac.logged("move-to-space:"), ["move-to-space: the quick route did not move window \(goes.id), falling back to dragging it"])

        mac.system.show(one, on: display)
        mac.settle()
        XCTAssertEqual(mac.tiledInReadingOrder, [stays.id])
        XCTAssertFrame(stays.rect, mac.usable())
    }

    func testAWindowTheBridgeDoesNotMoveIsCarriedInstead() {
        mac.system.bridgeMovesWindows = false
        let two = mac.system.addDesktop(to: display)
        // A window that is not on screen cannot be carried by hand, so that one is refused.
        let away = open(mac.system.launch("Mail"), on: two)
        XCTAssertEqual(mac.run("move-to-space 1 --window \(away.id)"), "error: the system did not move the window")
        XCTAssertEqual(away.spaces, [two.id])
        XCTAssertTrue(mac.system.posted.isEmpty, "the mouse was not used")

        let window = open(mac.system.launch("Notes"))

        XCTAssertEqual(mac.run("move-to-space 2 --stay"), "ok")

        XCTAssertEqual(mac.system.moveRequests.map(\.window), [away.id, window.id], "the bridge was asked first")
        XCTAssertEqual(mouseDowns.count, 1, "then the window was taken by hand")
        XCTAssertEqual(window.spaces, [two.id])
        XCTAssertEqual(display.currentSpace.id, two.id, "carrying a window always ends on its desktop, --stay or not")
        XCTAssertEqual(Set(mac.tiles.keys), [away.id, window.id], "where it joins the layout")
        XCTAssertEqual(mac.logged("falling back to dragging it").count, 1)
    }

    func testAWindowThatCannotBeHeldStaysWhereItIs() {
        mac.system.hasMoveBridge = false
        mac.system.addDesktop(to: display)
        let terminal = mac.system.launch("Terminal")
        open(terminal)
        let window = open(terminal)
        let tile = window.rect
        let pointer = mac.system.pointerLocation
        // Its whole title bar is taken up by controls of its own.
        window.canBeDraggedAt = { _ in false }

        XCTAssertEqual(mac.run("move-to-space 2"), "ok", "the command has answered before the window is tried")

        XCTAssertEqual(mouseDowns.count, 5, "every spot was tried")
        XCTAssertEqual(mac.logged("move-to-space:").last, "move-to-space: could not take hold of window \(window.id) by its title bar, so it stays where it is")
        XCTAssertTrue(mac.system.pressed.isEmpty)
        XCTAssertEqual(display.currentSpace.id, one.id)
        XCTAssertEqual(window.spaces, [one.id])
        XCTAssertFrame(window.rect, tile)
        XCTAssertFalse(mac.system.leftMouseIsDown)
        XCTAssertEqual(mac.system.pointerLocation, pointer)
        XCTAssertEqual(mac.run("move-to-space 1"), "ok: already on desktop 1", "and another move can be asked for")
    }

    func testAShortcutThatDoesNotFireLeavesTheCarriedWindowOnItsTile() {
        mac.system.hasMoveBridge = false
        mac.system.shortcutsWork = false
        mac.system.addDesktop(to: display)
        let terminal = mac.system.launch("Terminal")
        open(terminal)
        let window = open(terminal)
        let tile = window.rect

        XCTAssertEqual(mac.send("move-to-space 2"), "ok")
        mac.scheduler.advance(by: 0.25)
        XCTAssertFalse(mac.system.leftMouseIsDown, "let go at once, not held for a desktop that will not come")
        XCTAssertNotEqual(window.rect.origin, tile.origin, "taking hold of it moved it a little")

        mac.settle()
        XCTAssertEqual(mac.logged("move-to-space:").last, "move-to-space: could not trigger the system shortcut, so window \(window.id) stays where it is")
        XCTAssertEqual(window.spaces, [one.id])
        XCTAssertEqual(display.currentSpace.id, one.id)
        XCTAssertFrame(window.rect, tile, "back on its tile")
    }

    func testACarriedWindowIsLetGoWhenTheDesktopHasNotChangedAfterEightSeconds() {
        // The one way the made-up Mac takes a shortcut and keeps the desktop: the desktop asked
        // for is already being shown, on the other display.
        mac.system.hasMoveBridge = false
        _ = plugInSecondDisplay()
        let window = open(mac.system.launch("Notes"))
        let pointer = mac.system.pointerLocation

        XCTAssertEqual(mac.send("move-to-space 2"), "ok")
        mac.scheduler.advance(by: 0.3)
        XCTAssertEqual(mac.system.pressed, [Private.SystemShortcut.desktop(2)])

        mac.scheduler.advance(by: 7.5)
        XCTAssertTrue(mac.system.leftMouseIsDown, "still holding on")
        XCTAssertEqual(mac.send("move-to-space 1"), "error: a move is already in progress")
        XCTAssertTrue(mac.logged("the desktop did not change").isEmpty)

        mac.scheduler.advance(by: 1)
        XCTAssertFalse(mac.system.leftMouseIsDown)
        XCTAssertEqual(mac.logged("move-to-space:").last, "move-to-space: the desktop did not change, so window \(window.id) stays where it is")
        XCTAssertEqual(mac.system.pointerLocation, pointer)

        mac.settle()
        XCTAssertEqual(mac.run("move-to-space 3"), "error: there are only 2 desktops", "the next move is listened to again")
    }

    func testACarriedWindowIsLetGoOnceTheOtherDisplayShowsItsDesktop() {
        mac.system.hasMoveBridge = false
        let second = plugInSecondDisplay(desktops: 2)
        let three = second.spaces[1]
        let window = open(mac.system.launch("Notes"))

        XCTAssertEqual(mac.send("move-to-space 3"), "ok")
        mac.scheduler.advance(by: 2)

        XCTAssertEqual(second.currentSpace.id, three.id)
        XCTAssertEqual(window.spaces, [three.id], "the window came along")
        XCTExpectFailure("it waits for this display to leave its desktop, which it never does, so the button is held for 8 s and the move is logged as failed (WindowManager+Spaces.swift:128)") {
            XCTAssertFalse(mac.system.leftMouseIsDown, "let go once the desktop has changed")
        }

        mac.settle()
        XCTAssertFalse(mac.system.leftMouseIsDown)
        XCTAssertFrame(window.rect, mac.usable(second), "tiled on the desktop it was carried to")
        XCTExpectFailure("the window is on desktop 3, and the log says it stayed (WindowManager+Spaces.swift:128)") {
            XCTAssertTrue(mac.logged("the desktop did not change").isEmpty)
        }
    }
}
