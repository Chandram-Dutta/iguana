import XCTest
import IguanaCore
@testable import iguana

// Where floating windows are put: by a rule's `size` and `position` as they open, and by the
// `place` command afterwards.

private extension Scenario {
    /// The moves asked of one window, oldest first.
    func moves(of window: FakeWindow) -> [ImmediateMover.Move] {
        mover.moves.filter { $0.window == window.id }
    }
}

/// The area windows are placed in on the built-in display: inside the outer gap, under the menu bar.
private let area = CGRect(x: 8, y: 33, width: 1424, height: 859)
/// A rule that floats Notes and says nothing about where.
private let floatNotes = """
[[rule]]
app = "Notes"
float = true
"""

// MARK: - Rules

/// A rule's `size` and `position`: a new floating window is placed once, as it opens.
final class PlacementRuleScenarioTests: ScenarioTestCase {
    func testARuleGivesANewFloatingWindowItsSizeAndPlaceAtOnce() {
        mac.writeConfig("""
        [[rule]]
        app = "Notes"
        float = true
        size = [400, 600]
        position = "center"
        """)
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()

        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 640, height: 480))
        mac.settle()

        XCTAssertEqual(notes.rect, CGRect(x: 520, y: 162.5, width: 400, height: 600), "the rule's size, in the middle of the desktop")
        XCTAssertEqual(mac.logged("rule:"), ["rule: placed window \(notes.id) of Notes"])
        XCTAssertEqual(mac.moves(of: notes).map(\.duration), [0], "put there once, and not as a glide")
        XCTAssertEqual(mac.tiles.keys.sorted(), [terminal.id], "it floats")
        XCTAssertFrame(terminal.rect, area)
    }

    func testASizeOnItsOwnKeepsTheCornerTheWindowOpenedAtAsFarAsItFits() {
        mac.writeConfig("""
        [[rule]]
        app = "Notes"
        float = true
        size = [400, 300]
        """)
        let app = mac.system.launch("Notes")
        let inside = mac.system.open(app, frame: CGRect(x: 300, y: 200, width: 640, height: 480))
        mac.settle()
        // This one opens hanging over the right and bottom edges of the display.
        let outside = mac.system.open(app, frame: CGRect(x: 1300, y: 700, width: 640, height: 480))
        mac.settle()

        XCTAssertEqual(inside.rect, CGRect(x: 300, y: 200, width: 400, height: 300))
        XCTAssertEqual(outside.rect, CGRect(x: 1032, y: 592, width: 400, height: 300), "moved in until all of it is on the desktop")
    }

    func testAWindowOfAFixedSizeIsFittedIntoItsPlaceAtTheSizeItHas() {
        mac.writeConfig("""
        [[rule]]
        app = "Calculator"
        float = true
        position = "bottom-right"
        """)
        let calculator = mac.system.open(mac.system.launch("Calculator"), frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        calculator.resizable = false

        // It is first given the corner of the quarter it was to fill.
        mac.scheduler.advance(by: 0.1)
        XCTAssertEqual(calculator.rect, CGRect(x: 724, y: 466.5, width: 300, height: 200))

        // A moment later it is seen not to have taken the size, and goes into the corner of the desktop.
        mac.settle()
        XCTAssertEqual(calculator.rect, CGRect(x: 1132, y: 692, width: 300, height: 200))
        XCTAssertEqual(mac.logged("rule:"), ["rule: placed window \(calculator.id) of Calculator"])
    }

    func testAWindowThatWillNotShrinkKeepsToTheEdgeItsPlaceNames() {
        mac.writeConfig("""
        [[rule]]
        app = "Xcode"
        float = true
        position = "right"
        """)
        let xcode = mac.system.open(mac.system.launch("Xcode"), frame: CGRect(x: 100, y: 100, width: 1000, height: 500))
        xcode.minSize = CGSize(width: 900, height: 300)
        mac.settle()

        XCTAssertEqual(xcode.rect.size, CGSize(width: 900, height: 859), "as narrow as it gets, as tall as the half")
        XCTAssertEqual(xcode.rect.maxX, area.maxX, "its right edge is on the right edge of the desktop")
        XCTAssertEqual(xcode.rect.minY, area.minY)
    }

    func testOnlyAWindowThatOpensAfterTheRuleWasReadIsPlaced() {
        let app = mac.system.launch("Notes")
        let old = mac.system.open(app, title: "Old")
        mac.settle()
        XCTAssertFrame(old.rect, area)

        mac.writeConfig("""
        [[rule]]
        app = "Notes"
        float = true
        position = "top-left"
        """)
        XCTAssertFrame(old.rect, area, "it floats now, where the user had it")
        XCTAssertTrue(mac.logged("rule:").isEmpty)

        let new = mac.system.open(app, title: "New", frame: CGRect(x: 500, y: 300, width: 640, height: 480))
        mac.settle()
        XCTAssertEqual(new.rect, CGRect(x: 8, y: 33, width: 708, height: 425.5))
        XCTAssertEqual(mac.logged("rule:"), ["rule: placed window \(new.id) of Notes"])
    }

    func testAWindowIsPlacedOnTheDisplayItOpenedOn() {
        mac.writeConfig("""
        [[rule]]
        app = "Notes"
        float = true
        position = "left"
        """)
        mac.system.addDisplay("Studio Display", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        mac.settle()

        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 1700, y: 300, width: 640, height: 480))
        mac.settle()

        XCTAssertEqual(notes.rect, CGRect(x: 1448, y: 33, width: 948, height: 1039), "the left half of the Studio Display")
    }
}

