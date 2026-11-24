import XCTest
@testable import IguanaCore

/// `focus-follows-mouse`: which window the resting pointer gives the focus to, and when it
/// gives it to none.
final class PointerFocusTests: XCTestCase {
    typealias Surface = PointerFocus.Surface
    typealias Scene = PointerFocus.Scene

    // Two tiles side by side under a menu bar, with a Dock below them.
    let screen = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    let usable = CGRect(x: 0, y: 38, width: 1500, height: 890)
    let left = Surface(id: 1, frame: CGRect(x: 8, y: 46, width: 738, height: 874), kind: .window)
    let right = Surface(id: 2, frame: CGRect(x: 754, y: 46, width: 738, height: 874), kind: .window)
    let onLeft = CGPoint(x: 300, y: 400)
    let onRight = CGPoint(x: 1100, y: 400)

    /// What is on screen, with the click landing on whatever the list says is in front,
    /// unless a test says that the window server knows better.
    func scene(_ surfaces: [Surface], at point: CGPoint, focused: WindowID?, buttonsDown: Bool = false, hit: WindowID?? = nil) -> Scene {
        let front = surfaces.first { $0.frame.contains(point) }?.id
        return Scene(surfaces: surfaces, areas: [usable], hit: hit ?? front, buttonsDown: buttonsDown, focused: focused)
    }

    func target(_ surfaces: [Surface], at point: CGPoint, focused: WindowID?, buttonsDown: Bool = false, hit: WindowID?? = nil) -> WindowID? {
        PointerFocus.target(at: point, in: scene(surfaces, at: point, focused: focused, buttonsDown: buttonsDown, hit: hit))
    }

    /// A pointer that has been moved well clear of where it lay and has now come to rest.
    func rest(_ tracker: inout PointerFocus, from start: CGPoint, at point: CGPoint, _ surfaces: [Surface], focused: WindowID?) -> WindowID? {
        _ = tracker.moved(to: start, focused: focused)
        XCTAssertTrue(tracker.moved(to: point, focused: focused))
        return tracker.rested(at: point, scene: scene(surfaces, at: point, focused: focused))
    }

    // MARK: What is under the pointer

    func testTheWindowUnderThePointerGetsTheFocus() {
        XCTAssertEqual(target([left, right], at: onRight, focused: 1), 2)
        XCTAssertEqual(target([right, left], at: onLeft, focused: 2), 1, "the order of the list is not the order on screen")
        XCTAssertNil(target([left, right], at: onLeft, focused: 1), "it has the focus already")
        XCTAssertEqual(target([left, right], at: onRight, focused: nil), 2, "no window had the focus")
    }

    func testNeverWhileAMouseButtonIsDown() {
        XCTAssertNil(target([left, right], at: onRight, focused: 1, buttonsDown: true), "dragging, resizing or selecting")
    }

    func testNeverOverTheMenuBarTheDockOrTheDesktop() {
        // A window that reaches under the menu bar and the Dock, to show that it is the place
        // of the pointer that counts.
        let tall = Surface(id: 2, frame: CGRect(x: 754, y: 0, width: 738, height: 1000), kind: .window)
        XCTAssertEqual(target([left, tall], at: onRight, focused: 1), 2)
        XCTAssertNil(target([left, tall], at: CGPoint(x: 1100, y: 12), focused: 1), "the menu bar")
        XCTAssertNil(target([left, tall], at: CGPoint(x: 1100, y: 960), focused: 1), "the Dock")
        XCTAssertNil(target([left, right], at: CGPoint(x: 750, y: 400), focused: 1), "the gap between the tiles: the desktop")
        XCTAssertNil(target([left, right], at: CGPoint(x: 3, y: 400), focused: 2), "the gap at the edge of the screen")
        XCTAssertNil(target([left, right], at: CGPoint(x: 4000, y: 400), focused: 1), "on no display")
    }

    func testNeverOntoSomethingIguanaDoesNotKnow() {
        let dialog = Surface(id: 7, frame: CGRect(x: 900, y: 300, width: 400, height: 200), kind: .other)
        XCTAssertNil(target([dialog, left, right], at: onRight, focused: 1), "a dialog, a panel, Iguana's own settings window")
        XCTAssertEqual(target([dialog, left, right], at: CGPoint(x: 800, y: 100), focused: 1), 2, "beside the dialog, on the window itself")
        let sheet = Surface(id: 2, frame: right.frame, kind: .other)
        XCTAssertNil(target([left, sheet], at: onRight, focused: 1), "a window Iguana knows that is not a standard one")
    }

