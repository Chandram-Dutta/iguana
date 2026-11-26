import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

// What the `[[rule]]` sections of the config file do to windows: keep them floating, send
// them to a desktop or to a display as they open, and do the same on request (`apply-rules`).

private extension Scenario {
    /// What `list-windows` says a window is: tiled, floating, unmanaged or not on screen.
    func state(of window: FakeWindow) -> String? {
        for row in run("list-windows").split(separator: "\n") {
            let columns = row.dropFirst(2).split(separator: "\t", omittingEmptySubsequences: false)
            if columns.count > 1, columns[0] == "\(window.id)" { return String(columns[1]) }
        }
        return nil
    }

    /// A second, larger display to the right of the built-in one. It is display 2.
    @discardableResult
    func addStudioDisplay() -> FakeDisplay {
        let display = system.addDisplay("Studio Display", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        settle()
        return display
    }

    /// The moves asked of one window, oldest first.
    func moves(of window: FakeWindow) -> [ImmediateMover.Move] {
        mover.moves.filter { $0.window == window.id }
    }

    /// What the rules wrote to the log, without the lines about reading the config.
    var ruleLog: [String] {
        log.filter { $0.hasPrefix("rule") || $0.hasPrefix("apply-rules") }
    }
}

/// The area windows are tiled into on the built-in display and on the Studio Display.
private let builtIn = CGRect(x: 8, y: 33, width: 1424, height: 859)
private let studio = CGRect(x: 1448, y: 33, width: 1904, height: 1039)

// MARK: - Floating

/// Rules that keep windows out of the layout. Most of these start Iguana with the rule already
/// in its file, where the other suites write the file once Iguana runs.
final class FloatRuleScenarioTests: ScenarioTestCase {
    func testARuleFloatsAnAppByPartOfItsNameOrByItsBundleID() {
        replaceScenario(Scenario(config: """
        [[rule]]
        app = "calc"
        float = true

        [[rule]]
        app = "COM.apple.Finder"
        """))
        let frame = CGRect(x: 300, y: 200, width: 400, height: 500)
        let calculator = mac.system.open(mac.system.launch("Calculator"), frame: frame)
        let finder = mac.system.open(mac.system.launch("Finder", bundleID: "com.apple.finder"))
        // A bundle id has to be the whole of it, and this app's name does not hold the text either.
        let sync = mac.system.open(mac.system.launch("Sync", bundleID: "com.apple.finder.sync"))
        mac.settle()

        XCTAssertEqual(calculator.rect, frame, "left where it opened")
        XCTAssertTrue(calculator.sizesAsked.isEmpty && calculator.positionsAsked.isEmpty, "and never touched")
        XCTAssertEqual(mac.state(of: calculator), "floating", "part of the name is enough")
        XCTAssertEqual(mac.state(of: finder), "floating", "the case of the letters does not matter, and a rule floats unless it says otherwise")
        XCTAssertEqual(mac.tiles.keys.sorted(), [sync.id])
        XCTAssertFrame(sync.rect, builtIn, "the window no rule matches has the desktop to itself")
    }

    func testARuleFloatsOnlyTheWindowsWhoseTitleMatches() {
        replaceScenario(Scenario(config: """
        [[rule]]
        app = "Safari"
        title = "^picture in picture$"
        float = true
        """))
        let safari = mac.system.launch("Safari")
        let page = mac.system.open(safari, title: "Docs")
        mac.settle()
        let frame = CGRect(x: 900, y: 500, width: 480, height: 270)
        let player = mac.system.open(safari, title: "Picture in Picture", frame: frame)
        mac.settle()

        XCTAssertEqual(player.rect, frame)
        XCTAssertEqual(mac.state(of: player), "floating")
        XCTAssertFrame(page.rect, builtIn, "the page did not make room for it")
    }