// MARK: - place

/// `place`: put a floating window in a part of its display's area.
final class PlaceCommandScenarioTests: ScenarioTestCase {
    func testPlaceFloatsATiledWindowAndGlidesItToItsHalf() {
        let app = mac.system.launch("Terminal")
        let left = mac.system.open(app, title: "One")
        mac.settle()
        let right = mac.system.open(app, title: "Two")
        mac.settle()
        XCTAssertFrame(right.rect, CGRect(x: 724, y: 33, width: 708, height: 859))
        mac.mover.clearRecord()

        XCTAssertEqual(mac.run("place left"), "ok: floating")

        XCTAssertFrame(right.rect, CGRect(x: 8, y: 33, width: 708, height: 859))
        XCTAssertEqual(mac.tiles.keys.sorted(), [left.id], "it left the layout")
        XCTAssertFrame(left.rect, area, "and the other window took its room")
        XCTAssertEqual(mac.moves(of: right).map(\.duration), [mac.wm.config.animationDuration], "it glides as tiled windows do")

        // Placed again, it is floating already.
        XCTAssertEqual(mac.run("place right"), "ok")
        XCTAssertFrame(right.rect, CGRect(x: 724, y: 33, width: 708, height: 859))
    }

    func testEveryPlaceHasItsPartOfTheDesktop() {
        mac.writeConfig(floatNotes)
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 640, height: 480))
        mac.settle()

        XCTAssertEqual(mac.run("place center"), "ok")
        XCTAssertEqual(notes.rect, CGRect(x: 400, y: 222.5, width: 640, height: 480), "the middle, at the size it had")

        // Halves and quarters leave the inner gap of 8 between them.
        let places: [(String, CGRect)] = [
            ("left", CGRect(x: 8, y: 33, width: 708, height: 859)),
            ("right", CGRect(x: 724, y: 33, width: 708, height: 859)),
            ("top", CGRect(x: 8, y: 33, width: 1424, height: 425.5)),
            ("bottom", CGRect(x: 8, y: 466.5, width: 1424, height: 425.5)),
            ("top-left", CGRect(x: 8, y: 33, width: 708, height: 425.5)),
            ("top-right", CGRect(x: 724, y: 33, width: 708, height: 425.5)),
            ("bottom-left", CGRect(x: 8, y: 466.5, width: 708, height: 425.5)),
            ("bottom-right", CGRect(x: 724, y: 466.5, width: 708, height: 425.5)),
            ("full", area),
        ]
        for (name, frame) in places {
            XCTAssertEqual(mac.run("place \(name)"), "ok", name)
            XCTAssertEqual(notes.rect, frame, name)
        }
        XCTAssertTrue(mac.tiles.isEmpty)
    }

    func testPlacesKeepToTheGapsOfTheConfigAndANamedWindowLeavesTheFocusAlone() {
        mac.writeConfig(floatNotes + """

        [gaps]
        inner = 20
        outer = 30
        """)
        let app = mac.system.launch("Notes")
        let first = mac.system.open(app, title: "One", frame: CGRect(x: 100, y: 100, width: 640, height: 480))
        mac.settle()
        let second = mac.system.open(app, title: "Two", frame: CGRect(x: 300, y: 200, width: 640, height: 480))
        mac.settle()
        let asked = mac.system.focusRequests.count

        XCTAssertEqual(mac.run("place left --window \(first.id)"), "ok")
        XCTAssertEqual(mac.run("place right --window \(second.id)"), "ok")

        XCTAssertEqual(first.rect, CGRect(x: 30, y: 55, width: 680, height: 815))
        XCTAssertEqual(second.rect, CGRect(x: 730, y: 55, width: 680, height: 815), "one inner gap away, inside the outer gap")
        XCTAssertEqual(mac.focused, second.id)
        XCTAssertEqual(mac.system.focusRequests.count, asked, "naming a window does not focus it")
    }

    func testATinyMoveIsNotAGlideNorIsAnyMoveWithMotionSwitchedOff() {
        mac.writeConfig(floatNotes)
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 640, height: 480))
        mac.settle()
        mac.run("place left")
        mac.mover.clearRecord()

        // Ten points off its place: too little to be worth a glide.
        notes.rect.origin.x += 10
        mac.run("place left")
        XCTAssertEqual(mac.moves(of: notes).map(\.duration), [0])
        XCTAssertEqual(notes.rect, CGRect(x: 8, y: 33, width: 708, height: 859))

        mac.system.reduceMotion = true
        mac.run("place right")
        XCTAssertEqual(mac.moves(of: notes).map(\.duration), [0, 0], "the Mac is set to reduce motion")

        mac.system.reduceMotion = false
        mac.writeConfig(floatNotes + "\n[animation]\nenabled = false\n")
        mac.run("place left")
        XCTAssertEqual(mac.moves(of: notes).map(\.duration), [0, 0, 0], "the config switches gliding off")
    }

    func testAWindowThatWillNotTakeTheSizeIsMovedAfterASecondLook() {
        mac.writeConfig(floatNotes)
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 1000, height: 500))
        notes.minSize = CGSize(width: 900, height: 300)
        mac.settle()

        XCTAssertEqual(mac.wm.run(.place(.right)), "ok")
        mac.scheduler.advance(by: 0.1)
        // It is where the right half begins, too wide for it: part of it is off the display.
        XCTAssertEqual(notes.rect, CGRect(x: 724, y: 33, width: 900, height: 859))
        XCTAssertEqual(notes.sizesAsked.suffix(2), [CGSize(width: 708, height: 859), CGSize(width: 708, height: 859)], "asked a second time, in case it was only busy")

        mac.scheduler.advance(by: 0.1)
        XCTAssertEqual(notes.rect, CGRect(x: 532, y: 33, width: 900, height: 859), "still too wide, so its right edge is put on the right edge")
        mac.settle()
        XCTAssertEqual(notes.rect.maxX, area.maxX)
    }

    func testAWindowTheUserMovesInTheMeantimeIsLeftWhereTheyPutIt() {
        mac.writeConfig(floatNotes)
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 1000, height: 500))
        notes.minSize = CGSize(width: 900, height: 300)
        mac.settle()

        XCTAssertEqual(mac.wm.run(.place(.right)), "ok")
        mac.scheduler.advance(by: 0.05)
        // Before the second look, the user takes the window somewhere else.
        notes.rect.origin = CGPoint(x: 60, y: 80)
        mac.settle()

        XCTAssertEqual(notes.rect.origin, CGPoint(x: 60, y: 80))
    }

    func testAWindowOfAFixedSizeIsPutAgainstTheEdgesOfItsPlace() {
        // The built-in rules float Calculator.
        let calculator = mac.system.open(mac.system.launch("Calculator", bundleID: "com.apple.calculator"), frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        calculator.resizable = false
        mac.settle()

        XCTAssertEqual(mac.run("place center"), "ok")
        XCTAssertEqual(calculator.rect, CGRect(x: 570, y: 362.5, width: 300, height: 200), "the middle, at the only size it has")
        XCTAssertEqual(mac.run("place bottom-right"), "ok")
        XCTAssertEqual(calculator.rect, CGRect(x: 1132, y: 692, width: 300, height: 200), "in the corner of the desktop, not of the quarter")

        // No rule floats this one. It is not tiled either, because it cannot be resized.
        let fonts = mac.system.open(mac.system.launch("Fonts"), frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        fonts.resizable = false
        mac.settle()

        XCTAssertEqual(mac.run("place bottom-right"), "ok", "it was never tiled, so it is not floated first")
        XCTAssertEqual(fonts.rect, CGRect(x: 1132, y: 692, width: 300, height: 200))
        XCTAssertEqual(mac.run("place right"), "ok")
        XCTAssertEqual(fonts.rect, CGRect(x: 1132, y: 362.5, width: 300, height: 200), "against the right edge, half way down")
        XCTAssertTrue(mac.tiles.isEmpty)
    }

    func testAWindowThatTookTheSizeIsNotLookedAtAgain() {
        mac.writeConfig(floatNotes)
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 640, height: 480))
        mac.settle()

        XCTAssertEqual(mac.run("place right", settle: false), "ok")
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(notes.rect, CGRect(x: 724, y: 33, width: 708, height: 859))
        XCTAssertEqual(notes.sizesAsked, [CGSize(width: 708, height: 859)], "it took the size, so it is not asked a second time")

        // The user makes it smaller by its bottom-right corner. It is theirs now: no fit follows.
        notes.rect.size = CGSize(width: 500, height: 400)
        mac.settle()
        XCTAssertEqual(notes.rect, CGRect(x: 724, y: 33, width: 500, height: 400))
    }

    func testAWindowTiledAgainBeforeTheSecondLookKeepsToItsTile() {
        mac.writeConfig(floatNotes)
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 1000, height: 500))
        notes.minSize = CGSize(width: 900, height: 300)
        mac.settle()
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()

        XCTAssertEqual(mac.run("place left --window \(notes.id)", settle: false), "ok")
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(notes.rect, CGRect(x: 8, y: 33, width: 900, height: 859), "too wide for the half: a second look is due")

        // Before it, the user tiles the window and moves it to the top. Its tile has the corner
        // of the half it was placed in, and is not the size that was asked for either.
        XCTAssertEqual(mac.run("float --window \(notes.id)", settle: false), "ok: tiled")
        XCTAssertEqual(mac.run("move up --window \(notes.id)", settle: false), "ok")
        XCTAssertFrame(notes.rect, CGRect(x: 8, y: 33, width: 1424, height: 425.5))
        let asked = notes.positionsAsked.count

        // The fit would send it half way down the display, and the layout would fetch it back.
        mac.settle()
        XCTAssertEqual(notes.positionsAsked.count, asked, "the second look does not touch a tiled window")
        XCTAssertFrame(notes.rect, CGRect(x: 8, y: 33, width: 1424, height: 425.5))
        XCTAssertFrame(terminal.rect, CGRect(x: 8, y: 466.5, width: 1424, height: 425.5))
        XCTAssertEqual(mac.tiles.count, 2)
    }

    func testAWindowThatCanBeTiledAfterAllBeforeTheSecondLookKeepsToItsTile() {
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        // A window that is reported before it can be resized: no layout takes it, and no rule floats it.
        let late = mac.system.open(mac.system.launch("Fonts"), frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        late.resizable = false
        mac.settle()
        XCTAssertEqual(mac.tiles.keys.sorted(), [terminal.id])

        XCTAssertEqual(mac.run("place left", settle: false), "ok")
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(late.rect, CGRect(x: 8, y: 33, width: 300, height: 200), "a second look is due")

        // By the time the user comes back to it, it is a window like any other, and is tiled.
        late.resizable = true
        mac.system.click(terminal)
        mac.system.click(late)
        mac.scheduler.advance(by: 0.05)
        XCTAssertEqual(mac.tiles.count, 2)
        XCTAssertEqual(mac.run("move up", settle: false), "ok")
        XCTAssertFrame(late.rect, CGRect(x: 8, y: 33, width: 1424, height: 425.5))
        let asked = late.positionsAsked.count

        mac.settle()
        XCTAssertEqual(late.positionsAsked.count, asked, "the second look does not touch a tiled window")
        XCTAssertFrame(late.rect, CGRect(x: 8, y: 33, width: 1424, height: 425.5))
        XCTAssertFrame(terminal.rect, CGRect(x: 8, y: 466.5, width: 1424, height: 425.5))
    }

    func testWithNoWindowOrOneThatCannotBeMovedPlaceIsAnError() {
        XCTAssertEqual(mac.run("place left"), "error: no focused window")

        let frame = CGRect(x: 100, y: 100, width: 640, height: 480)
        let pinned = mac.system.open(mac.system.launch("Notes"), frame: frame)
        pinned.movable = false
        mac.settle()

        XCTAssertEqual(mac.run("place left"), "error: this window cannot be moved")
        XCTAssertEqual(pinned.rect, frame)
        XCTAssertEqual(mac.run("place left --window 999"), "error: no window 999")
    }

    func testAWindowOnAFullscreenSpaceIsNotPlaced() {
        let display = mac.system.displayList[0]
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        // The window goes into native fullscreen: it has a Space of its own and fills the display.
        let space = mac.system.addFullscreenSpace(to: display)
        mac.system.put(notes, on: space)
        notes.fullscreen = true
        notes.rect = display.frame
        mac.system.show(space, on: display)
        mac.settle()

        XCTAssertEqual(mac.run("place left"), "error: a fullscreen window cannot be placed")
        XCTAssertEqual(notes.rect, display.frame)
    }
}
