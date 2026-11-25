import XCTest
import IguanaCore
@testable import iguana

/// What the app shell adds to `status`, as text and as JSON.
final class ShellReportTests: ScenarioTestCase {
    var service: FakeShortcutService!
    var shortcuts: HotkeyRegistrar!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var tourShowing = false
    var tilingHeld = false
    var update: UpdateCheck.Update?
    var report: ShellReport!

    override func makeScenario() -> Scenario { Scenario(config: ShellFakes.modes) }

    override func setUp() {
        super.setUp()
        tourShowing = false
        tilingHeld = false
        update = nil
        let wm = mac.wm!
        let service = FakeShortcutService()
        let shortcuts = HotkeyRegistrar(wm: wm, makeService: { service }, now: { [unowned self] in clock }) { wm.run($0.command) }
        report = ShellReport(wm: wm, shortcuts: shortcuts, tourShowing: { [unowned self] in tourShowing },
                             tilingHeld: { [unowned self] in tilingHeld }, knownUpdate: { [unowned self] in update },
                             now: { [unowned self] in clock })
        self.service = service
        self.shortcuts = shortcuts
    }

    override func tearDown() {
        report = nil
        shortcuts = nil
        service = nil
        super.tearDown()
    }

    func status() throws -> Report.Status {
        try JSONDecoder().decode(Report.Status.self, from: Data(report.json(.status).utf8))
    }

    func testBeforeAnyShortcutIsRegistered() throws {
        XCTAssertEqual(report.statusLines(), ["shortcuts: 0 active", "last shortcut: none received since Iguana started"])
        let status = try status()
        XCTAssertEqual(status.shortcuts, Report.Shortcuts(active: 0, warnings: []))
        XCTAssertNil(status.lastShortcut)
        XCTAssertFalse(status.tourShowing)
        XCTAssertNil(status.update)
    }

    func testTheShortcutsAndTheirProblems() throws {
        shortcuts.start()
        service.refused = ["option-r"]
        shortcuts.register()
        let count = mac.wm.config.bindings.count - 1
        let problems = ["binding 'option-r': the system refused it (another app may own this shortcut)",
                        "binding 'nokey' in [mode.move]: unknown key 'nokey'"]
        XCTAssertEqual(report.statusLines(), ["shortcuts: \(count) active"] + problems.map { "  warning: \($0)" }
            + ["last shortcut: none received since Iguana started"])
        XCTAssertEqual(try status().shortcuts, Report.Shortcuts(active: count, warnings: problems))
    }

    func testTheLastShortcutAndHowLongAgo() throws {
        shortcuts.start()
        shortcuts.register()
        service.press("option-r")
        clock.addTimeInterval(7.9)
        XCTAssertEqual(report.statusLines().last, "last shortcut: option-r, 7 s ago, answered \"ok\"")
        let status = try status()
        XCTAssertEqual(status.lastShortcut, Report.LastShortcut(keys: "option-r", secondsAgo: 7, reply: "ok"))
        XCTAssertEqual(status.mode, "resize")
    }

    func testTheTourOnScreen() throws {
        tourShowing = true
        XCTAssertEqual(report.statusLines()[1], "welcome tour: on screen; shortcuts act on its practice desktop")
        tilingHeld = true
        XCTAssertEqual(report.statusLines()[1], "welcome tour: on screen; tiling starts when it ends")
        XCTAssertTrue(try status().tourShowing)

        tourShowing = false
        XCTAssertFalse(report.statusLines().contains { $0.hasPrefix("welcome tour") }, "held or not, a tour that is gone is not mentioned")
    }

    func testANewerRelease() throws {
        update = ShellFakes.update("9.9.9")
        XCTAssertEqual(report.statusLines().last, UpdateCheck.statusLine(ShellFakes.update("9.9.9")))
        XCTAssertEqual(try status().update, Report.Update(version: "9.9.9", url: ShellFakes.update("9.9.9").page.absoluteString))
    }

    func testTheLinesAreTheEndOfTheStatusText() {
        mac.wm.statusExtras = report.statusLines
        let text = mac.run("status")
        XCTAssertTrue(text.hasSuffix("shortcuts: 0 active\nlast shortcut: none received since Iguana started"), text)
    }
}