    func testNeverOntoAWindowThatIsCoveredAtThatPoint() {
        // A floating window lies over the right tile.
        let floating = Surface(id: 3, frame: CGRect(x: 1000, y: 300, width: 300, height: 300), kind: .window)
        XCTAssertEqual(target([floating, left, right], at: onRight, focused: 1), 3, "the window in front at that point")
        XCTAssertNil(target([floating, left, right], at: onRight, focused: 3), "the one in front has the focus: the tile under it is covered here")
        XCTAssertEqual(target([floating, left, right], at: CGPoint(x: 800, y: 100), focused: 3), 2, "where the tile shows, it is under the pointer")
        let panel = Surface(id: 9, frame: floating.frame, kind: .other)
        XCTAssertNil(target([panel, left, right], at: onRight, focused: 1), "covered by something that takes no focus")
    }

    func testNeverWhileAMenuIsOpen() {
        let menu = Surface(id: 50, frame: CGRect(x: 100, y: 38, width: 240, height: 300), kind: .menu)
        XCTAssertNil(target([menu, left, right], at: CGPoint(x: 150, y: 100), focused: 2), "over the menu")
        XCTAssertNil(target([menu, left, right], at: onLeft, focused: 2), "beside the menu: focusing another window would close it")
        XCTAssertNil(target([menu, left, right], at: onRight, focused: 1))
    }

    func testAClickHasToLandOnThatSameWindow() {
        // The window list only holds ordinary windows. What floats above them it cannot see.
        XCTAssertNil(target([left, right], at: onRight, focused: 1, hit: .some(77)), "a popover, a menu bar item's panel, Mission Control")
        XCTAssertNil(target([left, right], at: onRight, focused: 1, hit: .some(nil)), "the window server does not say")
        XCTAssertNil(target([left, right], at: onRight, focused: 1, hit: .some(1)), "the list and the window server disagree: do nothing")
        XCTAssertEqual(target([left, right], at: onRight, focused: 1, hit: .some(2)), 2)
    }

    // MARK: What happened last