    func testTheFirstRuleThatMatchesDecides() {
        replaceScenario(Scenario(config: """
        [[rule]]
        app = "Safari"
        title = "Docs"
        float = false

        [[rule]]
        app = "Safari"
        float = true
        """))
        let safari = mac.system.launch("Safari")
        let docs = mac.system.open(safari, title: "Docs")
        let downloads = mac.system.open(safari, title: "Downloads", frame: CGRect(x: 500, y: 300, width: 400, height: 300))
        mac.settle()

        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id], "the exception above the general rule is tiled")
        XCTAssertFrame(docs.rect, builtIn)
        XCTAssertEqual(mac.state(of: downloads), "floating")
    }

    func testTheBuiltInRulesFloatCalculatorUntilTheFileListsRulesOfItsOwn() {
        let frame = CGRect(x: 300, y: 200, width: 400, height: 500)
        let calculator = mac.system.open(mac.system.launch("Calculator", bundleID: "com.apple.calculator"), frame: frame)
        mac.settle()
        XCTAssertEqual(mac.state(of: calculator), "floating", "with no config file")
        XCTAssertEqual(calculator.rect, frame)

        // A file that lists rules lists all of them.
        mac.writeConfig("""
        [[rule]]
        app = "Notes"
        """)
        XCTAssertEqual(mac.state(of: calculator), "tiled")
        XCTAssertFrame(calculator.rect, builtIn, "no rule floats it any more, so it joined the layout")
    }

    func testReadingTheConfigAgainFloatsAWindowThatNowMatches() {
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        let tile = notes.rect
        XCTAssertEqual(mac.tiles.count, 2)

        mac.writeConfig("""
        [[rule]]
        app = "Notes"
        float = true
        """)

        XCTAssertEqual(mac.tiles.keys.sorted(), [terminal.id], "the window left the layout")
        XCTAssertFrame(terminal.rect, builtIn, "and the other took its room")
        XCTAssertEqual(notes.rect, tile, "it floats where its tile was")
    }

    func testAWindowFloatedByHandStaysFloatingWhenTheConfigIsReadAgain() {
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        XCTAssertEqual(mac.run("float"), "ok: floating")
        XCTAssertEqual(mac.tiles.keys.sorted(), [terminal.id])

        // No rule in this file floats Notes.
        mac.writeConfig("""
        [gaps]
        inner = 20

        [[rule]]
        app = "Calculator"
        """)

        XCTAssertEqual(mac.state(of: notes), "floating", "the user's choice outlives the reload")
        XCTAssertEqual(mac.tiles.keys.sorted(), [terminal.id])
    }

    func testAWindowTiledByHandStaysTiledAlthoughARuleFloatsIt() {
        let rule = """
        [[rule]]
        app = "Notes"
        float = true
        """
        replaceScenario(Scenario(config: rule))
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 300, y: 200, width: 400, height: 300))
        mac.settle()
        XCTAssertEqual(mac.state(of: notes), "floating")

        XCTAssertEqual(mac.run("float"), "ok: tiled")
        XCTAssertFrame(notes.rect, builtIn)

        mac.writeConfig(rule + "\n[gaps]\ninner = 20\n")
        XCTAssertEqual(mac.state(of: notes), "tiled", "the rule is read again and still does not float it")
        XCTAssertFrame(notes.rect, builtIn)
    }

    func testApplyRulesFloatsAWindowWhoseTitleHasComeToMatch() {
        replaceScenario(Scenario(config: """
        [[rule]]
        title = "Player"
        float = true
        """))
        let window = mac.system.open(mac.system.launch("Safari"), title: "Loading")
        mac.settle()
        XCTAssertEqual(mac.state(of: window), "tiled", "its title did not match when it opened")

        window.title = "Player"
        XCTAssertEqual(mac.run("apply-rules"), "ok: nothing to move")

        XCTAssertEqual(mac.state(of: window), "floating")
        XCTAssertTrue(mac.tiles.isEmpty)
    }
}

// MARK: - Desktops

/// Rules that name a desktop: a new window is sent there and the user stays.
final class DesktopRuleScenarioTests: ScenarioTestCase {
    private let mailToTwo = """
    [[rule]]
    app = "Mail"
    desktop = 2
    """

    private var display: FakeDisplay { mac.system.displayList[0] }

    /// Read `config` with two desktops on the built-in display. Desktop 1 is showing.
    private func start(_ config: String) {
        mac.system.addDesktop(to: display)
        mac.writeConfig(config)
    }

