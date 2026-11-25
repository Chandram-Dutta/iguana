import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// How a command finds the window it acts on, what it answers when there is none, and the
/// commands that are about Iguana itself: modes, chains, pausing, quitting.
final class CommandDispatchTests: LayoutCommandTestCase {
    static let modes = """
    [bindings]
    option-r = "mode resize"

    [mode.resize]
    h = "resize shrink width"
    l = "resize grow width"

    """

    // MARK: --window

    func testALayoutCommandOnANamedWindowLeavesTheFocusWhereItIs() {
        let w = open(3)
        let first = w[0].id

        XCTAssertEqual(mac.run("move right --window \(first)"), "ok")
        let thirds = rows(1, 1, 1)
        XCTAssertFrame(w[1].rect, thirds[0])
        XCTAssertFrame(w[2].rect, thirds[1])
        XCTAssertFrame(w[0].rect, thirds[2])

        // A third of the room and one step of 5% more.
        XCTAssertEqual(mac.run("resize grow --window \(first)"), "ok")
        XCTAssertEqual(w[0].rect.height, (1.0 / 3 + 0.05) * (area.height - 2 * gap), accuracy: 1.5)
        XCTAssertEqual(w[0].rect.maxY, area.maxY, accuracy: 1)

        XCTAssertEqual(mac.run("flip --window \(first)"), "ok")
        XCTAssertEqual(mac.tiledInReadingOrder, [w[1].id, w[2].id, first])
        XCTAssertEqual(w[0].rect.width, (1.0 / 3 + 0.05) * (area.width - 2 * gap), accuracy: 1.5)
        XCTAssertEqual(w[0].rect.height, area.height, accuracy: 1)

        // The named window is the main one, not the focused one.
        XCTAssertEqual(mac.run("arrange main --window \(first)"), "ok")
        let parts = columns(0.6, 0.4)
        XCTAssertFrame(w[0].rect, parts[0])
        XCTAssertFrame(w[1].rect, rows(1, 1, of: parts[1])[0])
        XCTAssertFrame(w[2].rect, rows(1, 1, of: parts[1])[1])

        XCTAssertEqual(mac.focused, w[2].id)
        XCTAssertTrue(mac.system.focusRequests.isEmpty, "no window was asked to take the keyboard")
    }

    func testZoomFloatAndCloseTakeANamedWindow() {
        let w = open(3)
        let first = w[0].id

        XCTAssertEqual(mac.run("zoom --window \(first)"), "ok")
        XCTAssertFrame(w[0].rect, area)
        XCTAssertEqual(mac.focused, w[2].id)
        XCTAssertEqual(mac.run("zoom --window \(first)"), "ok")
        XCTAssertFrame(w[0].rect, columns(1, 1)[0])

        XCTAssertEqual(mac.run("float --window \(first)"), "ok: floating")
        XCTAssertFrame(w[1].rect, rows(1, 1)[0], "the two that are left have the desktop")
        XCTAssertFrame(w[2].rect, rows(1, 1)[1])
        // It comes back beside the focused window, as a window that has just opened would.
        XCTAssertEqual(mac.run("float --window \(first)"), "ok: tiled")
        XCTAssertFrame(w[2].rect, columns(1, 1, of: rows(1, 1)[1])[0])
        XCTAssertFrame(w[0].rect, columns(1, 1, of: rows(1, 1)[1])[1])

        XCTAssertEqual(mac.run("close --window \(first)"), "ok")
        XCTAssertNil(mac.system.window(first))
        XCTAssertEqual(mac.tiles.keys.sorted(), [w[1].id, w[2].id])
        XCTAssertEqual(mac.focused, w[2].id)
        XCTAssertTrue(mac.system.focusRequests.isEmpty)
    }