    func testThePointerHasToRestAfterTheUserMovedIt() {
        var tracker = PointerFocus()
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([left, right], at: onRight, focused: 1)), "it never moved")
        XCTAssertEqual(rest(&tracker, from: onLeft, at: onRight, [left, right], focused: 1), 2)
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([left, right], at: onRight, focused: 1)), "one rest, one decision")
    }

    func testAShortcutThatMovesTheFocusIsNotUndoneByThePointerLyingElsewhere() {
        var tracker = PointerFocus()
        XCTAssertEqual(rest(&tracker, from: onLeft, at: onRight, [left, right], focused: 1), 2)
        // `focus left` on the keyboard. The pointer still lies on the right window and has
        // not moved, so nothing asks about it. When something does, the answer is no.
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([left, right], at: onRight, focused: 1)))
    }

    func testAFocusChangeWhileThePointerWasOnItsWayWins() {
        var tracker = PointerFocus()
        _ = tracker.moved(to: onLeft, focused: 1)
        XCTAssertTrue(tracker.moved(to: onRight, focused: 1))
        // Before the pointer has rested, a shortcut gives the focus to a third window.
        let third = Surface(id: 3, frame: CGRect(x: 100, y: 500, width: 300, height: 300), kind: .window)
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([third, left, right], at: onRight, focused: 3)), "the keyboard spoke last")
        // And a twitch of the mouse afterwards does not take it back.
        XCTAssertFalse(tracker.moved(to: CGPoint(x: onRight.x + 1, y: onRight.y), focused: 3))
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([third, left, right], at: onRight, focused: 3)))
    }

    func testAfterTheKeyboardThePointerHasToBeMovedInEarnest() {
        var tracker = PointerFocus()
        XCTAssertEqual(rest(&tracker, from: onLeft, at: onRight, [left, right], focused: 1), 2)
        // The focus goes back to the left window by keyboard. The mouse is bumped by a point or two.
        for nudge in [CGPoint(x: 1101, y: 400), CGPoint(x: 1102, y: 401), CGPoint(x: 1100, y: 402)] {
            XCTAssertFalse(tracker.moved(to: nudge, focused: 1), "less than \(PointerFocus.slack) points is not a move")
        }
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([left, right], at: onRight, focused: 1)))
        // Moved properly, still on the right window: now the pointer means it.
        let moved = CGPoint(x: 1100 + PointerFocus.slack + 1, y: 400)
        XCTAssertTrue(tracker.moved(to: moved, focused: 1))
        XCTAssertEqual(tracker.rested(at: moved, scene: scene([left, right], at: moved, focused: 1)), 2)
    }

    func testThePointerMovedByIguanaIsNotTheUserMovingIt() {
        var tracker = PointerFocus()
        XCTAssertEqual(rest(&tracker, from: onLeft, at: onRight, [left, right], focused: 1), 2)
        // `focus left` with mouse-follows-focus: Iguana puts the pointer on the middle of the
        // left window, which a floating window happens to cover.
        let centre = CGPoint(x: left.frame.midX, y: left.frame.midY)
        let floating = Surface(id: 3, frame: CGRect(x: 300, y: 400, width: 200, height: 200), kind: .window)
        tracker.warped(to: centre)
        XCTAssertFalse(tracker.moved(to: centre, focused: 1), "the system reporting the pointer where Iguana put it")
        XCTAssertNil(tracker.rested(at: centre, scene: scene([floating, left, right], at: centre, focused: 1)), "the floating window does not steal what the shortcut asked for")
        XCTAssertFalse(tracker.moved(to: CGPoint(x: centre.x + 1, y: centre.y), focused: 1), "nor does a twitch")
        // The user takes the mouse and rests it on the floating window.
        let there = CGPoint(x: centre.x + 20, y: centre.y + 20)
        XCTAssertTrue(tracker.moved(to: there, focused: 1))
        XCTAssertEqual(tracker.rested(at: there, scene: scene([floating, left, right], at: there, focused: 1)), 3)
    }

    func testAWarpCancelsARestThatWasDue() {
        var tracker = PointerFocus()
        _ = tracker.moved(to: onLeft, focused: 1)
        XCTAssertTrue(tracker.moved(to: onRight, focused: 1))
        tracker.warped(to: CGPoint(x: 377, y: 483))
        XCTAssertNil(tracker.rested(at: CGPoint(x: 377, y: 483), scene: scene([left, right], at: CGPoint(x: 377, y: 483), focused: 1)))
    }

    func testRestingOnTheFocusedWindowEndsTheMatter() {
        var tracker = PointerFocus()
        _ = tracker.moved(to: onLeft, focused: 1)
        XCTAssertTrue(tracker.moved(to: CGPoint(x: 320, y: 420), focused: 1))
        tracker.stay()
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([left, right], at: onRight, focused: 1)), "nothing is due until the pointer moves again")
    }

    func testAFocusThatDidNotTakeIsAskedForAgainOnlyWhenThePointerMoves() {
        var tracker = PointerFocus()
        XCTAssertEqual(rest(&tracker, from: onLeft, at: onRight, [left, right], focused: 1), 2)
        // macOS left the focus where it was. Nothing happens by itself.
        XCTAssertNil(tracker.rested(at: onRight, scene: scene([left, right], at: onRight, focused: 1)))
        XCTAssertFalse(tracker.moved(to: CGPoint(x: 1101, y: 400), focused: 1))
        let moved = CGPoint(x: 1120, y: 410)
        XCTAssertTrue(tracker.moved(to: moved, focused: 1))
        XCTAssertEqual(tracker.rested(at: moved, scene: scene([left, right], at: moved, focused: 1)), 2)
    }

    func testTheFirstMovementAfterItIsSwitchedOnCountsFromWhereThePointerLay() {
        var tracker = PointerFocus()
        XCTAssertFalse(tracker.moved(to: onRight, focused: 1), "where the pointer lay when the setting was switched on")
        XCTAssertFalse(tracker.moved(to: CGPoint(x: 1101, y: 400), focused: 1))
        XCTAssertTrue(tracker.moved(to: CGPoint(x: 1110, y: 400), focused: 1))
    }

    // MARK: Config

    func testFocusFollowsMouseIsOffUntilAskedFor() throws {
        XCTAssertFalse(Config.default.focusFollowsMouse)
        let (c, warnings) = try Config.load("[layout]\nfocus-follows-mouse = true\n")
        XCTAssertEqual(warnings, [])
        XCTAssertTrue(c.focusFollowsMouse)
        XCTAssertFalse(c.mouseFollowsFocus, "the two settings are separate")
        let (kept, problems) = try Config.load("[layout]\nfocus-follows-mouse = \"always\"\n")
        XCTAssertFalse(kept.focusFollowsMouse)
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(PointerFocus.dwell, 0.08, "about 80 ms, a constant and not a setting")
    }

    func testTheSettingsWindowsEditKeepsTheFile() throws {
        var editor = TOMLEditor(Config.defaultText)
        editor.set(["layout", "focus-follows-mouse"], to: .bool(true))
        XCTAssertEqual(editor.text.components(separatedBy: "\n").count, Config.defaultText.components(separatedBy: "\n").count, "no lines added or lost")
        let line = try XCTUnwrap(editor.text.components(separatedBy: "\n").first { $0.hasPrefix("focus-follows-mouse") })
        XCTAssertTrue(line.hasPrefix("focus-follows-mouse = true"), line)
        XCTAssertTrue(line.hasSuffix("# the window the pointer rests on gets the focus"), "the comment stays: \(line)")
        XCTAssertTrue(try Config.load(editor.text).config.focusFollowsMouse)
    }
}