    func testANewWindowIsSentToItsDesktopAndTheUserStays() {
        start(mailToTwo)
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        mac.mover.clearRecord()

        let mail = mac.system.open(mac.system.launch("Mail"), title: "Inbox")
        mac.settle()

        XCTAssertEqual(mail.spaces, [display.spaces[1].id], "the window is on desktop 2")
        XCTAssertEqual(display.currentSpace.id, display.spaces[0].id, "and desktop 1 is still showing")
        XCTAssertTrue(mac.system.pressed.isEmpty, "no shortcut switched desktop on the way")
        XCTAssertEqual(mac.system.moveRequests.map(\.window), [mail.id], "it was asked to go once")
        XCTAssertEqual(mac.ruleLog, ["rule: sent window \(mail.id) of Mail to desktop 2"])
        XCTAssertEqual(mac.tiles.keys.sorted(), [terminal.id])
        XCTAssertFrame(terminal.rect, builtIn)
        XCTAssertTrue(mac.moves(of: terminal).isEmpty, "the window here never made room for it")
    }

    func testOnItsDesktopTheWindowIsTiledAndOneThatOpensThereIsLeftAlone() {
        start(mailToTwo)
        let app = mac.system.launch("Mail")
        let mail = mac.system.open(app, title: "Inbox")
        mac.settle()
        XCTAssertTrue(mac.tiles.isEmpty)

        mac.system.show(display.spaces[1], on: display)
        mac.settle()
        XCTAssertFrame(mail.rect, builtIn)
        XCTAssertEqual(mac.tiles.keys.sorted(), [mail.id])

        // Another window of the app opens here, on the desktop its rule names.
        let second = mac.system.open(app, title: "Message")
        mac.settle()
        XCTAssertEqual(second.spaces, [display.spaces[1].id])
        XCTAssertEqual(mac.tiles.count, 2)
        XCTAssertEqual(mac.system.moveRequests.count, 1, "neither window was asked to go anywhere once it was here")
        XCTAssertEqual(mac.ruleLog, ["rule: sent window \(mail.id) of Mail to desktop 2"])
    }

    func testTheKeyboardGoesBackToTheWindowThatHadIt() {
        start(mailToTwo)
        let terminal = mac.system.launch("Terminal")
        let first = mac.system.open(terminal, title: "One")
        mac.settle()
        let second = mac.system.open(terminal, title: "Two")
        mac.settle()
        // The user works in the first window. The second is the one in front of the rest.
        mac.system.click(first)
        mac.settle()
        XCTAssertEqual(mac.focused, first.id)

        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertEqual(mail.spaces, [display.spaces[1].id])
        XCTAssertEqual(mac.focused, first.id, "not the second window, and not nothing")
        XCTAssertEqual(mac.system.frontmostPID, terminal.processIdentifier, "Terminal has the keyboard again")
        XCTAssertTrue(terminal.focusedWindow === first)
        XCTAssertEqual(mac.system.focusRequests.last, first.id)
        XCTAssertEqual(mac.tiles.keys.sorted(), [first.id, second.id])
    }

    func testWindowsAlreadyOpenWhenTheConfigIsReadStay() {
        mac.system.addDesktop(to: display)
        let mail = mac.system.launch("Mail")
        let old = mac.system.open(mail, title: "Inbox")
        mac.settle()

        mac.writeConfig(mailToTwo)
        XCTAssertEqual(old.spaces, [display.spaces[0].id], "the rule was written after this window opened")
        XCTAssertTrue(mac.system.moveRequests.isEmpty)
        XCTAssertFrame(old.rect, builtIn)

        let new = mac.system.open(mail, title: "Message", frame: CGRect(x: 300, y: 200, width: 500, height: 400))
        mac.settle()
        XCTAssertEqual(new.spaces, [display.spaces[1].id], "the next one to open is sent")
        XCTAssertEqual(old.spaces, [display.spaces[0].id])
    }

    func testADesktopThatDoesNotExistIsLogged() {
        start("""
        [[rule]]
        app = "Mail"
        desktop = 4
        """)
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertEqual(mac.ruleLog, ["rule: window \(mail.id) of Mail was not sent to desktop 4: there are only 2 desktops"])
        XCTAssertTrue(mac.system.moveRequests.isEmpty)
        XCTAssertFrame(mail.rect, builtIn, "it is tiled on the desktop it opened on")
    }