    func testFocusWithAWindowNamedGivesThatWindowTheFocus() {
        let w = open(3)

        XCTAssertEqual(mac.run("focus --window \(w[0].id)"), "ok")

        XCTAssertEqual(mac.focused, w[0].id)
        XCTAssertEqual(mac.system.focusRequests, [w[0].id])
        XCTAssertEqual(mac.system.order.first?.id, w[0].id)
        // A shortcut cannot name a window, and `focus` alone means nothing.
        XCTAssertEqual(mac.wm.run(.focusWindow), "error: 'focus' needs one of: left, right, up, down")
    }

    func testAWindowIdThatIsNotThereIsAnError() {
        let w = open(2)

        for command in ["move left", "join left", "resize grow", "flip", "stack", "balance", "split auto", "arrange grid",
                        "zoom", "float", "close", "focus"] {
            XCTAssertEqual(mac.run("\(command) --window 4242"), "error: no window 4242", command)
        }

        XCTAssertFrame(w[0].rect, columns(1, 1)[0])
        XCTAssertFrame(w[1].rect, columns(1, 1)[1])
        XCTAssertEqual(mac.focused, w[1].id)
    }

    func testAWindowWithoutATileCannotBeRearranged() {
        let w = open(2)
        mac.run("float")
        let floating = w[1].id
        let commands = ["move left", "join left", "resize grow", "flip", "stack", "balance", "split vertical", "arrange rows", "zoom"]

        for command in commands {
            XCTAssertEqual(mac.run("\(command) --window \(floating)"), "error: window \(floating) is not tiled on a desktop being shown", command)
            // It has the focus as well, and without a name the answer is about the focused window.
            XCTAssertEqual(mac.run(command), "error: the focused window is not tiled", command)
        }
        XCTAssertFrame(w[0].rect, area)
        XCTAssertEqual(mac.run("undo"), "ok: nothing to undo", "none of that was a change")

        // A window in the Dock has a place in the layout, and no tile for as long as it is there.
        mac.system.minimise(w[0])
        mac.settle()
        XCTAssertEqual(mac.run("flip --window \(w[0].id)"), "error: window \(w[0].id) is not tiled on a desktop being shown")
    }

    // MARK: Which window, and what if there is none

    func testACommandActsOnTheWindowTheUserJustClicked() {
        let w = open(2)
        // No time passes: the window manager has not looked at the screen since the click.
        mac.system.click(w[0])

        XCTAssertEqual(mac.run("move right"), "ok")

        XCTAssertEqual(mac.tiledInReadingOrder, [w[1].id, w[0].id])
        XCTAssertEqual(mac.focused, w[0].id)
    }

    func testWithNoWindowEveryCommandSaysWhatIsMissing() {
        let noTile = "error: the focused window is not tiled"
        let noWindow = "error: no focused window"
        let expected: [(command: String, reply: String)] = [
            ("move left", noTile), ("join right", noTile), ("resize grow", noTile), ("flip", noTile), ("stack", noTile),
            ("balance", noTile), ("split vertical", noTile), ("arrange grid", noTile), ("zoom", noTile),
            ("float", noWindow), ("close", noWindow), ("place center", noWindow),
            ("move-to-space 1", noWindow), ("move-to-display next", noWindow),
            ("undo", "ok: nothing to undo"), ("redo", "ok: nothing to redo"),
            ("focus left", "ok: no windows here"), ("focus recent", "ok: no other recent window"),
            ("focus-display next", "ok: only one display"), ("space 1", "ok: already on desktop 1"),
            ("focus-app nosuch", "error: no app called 'nosuch'"), ("apply-rules", "ok: nothing to move"),
            ("list-windows", "no windows on this Space"),
            ("list-spaces", "Display 1, Built-in Display: showing desktop 1 of 1; this display has 1 desktop(s)"),
            ("tree", "Built-in Display, desktop 1\n  (no tiled windows)"),
        ]

        for (command, reply) in expected { XCTAssertEqual(mac.run(command), reply, command) }
    }

    // MARK: Before the permission

