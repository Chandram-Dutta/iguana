import XCTest
import IguanaCore
@testable import iguana

/// Running the commands of `[hooks]`: real `/bin/sh` runs that write into a throwaway folder.
final class HookRunnerTests: XCTestCase {
    var folder: URL!
    var logged: [String] = []
    var runner: HookRunner!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iguana-hooks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        logged = []
        runner = HookRunner { [unowned self] in self.logged.append($0) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func path(_ name: String) -> String { folder.appendingPathComponent(name).path }
    func contents(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }

    /// The runner reports back on the main queue, so waiting means letting the main run loop turn.
    @discardableResult
    func wait(_ seconds: TimeInterval = 5, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }

    func testFactsReachTheCommandAsVariablesAndAreNeverRunAsCode() {
        // Everything a shell would act on if the title were pasted into the command.
        let title = "$(touch '\(path("pwned"))'); `touch '\(path("pwned"))'` \"; touch '\(path("pwned"))' #\n&& touch '\(path("pwned"))'"
        let variables = HookEnvironment.variables(event: .focusChanged, desktop: 2, display: "Studio Display", window: (1187, "Safari", title))
        let command = "printf '%s|%s|%s|%s|%s|' \"$IGUANA_EVENT\" \"$IGUANA_DESKTOP\" \"$IGUANA_DISPLAY\" \"$IGUANA_WINDOW_ID\" \"$IGUANA_APP\" > '\(path("facts"))';"
            + " printf '%s' \"$IGUANA_TITLE\" > '\(path("title"))'; touch '\(path("done"))'"
        runner.fire(.focusChanged, command: command, variables: variables)

        XCTAssertTrue(wait { FileManager.default.fileExists(atPath: path("done")) }, "the command ran")
        XCTAssertEqual(contents("facts"), "focus-changed|2|Studio Display|1187|Safari|")
        XCTAssertEqual(contents("title"), title, "the title arrives exactly as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("pwned")), "nothing in the title was run")
        XCTAssertEqual(logged, [])
    }

    func testFiringReturnsAtOnce() {
        let started = Date()
        runner.fire(.desktopChanged, command: "sleep 2", variables: [:])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "the command is never waited for")
    }

    func testASlowHookDoesNotPileUp() {
        let command = "echo \"$IGUANA_DESKTOP\" >> '\(path("seen"))'; sleep 0.5"
        for desktop in 1...6 {
            runner.fire(.desktopChanged, command: command, variables: HookEnvironment.variables(event: .desktopChanged, desktop: desktop, display: "D"))
        }
        XCTAssertTrue(wait { contents("seen") == "1\n6\n" }, "the first run, then one more with the newest desktop: \(contents("seen") ?? "nothing")")
        // Give a run that should not exist the time to show up.
        wait(0.8) { false }
        XCTAssertEqual(contents("seen"), "1\n6\n")
        XCTAssertEqual(logged.count, 1, "said once, not five times: \(logged)")
        XCTAssertTrue(logged[0].contains("desktop-changed") && logged[0].contains("has not ended"))

        // Each hook waits only for itself: a busy desktop hook does not hold up the focus hook.
        runner.fire(.desktopChanged, command: "sleep 4", variables: [:])
        runner.fire(.focusChanged, command: "touch '\(path("focus"))'", variables: [:])
        XCTAssertTrue(wait(2) { FileManager.default.fileExists(atPath: path("focus")) })
    }

    func testAFailingHookIsLoggedOnce() {
        let command = "echo x >> '\(path("runs"))'; exit 3"
        for round in 1...3 {
            runner.fire(.focusChanged, command: command, variables: [:])
            XCTAssertTrue(wait { runner.isIdle })
            XCTAssertEqual(contents("runs")?.count, 2 * round, "it still runs every time")
        }
        XCTAssertEqual(logged.count, 1, "\(logged)")
        XCTAssertTrue(logged[0].contains("focus-changed") && logged[0].contains("status 3"))

        // A command that was changed in the config file and fails again is news again.
        runner.fire(.focusChanged, command: "exit 4", variables: [:])
        XCTAssertTrue(wait { logged.count == 2 })
        XCTAssertTrue(logged[1].contains("status 4"))
    }

    func testACommandTheShellCannotFindSaysSo() {
        runner.fire(.desktopChanged, command: "iguana-test-no-such-command-\(UUID().uuidString)", variables: [:])
        XCTAssertTrue(wait { !logged.isEmpty })
        XCTAssertTrue(logged[0].contains("status 127") && logged[0].contains("full path"), "\(logged)")
    }

    func testAChangedCommandIsNotHeldUpByTheOldOne() {
        runner.fire(.desktopChanged, command: "sleep 3", variables: [:])
        runner.fire(.desktopChanged, command: "touch '\(path("new"))'", variables: [:])
        XCTAssertTrue(wait(1) { FileManager.default.fileExists(atPath: path("new")) }, "fixing a stuck hook in the config file takes effect at once")
        XCTAssertEqual(logged, [])
    }

    func testTheCommandFindsHomebrewAndStartsAtHome() {
        runner.fire(.desktopChanged, command: "printf '%s\\n%s' \"$PATH\" \"$PWD\" > '\(path("where"))'", variables: [:])
        XCTAssertTrue(wait { (contents("where") ?? "").contains("\n") })
        let lines = (contents("where") ?? "").components(separatedBy: "\n")
        XCTAssertTrue(lines[0].split(separator: ":").contains("/opt/homebrew/bin"), lines[0])
        XCTAssertEqual(URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath().path,
                       FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)
    }
}

/// Hooks have no pane in the settings window. What the window must do is leave them alone.
final class SettingsKeepHooksTests: XCTestCase {
    func testTheSettingsWindowKeepsAHooksSection() throws {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        let hooks = """
        # My status bar listens for these.
        [hooks]
        desktop-changed = "sketchybar --trigger iguana_desktop"   # one trigger per switch
        focus-changed = 'echo "$IGUANA_TITLE" >> "$HOME/focus.log"'
        """
        try ConfigFile.write("[gaps]\ninner = 4\n\n\(hooks)\n\n[[rule]]\napp = \"Calculator\"\n", to: backend.configURL)
        backend.reloadConfig()
        let model = SettingsModel(backend: backend)
        var text: String { (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? "" }
        XCTAssertEqual(model.config.hooks.count, 2)

        // One of everything the window can write.
        model.setNumber(["gaps", "inner"], 14)
        model.setOuterGap(Edges(all: 20))
        model.set(["animation", "enabled"], .bool(false))
        model.set(["menu-bar", "desktops"], .string("all"))
        model.bind("cmd-option-left", to: "focus left", replacing: model.config.bindings.first { $0.source == "option-h" })
        model.bind("ctrl-option-z", to: "zoom", replacing: nil)
        model.unbind(try XCTUnwrap(model.config.bindings.first { $0.source == "option-slash" }))
        model.setRules([Rule(app: "Preview", title: nil), Rule(app: nil, title: "^Inspector")])
        model.setRules([])
        model.setRules([Rule(app: "Notes", title: nil)])
        model.resetShortcuts()

        XCTAssertTrue(text.contains(hooks), "the section is in the file exactly as it was written:\n\(text)")
        XCTAssertEqual(model.config.hooks, [
            .desktopChanged: "sketchybar --trigger iguana_desktop",
            .focusChanged: "echo \"$IGUANA_TITLE\" >> \"$HOME/focus.log\"",
        ])
        XCTAssertEqual(model.problems, [])
        // And the changes themselves took.
        XCTAssertEqual(model.config.gapInner, 14)
        XCTAssertEqual(model.config.menuBarDesktops, .all)
        XCTAssertEqual(model.config.rules, [Rule(app: "Notes", title: nil)])
    }

    func testAFileTheWindowCreatesHasTheHooksToFillIn() {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        let model = SettingsModel(backend: backend)
        model.setNumber(["gaps", "inner"], 14)
        let text = (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("[hooks]\ndesktop-changed = \"\""))
        XCTAssertEqual(model.config.hooks, [:])
    }
}