    func testWithoutTheBridgeNothingIsSentAndTheLogSaysWhyOnce() {
        start(mailToTwo)
        mac.system.hasMoveBridge = false
        let mail = mac.system.launch("Mail")
        let first = mac.system.open(mail)
        mac.settle()
        let second = mac.system.open(mail)
        mac.settle()

        XCTAssertEqual(mac.ruleLog, ["rule: this macOS can only take a window to another desktop by going there with it, so rules with a desktop are not applied"])
        XCTAssertTrue(mac.system.moveRequests.isEmpty && mac.system.pressed.isEmpty, "the user is never taken anywhere")
        XCTAssertEqual(first.spaces.union(second.spaces), [display.spaces[0].id])
        XCTAssertEqual(mac.tiles.count, 2)
    }

    func testNothingIsSentWhilePausedNorAfterwards() {
        start(mailToTwo)
        XCTAssertEqual(mac.run("pause"), "ok: paused")
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        XCTAssertEqual(mail.spaces, [display.spaces[0].id])

        XCTAssertEqual(mac.run("pause"), "ok: tiling")
        XCTAssertEqual(mail.spaces, [display.spaces[0].id], "the user has it here by now, so it stays")
        XCTAssertTrue(mac.system.moveRequests.isEmpty)
        XCTAssertFrame(mail.rect, builtIn)
        XCTAssertTrue(mac.ruleLog.isEmpty)
    }

    func testANativeTabIsNotSentOnItsOwn() {
        mac.system.addDesktop(to: display)
        let mail = mac.system.launch("Mail")
        let window = mac.system.open(mail, title: "Inbox")
        mac.settle()
        mac.writeConfig(mailToTwo)

        // A new tab is a window of its own, with the frame of the window it is a tab of.
        let tab = mac.system.open(mail, title: "Drafts", frame: window.rect)
        mac.settle()
        XCTAssertEqual(tab.spaces, [display.spaces[0].id], "the tab stays with its window")
        XCTAssertTrue(mac.system.moveRequests.isEmpty)

        let separate = mac.system.open(mail, title: "Message", frame: CGRect(x: 300, y: 200, width: 500, height: 400))
        mac.settle()
        XCTAssertEqual(separate.spaces, [display.spaces[1].id], "a window of its own is sent")
    }

    func testAWindowThatSettlesIntoAStandardOneInTimeIsStillSent() {
        start(mailToTwo)
        mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        // The window is reported before it has its final role, behind the others.
        let mail = mac.system.open(mac.system.launch("Mail"), focus: false)
        mail.subrole = kAXDialogSubrole
        mac.scheduler.advance(by: 1)
        XCTAssertEqual(mail.spaces, [display.spaces[0].id], "not sent while it is no standard window")

        mail.subrole = kAXStandardWindowSubrole
        mac.system.click(mail)
        mac.settle()

        XCTAssertEqual(mail.spaces, [display.spaces[1].id])
        XCTAssertEqual(mac.ruleLog, ["rule: sent window \(mail.id) of Mail to desktop 2"])
    }

    func testAWindowThatTakesTooLongToSettleStays() {
        start(mailToTwo)
        mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        let mail = mac.system.open(mac.system.launch("Mail"), focus: false)
        mail.subrole = kAXDialogSubrole
        // Longer than the queue is patient for.
        mac.scheduler.advance(by: DesktopRuleQueue.patience + 0.5)

        mail.subrole = kAXStandardWindowSubrole
        mac.system.click(mail)
        mac.settle()

        XCTAssertEqual(mail.spaces, [display.spaces[0].id], "the user may be working in it by now")
        XCTAssertTrue(mac.system.moveRequests.isEmpty)
        XCTAssertNotNil(mac.tiles[mail.id], "it is tiled here instead")
    }

    func testADesktopOnAnotherDisplayTakesTheWindowToThatDisplay() {
        mac.writeConfig(mailToTwo)
        let second = mac.addStudioDisplay()
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()

        // Desktop 2 is the one the Studio Display shows.
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertEqual(mail.spaces, [second.currentSpace.id])
        XCTAssertFrame(mail.rect, studio, "it is tiled on the display its desktop belongs to")
        XCTAssertFrame(terminal.rect, builtIn)
        XCTAssertEqual(mac.ruleLog, ["rule: sent window \(mail.id) of Mail to desktop 2"])
    }