    func testWithoutThePermissionIguanaCanStillBeInspectedAndStopped() {
        replaceScenario(Scenario(config: Self.modes, start: false))
        mac.system.isTrusted = false
        mac.wm.start()
        var opened: [String] = []
        mac.wm.onOpenSettings = { opened.append("settings") }
        mac.wm.onOpenTour = { opened.append("tour") }
        mac.wm.onCheckForUpdate = { opened.append("update") }
        let window = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 300, height: 300))
        mac.settle()

        XCTAssertTrue(mac.run("status").contains("waiting for Accessibility permission"))
        XCTAssertEqual(mac.run("reload"), "ok: loaded \(mac.configURL.path)")
        XCTAssertEqual(mac.run("mode resize"), "ok")
        XCTAssertEqual(mac.wm.mode, "resize")
        XCTAssertEqual(mac.run("settings"), "ok")
        XCTAssertEqual(mac.run("tour"), "ok")
        XCTAssertEqual(mac.run("update"), "ok: checking")
        XCTAssertEqual(opened, ["settings", "tour", "update"])

        // Everything that touches a window waits for the permission.
        for command in ["flip", "float", "close", "undo", "pause", "switcher", "list-windows", "focus left"] {
            XCTAssertTrue(mac.run(command).hasPrefix("error: Iguana needs Accessibility permission"), command)
        }
        // Each command of a chain asks for itself: the way out of the mode works, the flip does not.
        XCTAssertTrue(mac.run("mode default; flip").hasPrefix("error: Iguana needs Accessibility permission"))
        XCTAssertEqual(mac.wm.mode, "default")
        XCTAssertEqual(window.rect, CGRect(x: 100, y: 100, width: 300, height: 300))

        XCTAssertEqual(mac.run("quit"), "ok")
        XCTAssertTrue(mac.system.terminated)
    }

    // MARK: The app shell

    func testQuitAnswersFirstAndStopsIguanaAMomentLater() {
        open(1)

        XCTAssertEqual(mac.wm.run(.quit), "ok")

        XCTAssertFalse(mac.system.terminated, "the answer has to reach the command line first")
        mac.scheduler.advance(by: 0.09)
        XCTAssertFalse(mac.system.terminated)
        mac.scheduler.advance(by: 0.02)
        XCTAssertTrue(mac.system.terminated)
    }

    func testSettingsTourUpdateAndSwitcherAreHandedToTheAppShell() {
        // With no app shell around them, the commands still answer.
        XCTAssertEqual(mac.run("settings"), "ok")
        XCTAssertEqual(mac.run("tour"), "ok")
        XCTAssertEqual(mac.run("update"), "ok: checking")
        XCTAssertEqual(mac.run("switcher"), "ok")

        var asked: [String] = []
        mac.wm.onOpenSettings = { asked.append("settings") }
        mac.wm.onOpenTour = { asked.append("tour") }
        mac.wm.onCheckForUpdate = { asked.append("update") }
        mac.wm.onOpenSwitcher = {
            asked.append("switcher")
            return "ok: 3 windows"
        }

        XCTAssertEqual(mac.run("settings"), "ok")
        XCTAssertEqual(mac.run("tour"), "ok")
        XCTAssertEqual(mac.run("update"), "ok: checking")
        XCTAssertEqual(mac.run("switcher"), "ok: 3 windows", "the switcher answers for itself")
        XCTAssertEqual(asked, ["settings", "tour", "update", "switcher"])

        // A stream of events needs a command line to print to. A shortcut has none.
        XCTAssertEqual(mac.run("subscribe"), "error: subscribe only works from the command line")
        XCTAssertEqual(mac.run("subscribe focus-changed"), "error: subscribe only works from the command line")
        XCTAssertFalse(mac.system.terminated)
    }

    // MARK: pause

    func testPauseLeavesWindowsAloneUntilTilingIsBack() {
        let w = open(2)
        var looks = 0
        mac.wm.onChange = { looks += 1 }

        XCTAssertEqual(mac.run("pause"), "ok: paused")
        XCTAssertTrue(mac.run("status").hasPrefix("Iguana \(Iguana.version): paused"))
        mac.system.drag(w[1], to: CGPoint(x: 100, y: 100))
        mac.system.releaseMouse()
        mac.settle()
        XCTAssertEqual(w[1].rect.origin, CGPoint(x: 100, y: 100), "a window moved by hand stays there")

        mac.mover.clearRecord()
        XCTAssertEqual(mac.run("pause"), "ok: tiling")
        XCTAssertTrue(mac.run("status").hasPrefix("Iguana \(Iguana.version): tiling"))
        XCTAssertFrame(w[1].rect, columns(1, 1)[1], "back on its tile")
        XCTAssertEqual(mac.mover.moves.map(\.duration), [0.16], "and it glides there")

        // Told what it is doing already, it does nothing.
        looks = 0
        mac.wm.setPaused(false)
        XCTAssertEqual(looks, 0)
    }

    // MARK: Chains

    func testAChainRunsItsCommandsInOrderAndStopsAtTheFirstError() {
        let w = open(2)

        // The last command answers. Flipped first, the stack runs top to bottom.
        XCTAssertEqual(mac.run("flip; stack"), "ok: stacked")
        XCTAssertFrame(w[0].rect, CGRect(x: 8, y: 33, width: 1424, height: 859 - 32))
        XCTAssertFrame(w[1].rect, CGRect(x: 8, y: 33 + 32, width: 1424, height: 859 - 32))

        XCTAssertEqual(mac.run("stack; flip; move left;"), "ok")
        XCTAssertFrame(w[1].rect, columns(1, 1)[0])
        XCTAssertFrame(w[0].rect, columns(1, 1)[1])

        // The flip is made. The error is the answer, and the move never runs.
        XCTAssertEqual(mac.run("flip; mode nosuch; move down"), "error: no mode 'nosuch'")
        XCTAssertFrame(w[1].rect, rows(1, 1)[0])
        XCTAssertFrame(w[0].rect, rows(1, 1)[1])
    }

    // MARK: Modes

    func testModeSwitchesToTheShortcutsOfItsTableAndBack() {
        replaceScenario(Scenario(config: Self.modes))
        var changes = 0
        mac.wm.onModeChange = { changes += 1 }
        XCTAssertEqual(mac.wm.mode, "default")

        XCTAssertEqual(mac.run("mode resize"), "ok")
        XCTAssertEqual(mac.wm.mode, "resize")
        XCTAssertEqual(changes, 1, "the app shell is told, to register the other shortcuts")
        XCTAssertTrue(mac.run("status").contains("\nmode: resize"))

        XCTAssertEqual(mac.run("mode resize"), "ok")
        XCTAssertEqual(changes, 1, "already in it: nothing to register")

        // A mode with no table in the config is an error, and the mode stays.
        XCTAssertEqual(mac.run("mode move"), "error: no mode 'move'")
        XCTAssertEqual(mac.wm.mode, "resize")
        XCTAssertEqual(changes, 1)

        XCTAssertEqual(mac.run("mode default"), "ok")
        XCTAssertEqual(mac.wm.mode, "default")
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(mac.run("status").contains("mode:"))
    }

    func testAModeIsLeftWhenTheConfigNoLongerHasItAsItWas() {
        replaceScenario(Scenario(config: Self.modes))
        var changes = 0
        mac.wm.onModeChange = { changes += 1 }
        mac.run("mode resize")

        // Something else in the file changes: the mode stays.
        mac.writeConfig(Self.modes + "\n[gaps]\ninner = 12\n")
        XCTAssertEqual(mac.wm.mode, "resize")
        XCTAssertEqual(changes, 1)

        // One of its keys changes: back to the ordinary shortcuts, rather than half of a mode.
        mac.writeConfig(Self.modes.replacingOccurrences(of: "resize grow width", with: "resize grow height"))
        XCTAssertEqual(mac.wm.mode, "default")
        XCTAssertEqual(changes, 2)

        // The table goes while the mode is on.
        mac.run("mode resize")
        mac.writeConfig("")
        XCTAssertEqual(mac.wm.mode, "default")
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(mac.run("mode resize"), "error: no mode 'resize'")
    }
}
