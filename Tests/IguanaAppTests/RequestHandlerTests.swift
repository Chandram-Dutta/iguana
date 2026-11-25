import XCTest
import IguanaCore
@testable import iguana

/// Who answers a line from the command socket, with each of them played by the test.
final class RequestHandlerTests: XCTestCase {
    var ran: [(command: Command, window: CGWindowID?)] = []
    var offeredToTour: [(command: Command, window: CGWindowID?)] = []
    var reports: [Command] = []
    var tourAnswer: String?
    /// Update checks that were asked for and have not been answered.
    var checks: [(UpdateCheck.Outcome) -> Void] = []
    var handler: RequestHandler!

    override func setUp() {
        ran = []
        offeredToTour = []
        reports = []
        tourAnswer = nil
        checks = []
        handler = RequestHandler(
            run: { [unowned self] command, window in
                ran.append((command, window))
                return "ok: ran"
            },
            tourReply: { [unowned self] command, window in
                offeredToTour.append((command, window))
                return tourAnswer
            },
            jsonReport: { [unowned self] command in
                reports.append(command)
                return "{}"
            },
            checkForUpdate: { [unowned self] completion in checks.append(completion) },
            version: "1.2.3")
    }

    func testACommandGoesToTheWindowManager() throws {
        XCTAssertEqual(handler.reply(to: "focus left"), "ok: ran")
        XCTAssertEqual(ran.map(\.command), [try Command.parse("focus left")])
        XCTAssertEqual(ran.map(\.window), [nil])
        XCTAssertEqual(reports, [])
    }

    func testTheWindowNamedIsPassedOn() throws {
        XCTAssertEqual(handler.reply(to: "close --window 42"), "ok: ran")
        XCTAssertEqual(ran.map(\.command), [.close])
        XCTAssertEqual(ran.map(\.window), [42])
        XCTAssertEqual(offeredToTour.map(\.window), [42], "the tour is told which window, so that it can refuse")
    }

    func testAJSONReportIsNotRunAsACommand() {
        XCTAssertEqual(handler.reply(to: "status --json"), "{}")
        XCTAssertEqual(reports, [.status])
        XCTAssertTrue(ran.isEmpty)
        XCTAssertTrue(offeredToTour.isEmpty, "a report is about the real windows, tour or no tour")
    }

    func testTheTourAnswersInPlaceOfTheWindowManager() {
        tourAnswer = "ok: on the practice desktop"
        XCTAssertEqual(handler.reply(to: "balance"), "ok: on the practice desktop")
        XCTAssertEqual(offeredToTour.map(\.command), [.balance])
        XCTAssertTrue(ran.isEmpty)
    }

    func testALineThatIsNotACommandIsAnErrorAndRunsNothing() {
        for line in ["", "no-such-command", "status --json --window 3", "focus left --window abc"] {
            XCTAssertTrue(handler.reply(to: line).hasPrefix("error: "), line)
        }
        XCTAssertEqual(handler.reply(to: "status --json --window 3"), "error: use --json or --window, not both")
        XCTAssertTrue(ran.isEmpty)
        XCTAssertTrue(reports.isEmpty)
        XCTAssertTrue(offeredToTour.isEmpty)
    }

    func testEveryCommandButUpdateAnswersAtOnce() {
        var replies: [String] = []
        handler.handle("balance") { replies.append($0) }
        handler.handle("status --json") { replies.append($0) }
        handler.handle("no-such-command") { replies.append($0) }
        XCTAssertEqual(replies.count, 3)
        XCTAssertEqual(Array(replies.prefix(2)), ["ok: ran", "{}"])
        XCTAssertTrue(replies[2].hasPrefix("error: "))
        XCTAssertTrue(checks.isEmpty)
    }

    func testUpdateAnswersWhenTheCheckHasAnswered() {
        var replies: [String] = []
        handler.handle("update") { replies.append($0) }
        XCTAssertEqual(replies, [], "nothing is said until GitHub has answered")
        XCTAssertEqual(checks.count, 1)
        XCTAssertTrue(ran.isEmpty, "the window manager is not asked as well")

        checks[0](.latest)
        XCTAssertEqual(replies, ["ok: Iguana 1.2.3 is the latest version"])
    }