    func testAWindowTheSystemDoesNotMoveIsPutBackAndLogged() {
        // Desktop 3 is on the Studio Display and is not the one it shows. A window put on that
        // display is on desktop 2 until the system takes it further, and here it does not.
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        desktop = 3
        """)
        mac.system.addDesktop(to: mac.addStudioDisplay())
        mac.system.bridgeMovesWindows = false

        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertEqual(mac.ruleLog, ["rule: window \(mail.id) of Mail was not sent to desktop 3: the system did not move the window"])
        XCTAssertEqual(mail.spaces, [display.currentSpace.id])
        XCTAssertFrame(mail.rect, builtIn, "back on the display it opened on, and tiled there")
        XCTAssertTrue(mac.system.pressed.isEmpty && mac.system.posted.isEmpty, "a rule never carries a window across by hand")
    }
}

// MARK: - Displays

/// Rules that name a display: a new window is moved there and joins the layout it finds.
final class DisplayRuleScenarioTests: ScenarioTestCase {
    private let mailToTwo = """
    [[rule]]
    app = "Mail"
    display = 2
    """

    /// The built-in display and a Studio Display to its right, with `config`.
    @discardableResult
    private func start(_ config: String) -> FakeDisplay {
        mac.writeConfig(config)
        return mac.addStudioDisplay()
    }

    func testANewWindowIsMovedToItsDisplayAndJoinsTheLayoutThere() {
        start(mailToTwo)
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 1600, y: 200, width: 600, height: 400))
        mac.settle()
        XCTAssertFrame(notes.rect, studio)

        let mail = mac.system.open(mac.system.launch("Mail"), frame: CGRect(x: 200, y: 150, width: 640, height: 480))
        mac.settle()

        XCTAssertEqual(mac.ruleLog, ["rule: sent window \(mail.id) of Mail to display 2 (Studio Display)"])
        XCTAssertFrame(notes.rect, CGRect(x: 1448, y: 33, width: 948, height: 1039))
        XCTAssertFrame(mail.rect, CGRect(x: 2404, y: 33, width: 948, height: 1039), "beside the window that was there")
        XCTAssertFrame(terminal.rect, builtIn, "the display it opened on is as it was")
        XCTAssertTrue(mac.system.moveRequests.isEmpty && mac.system.pressed.isEmpty, "no desktop was changed for it")
    }

    func testAWindowIsKeptOutOfEveryLayoutWhileItIsOnItsWay() {
        start(mailToTwo)
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        mac.mover.clearRecord()

        let mail = mac.system.open(mac.system.launch("Mail"), frame: CGRect(x: 200, y: 150, width: 640, height: 480))
        // Long enough for the window to be seen and sent, not for the move to be confirmed.
        mac.scheduler.advance(by: 0.04)
        // Something makes the window manager look again before then.
        mac.wm.refresh()

        XCTAssertEqual(mail.rect, CGRect(x: 2080, y: 312.5, width: 640, height: 480), "in the middle of its display, at its own size")
        XCTAssertNil(mac.tiles[mail.id], "no layout has taken it yet")
        XCTAssertTrue(mac.moves(of: terminal).isEmpty, "and the window it opened beside never made room")

        mac.settle()
        XCTAssertFrame(mail.rect, studio, "once it is seen to have arrived it is tiled there")
        XCTAssertFrame(terminal.rect, builtIn)
    }

    func testAWindowThatOpensOnItsDisplayIsLeftAlone() {
        start(mailToTwo)
        let mail = mac.system.open(mac.system.launch("Mail"), frame: CGRect(x: 1600, y: 200, width: 600, height: 400))
        mac.settle()

        XCTAssertTrue(mac.ruleLog.isEmpty)
        XCTAssertFrame(mail.rect, studio, "tiled as any window that opens there")
    }

    func testAFloatingWindowIsCentredOnItsDisplayAtItsOwnSize() {
        start("""
        [[rule]]
        app = "Mail"
        display = 2
        float = true
        """)
        let mail = mac.system.open(mac.system.launch("Mail"), frame: CGRect(x: 200, y: 150, width: 640, height: 480))
        mac.settle()

        XCTAssertEqual(mail.rect, CGRect(x: 2080, y: 312.5, width: 640, height: 480))
        XCTAssertTrue(mac.tiles.isEmpty)
        XCTAssertEqual(mac.ruleLog, ["rule: sent window \(mail.id) of Mail to display 2 (Studio Display)"])
    }

    func testADisplayThatIsNotConnectedIsLoggedOnceForEachRule() {
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        display = 2

        [[rule]]
        app = "Notes"
        display = "Studio"
        """)
        let mail = mac.system.launch("Mail")
        let first = mac.system.open(mail)
        mac.settle()
        mac.system.open(mail)
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()

