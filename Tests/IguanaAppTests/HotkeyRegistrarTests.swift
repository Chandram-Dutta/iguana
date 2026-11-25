import XCTest
import IguanaCore
@testable import iguana

/// Which shortcuts are asked of the system for a config with modes, and what is remembered
/// about them. The window manager is real; the system's hot-key service is played by the test.
final class HotkeyRegistrarTests: ScenarioTestCase {
    var service: FakeShortcutService!
    var registrar: HotkeyRegistrar!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// What a pressed shortcut answers, in place of the window manager. Nil runs the command.
    var answer: String?

    override func makeScenario() -> Scenario { Scenario(config: ShellFakes.modes) }

    override func setUp() {
        super.setUp()
        answer = nil
        let service = FakeShortcutService()
        registrar = HotkeyRegistrar(wm: mac.wm, makeService: { service }, now: { [unowned self] in clock }) { [unowned self] binding in
            answer ?? mac.wm.run(binding.command)
        }
        self.service = service
    }

    override func tearDown() {
        registrar = nil
        service = nil
        super.tearDown()
    }

    var modeWarning: String { "binding 'nokey' in [mode.move]: unknown key 'nokey'" }

    func testNothingIsRegisteredBeforeTheAppHasLaunched() {
        registrar.register()
        XCTAssertEqual(service.passes, 0)
        XCTAssertEqual(registrar.registered, 0)
        XCTAssertEqual(registrar.problems, [])
        registrar.unregisterAll()
    }

    func testTheShortcutsOfBindingsAreRegisteredOutsideAMode() {
        registrar.start()
        registrar.register()
        XCTAssertEqual(service.keys, mac.wm.config.bindings.map(\.source))
        XCTAssertEqual(registrar.registered, Config.default.bindings.count + 1, "the built-in shortcuts and option-r")
        XCTAssertTrue(service.keys.contains("option-r"))
    }

    func testAModeHasOnlyItsOwnShortcutsAndEscToLeaveIt() {
        registrar.start()
        mac.run("mode resize")
        registrar.register()
        XCTAssertEqual(service.keys, ["h", "l", "return", "esc"])
        XCTAssertEqual(registrar.registered, 4)

        mac.run("mode default")
        registrar.register()
        XCTAssertEqual(service.keys, mac.wm.config.bindings.map(\.source))
    }

    func testAMistypedKeyInAnotherModeIsAProblemAtOnce() {
        registrar.start()
        registrar.register()
        XCTAssertEqual(registrar.problems, [modeWarning])
        XCTAssertEqual(registrar.registered, mac.wm.config.bindings.count, "it does not count against the shortcuts in use")
        XCTAssertEqual(mac.logged("unknown key 'nokey'"), [modeWarning])
    }

    func testAMistypedKeyInTheModeInUseIsSaidOnce() {
        registrar.start()
        mac.run("mode move")
        registrar.register()
        XCTAssertEqual(service.keys, ["h", "esc"])
        XCTAssertEqual(registrar.problems, ["binding 'nokey': unknown key 'nokey'"])
        XCTAssertEqual(registrar.registered, 2)
        XCTAssertEqual(mac.wm.mode, "move", "esc still leads out")
    }

    func testAShortcutTheSystemRefusesIsAProblemAndNotCounted() {
        registrar.start()
        service.refused = ["option-r"]
        registrar.register()
        XCTAssertEqual(registrar.problems, [
            "binding 'option-r': the system refused it (another app may own this shortcut)", modeWarning,
        ])
        XCTAssertEqual(registrar.registered, mac.wm.config.bindings.count - 1)
        XCTAssertFalse(service.keys.contains("option-r"))
    }

    func testAModeKeepsGoingWhileOneWayOutIsLeft() {
        registrar.start()
        mac.run("mode resize")
        service.refused = ["esc"]
        registrar.register()
        XCTAssertEqual(mac.wm.mode, "resize", "return still leaves it")
        XCTAssertEqual(registrar.registered, 3)
        XCTAssertEqual(mac.logged("no key to leave it"), [])
    }

    func testAModeWithNoWayOutIsLeftAtOnce() {
        registrar.start()
        mac.run("mode resize")
        var modeChanges = 0
        mac.wm.onModeChange = { modeChanges += 1 }
        service.refused = ["esc", "return"]
        registrar.register()

        XCTAssertEqual(mac.wm.mode, Config.defaultMode)
        XCTAssertEqual(modeChanges, 1, "which is what makes the app register the default shortcuts")
        XCTAssertEqual(mac.logged("no key to leave it"), ["mode resize: no key to leave it could be registered; back to the default shortcuts"])
        XCTAssertEqual(registrar.problems.suffix(1), [modeWarning], "the other modes are checked as from [bindings]")

        registrar.register()
        XCTAssertEqual(service.keys, mac.wm.config.bindings.map(\.source))
    }

    func testAPressedShortcutRunsItsCommandAndIsRemembered() {
        registrar.start()
        registrar.register()
        XCTAssertNil(registrar.last)

        XCTAssertTrue(service.press("option-r"))
        XCTAssertEqual(mac.wm.mode, "resize")
        XCTAssertEqual(registrar.last?.keys, "option-r")
        XCTAssertEqual(registrar.last?.reply, "ok")
        XCTAssertEqual(registrar.last?.at, clock)
        XCTAssertEqual(mac.logged("option-r:"), [], "a shortcut that worked is not logged")
    }

    func testAShortcutThatFailsIsLogged() {
        registrar.start()
        registrar.register()
        answer = "error: no such thing"
        service.press("option-r")
        XCTAssertEqual(registrar.last?.reply, "error: no such thing")
        XCTAssertEqual(mac.logged("option-r:"), ["option-r: error: no such thing"])
        XCTAssertEqual(mac.wm.mode, Config.defaultMode)
    }

    func testEveryShortcutCanBeReleased() {
        registrar.start()
        registrar.register()
        registrar.unregisterAll()
        XCTAssertEqual(service.keys, [])
        XCTAssertFalse(service.press("option-r"))
    }

    func testAConfigThatChangedIsRegisteredAgain() {
        registrar.start()
        mac.wm.onConfigChange = { [unowned self] in registrar.register() }
        mac.writeConfig("""
        [bindings]
        option-y = "balance"
        """)
        XCTAssertTrue(service.keys.contains("option-y"))
        XCTAssertFalse(service.keys.contains("option-r"))
        XCTAssertEqual(registrar.problems, [], "the mode with the mistyped key is gone")
    }
}