    func testUpdateSaysWhatTheCheckFound() {
        var replies: [String] = []
        handler.handle("update") { replies.append($0) }
        handler.handle("update") { replies.append($0) }
        checks[0](.newer(ShellFakes.update("9.9.9")))
        checks[1](.failed("offline"))
        XCTAssertEqual(replies.count, 2)
        XCTAssertTrue(replies[0].hasPrefix("ok: Iguana 9.9.9 is available at https://"), replies[0])
        XCTAssertEqual(replies[1], "error: could not check for a newer version: offline")
    }

    func testAMistypedUpdateAsksNoOne() {
        var replies: [String] = []
        handler.handle("update --json") { replies.append($0) }
        XCTAssertEqual(replies.count, 1)
        XCTAssertTrue(replies[0].hasPrefix("error: "))
        XCTAssertTrue(checks.isEmpty)
    }
}

/// The same lines, answered by the real window manager on a made-up Mac, wired as the app
/// wires it.
final class RequestScenarioTests: ScenarioTestCase {
    var service: FakeShortcutService!
    var shortcuts: HotkeyRegistrar!
    var handler: RequestHandler!

    override func setUp() {
        super.setUp()
        let wm = mac.wm!
        let service = FakeShortcutService()
        let shortcuts = HotkeyRegistrar(wm: wm, makeService: { service }) { wm.run($0.command) }
        let report = ShellReport(wm: wm, shortcuts: shortcuts, tourShowing: { false }, tilingHeld: { false }, knownUpdate: { nil })
        wm.statusExtras = report.statusLines
        handler = RequestHandler(run: { wm.run($0, window: $1) }, tourReply: { _, _ in nil }, jsonReport: report.json,
                                 checkForUpdate: { $0(.latest) })
        shortcuts.start()
        shortcuts.register()
        self.service = service
        self.shortcuts = shortcuts
    }

    override func tearDown() {
        handler = nil
        shortcuts = nil
        service = nil
        super.tearDown()
    }

    func testACommandMovesTheRealWindows() {
        let app = mac.system.launch("Terminal")
        let first = mac.system.open(app)
        mac.settle()
        let second = mac.system.open(app)
        mac.settle()
        XCTAssertEqual(mac.focused, second.id)

        XCTAssertEqual(handler.reply(to: "focus left"), "ok")
        mac.settle()
        XCTAssertEqual(mac.focused, first.id)

        XCTAssertEqual(handler.reply(to: "move right --window \(first.id)"), "ok")
        mac.settle()
        XCTAssertEqual(mac.tiledInReadingOrder, [second.id, first.id])
    }

    func testStatusSaysWhatTheShellKnowsInTextAndInJSON() throws {
        let count = Config.default.bindings.count
        XCTAssertTrue(handler.reply(to: "status").contains("shortcuts: \(count) active"))
        XCTAssertTrue(handler.reply(to: "status").contains("last shortcut: none received since Iguana started"))

        let status = try JSONDecoder().decode(Report.Status.self, from: Data(handler.reply(to: "status --json").utf8))
        XCTAssertEqual(status.shortcuts, Report.Shortcuts(active: count, warnings: []))
        XCTAssertFalse(status.tourShowing)
        XCTAssertNil(status.lastShortcut)
        XCTAssertNil(status.update)
    }

    func testAReportListsTheWindowsOfTheMadeUpMac() throws {
        let window = mac.system.open(mac.system.launch("Notes"), title: "Shopping")
        mac.settle()
        let report = try JSONDecoder().decode(Report.Windows.self, from: Data(handler.reply(to: "list-windows --json").utf8))
        XCTAssertEqual(report.windows.map(\.id), [window.id])
    }

    func testUpdateIsAnsweredByTheCheckAndNotByTheWindowManager() {
        var replies: [String] = []
        handler.handle("update") { replies.append($0) }
        XCTAssertEqual(replies, ["ok: Iguana \(Iguana.version) is the latest version"])
    }
}