        XCTAssertEqual(mac.ruleLog, [
            "rule 1: window \(first.id) of Mail was not sent to display 2: no such display is connected (said once for this rule)",
            "rule 2: window \(notes.id) of Notes was not sent to display \"Studio\": no such display is connected (said once for this rule)",
        ])
        XCTAssertEqual(mac.tiles.count, 3, "the windows are tiled where they opened")
    }

    func testADisplayShowingAFullscreenAppDoesNotTakeTheWindow() {
        let second = start(mailToTwo)
        mac.system.show(mac.system.addFullscreenSpace(to: second), on: second)
        mac.settle()

        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()

        XCTAssertEqual(mac.ruleLog, ["rule: window \(mail.id) of Mail was not sent to display 2 (Studio Display): that display is showing a fullscreen Space"])
        XCTAssertFrame(mail.rect, builtIn, "it is tiled where it opened")
    }
}

// MARK: - apply-rules

/// `apply-rules`: the rules, carried out for the windows that are already open.
final class ApplyRulesScenarioTests: ScenarioTestCase {
    private var display: FakeDisplay { mac.system.displayList[0] }

    func testOpenWindowsAreSentToTheirDesktopAndCounted() {
        mac.system.addDesktop(to: display)
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        let mail = mac.system.launch("Mail")
        let inbox = mac.system.open(mail, title: "Inbox")
        mac.settle()
        let message = mac.system.open(mail, title: "Message")
        mac.settle()
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        desktop = 2
        """)
        XCTAssertEqual(mac.tiles.count, 3, "reading the rule moved nothing")

        XCTAssertEqual(mac.run("apply-rules"), "ok: 2 window(s) moved")

        XCTAssertEqual(inbox.spaces.union(message.spaces), [display.spaces[1].id])
        XCTAssertEqual(display.currentSpace.id, display.spaces[0].id, "the user stays on desktop 1")
        XCTAssertTrue(mac.system.pressed.isEmpty)
        XCTAssertEqual(mac.tiles.keys.sorted(), [terminal.id])
        XCTAssertFrame(terminal.rect, builtIn, "what is left has the desktop to itself")

        XCTAssertEqual(mac.run("apply-rules"), "ok: nothing to move", "they are where their rule wants them")
    }

    func testAnOpenWindowIsMovedToItsDisplay() {
        mac.addStudioDisplay()
        let terminal = mac.system.open(mac.system.launch("Terminal"))
        mac.settle()
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        // A display can be named by part of its name, in any case.
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        display = "studio"
        """)
        XCTAssertEqual(mac.tiles.count, 2)

        XCTAssertEqual(mac.wm.run(.applyRules), "ok: 1 window(s) moved")
        mac.settle()

        XCTAssertFrame(mail.rect, studio)
        XCTAssertFrame(terminal.rect, builtIn)
        XCTAssertEqual(mac.run("apply-rules"), "ok: nothing to move")
    }

    func testItRefusesWhileTilingIsPaused() {
        mac.system.addDesktop(to: display)
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        desktop = 2
        """)
        mac.run("pause")

        XCTAssertEqual(mac.run("apply-rules"), "error: tiling is paused")
        XCTAssertEqual(mail.spaces, [display.spaces[0].id])
    }

    func testADesktopAndADisplayThatAreNotThereAreLogged() {
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        let notes = mac.system.open(mac.system.launch("Notes"))
        mac.settle()
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        desktop = 5

        [[rule]]
        app = "Notes"
        display = 3
        """)

        XCTAssertEqual(mac.run("apply-rules"), "ok: nothing to move")
        XCTAssertEqual(mac.ruleLog, [
            "apply-rules: window \(mail.id) of Mail was not sent to desktop 5: there are only 1 desktops",
            "apply-rules: window \(notes.id) of Notes was not sent to display 3: no such display is connected",
        ])
        XCTAssertEqual(mac.tiles.count, 2)
    }

    func testWithoutTheBridgeDesktopsAreNotAppliedAndTheLogSaysWhyOnce() {
        mac.system.addDesktop(to: display)
        mac.system.hasMoveBridge = false
        let mail = mac.system.launch("Mail")
        mac.system.open(mail)
        mac.settle()
        mac.system.open(mail)
        mac.settle()
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        desktop = 2
        """)

        XCTAssertEqual(mac.run("apply-rules"), "ok: nothing to move")
        XCTAssertEqual(mac.ruleLog, ["apply-rules: this macOS can only take a window to another desktop by going there with it, so desktops in rules were not applied"])
        XCTAssertTrue(mac.system.pressed.isEmpty && mac.system.posted.isEmpty, "nothing was carried across by hand")
        XCTAssertEqual(mac.tiles.count, 2)
    }

    func testAWindowTheSystemWillNotMoveIsPutBackAndLogged() {
        mac.system.addDesktop(to: mac.addStudioDisplay())
        mac.system.bridgeMovesWindows = false
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        // Desktop 3 is on the Studio Display and is not the one it shows. A window put on that
        // display is on desktop 2 until the system takes it further, and here it does not.
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        desktop = 3
        """)

        XCTAssertEqual(mac.run("apply-rules"), "ok: nothing to move")
        XCTAssertEqual(mac.ruleLog, ["apply-rules: window \(mail.id) of Mail was not moved: the system did not move the window"])
        XCTAssertFrame(mail.rect, builtIn, "back on its own display")
        XCTAssertEqual(mail.spaces, [display.currentSpace.id])
    }

    func testMinimisedWindowsAndWindowsOnOtherDesktopsAreNotMovedToADisplay() {
        mac.addStudioDisplay()
        let other = mac.system.addDesktop(to: display)
        let mail = mac.system.launch("Mail")
        let minimised = mac.system.open(mail, title: "Inbox")
        mac.settle()
        let elsewhere = mac.system.open(mail, title: "Message", frame: CGRect(x: 100, y: 100, width: 500, height: 400), on: other)
        mac.settle()
        mac.system.minimise(minimised)
        mac.settle()
        let before = minimised.rect
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        display = 2
        """)

        XCTAssertEqual(mac.run("apply-rules"), "ok: nothing to move")
        XCTAssertEqual(minimised.rect, before)
        XCTAssertEqual(elsewhere.rect, CGRect(x: 100, y: 100, width: 500, height: 400), "a window on a desktop that is not showing stays on it")
        XCTAssertTrue(mac.ruleLog.isEmpty)
    }

    func testAWindowThatNeverArrivesOnItsDisplayIsLoggedAndTakesItsTileBack() {
        mac.addStudioDisplay()
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        display = 2
        """)
        // The app has stopped letting the window be moved.
        mail.movable = false

        XCTAssertEqual(mac.wm.run(.applyRules), "ok: 1 window(s) moved", "it was asked to go")
        mac.scheduler.advance(by: 0.25)
        XCTAssertNil(mac.tiles[mail.id], "while it is waited for, no layout has it")
        XCTAssertTrue(mac.logged("did not move").isEmpty)

        mac.settle()
        XCTAssertEqual(mac.logged("did not move"), ["rule: window \(mail.id) did not move to display 2"])
        XCTAssertFrame(mac.tiles[mail.id], builtIn, "given up on, it is tiled where it is")
        XCTAssertFrame(mail.rect, builtIn)
    }

    func testTheLogNamesTheDisplayByTheNumberTheRuleUses() {
        // A display to the left of the built-in one is display 1, though it was connected second.
        mac.system.addDisplay("Left", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        mac.settle()
        let mail = mac.system.open(mac.system.launch("Mail"))
        mac.settle()
        mac.writeConfig("""
        [[rule]]
        app = "Mail"
        display = 1
        """)
        mail.movable = false

        XCTAssertEqual(mac.run("apply-rules"), "ok: 1 window(s) moved")
        XCTAssertEqual(mac.logged("did not move").count, 1)
        XCTAssertEqual(mac.logged("did not move"), ["rule: window \(mail.id) did not move to display 1"])
    }
}
