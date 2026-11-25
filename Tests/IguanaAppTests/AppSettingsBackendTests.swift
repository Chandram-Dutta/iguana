import XCTest
import IguanaCore
@testable import iguana

/// What the settings window is told by, and does to, the running app.
final class AppSettingsBackendTests: ScenarioTestCase {
    var service: FakeShortcutService!
    var shortcuts: HotkeyRegistrar!
    var watcher: ConfigWatcher!
    var trusted = true
    var update: UpdateCheck.Update?
    var changes = 0
    var asked = 0
    var suite: String!
    var backend: AppSettingsBackend!

    override func makeScenario() -> Scenario { Scenario(config: ShellFakes.modes) }

    override func setUp() {
        super.setUp()
        trusted = true
        update = nil
        changes = 0
        asked = 0
        let wm = mac.wm!
        let url = mac.configURL
        let service = FakeShortcutService()
        shortcuts = HotkeyRegistrar(wm: wm, makeService: { service }) { wm.run($0.command) }
        shortcuts.start()
        shortcuts.register()
        watcher = ConfigWatcher { url }
        watcher.mark()
        // What the update check remembers goes to a throwaway place, and GitHub is the test.
        suite = "iguana-backend-tests-\(UUID().uuidString)"
        let updates = UpdateChecker(defaults: UserDefaults(suiteName: suite)!, running: "0.1.0", log: { _ in }) { [unowned self] answer in
            asked += 1
            answer(.success((200, UpdateCheckerTests.release())))
        }
        backend = AppSettingsBackend(wm: wm, shortcuts: shortcuts, configWatcher: watcher, updates: updates,
                                     knownUpdate: { [unowned self] in update }, trusted: { [unowned self] in trusted },
                                     onChange: { [unowned self] in changes += 1 })
        self.service = service
    }

    override func tearDown() {
        backend = nil
        watcher = nil
        shortcuts = nil
        service = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testItSaysWhatTheWindowManagerKnows() {
        let app = mac.system.launch("Terminal")
        mac.system.open(app)
        mac.settle()
        XCTAssertEqual(backend.config, mac.wm.config)
        XCTAssertEqual(backend.tiledWindowCount, 1)
        XCTAssertFalse(backend.isPaused)
        XCTAssertFalse(backend.needsPermission)
        XCTAssertNil(backend.availableUpdate)

        trusted = false
        update = ShellFakes.update()
        XCTAssertTrue(backend.needsPermission)
        XCTAssertEqual(backend.availableUpdate, ShellFakes.update())
    }

    func testProblemsAreThoseOfTheConfigThenThoseOfTheShortcuts() {
        XCTAssertEqual(backend.problems, ["binding 'nokey' in [mode.move]: unknown key 'nokey'"])
        mac.writeConfig("no-such-key = 1\n" + ShellFakes.modes)
        shortcuts.register()
        XCTAssertEqual(backend.problems.count, 2)
        XCTAssertEqual(backend.problems.first, mac.wm.configWarnings.first)
        XCTAssertEqual(backend.problems.last, "binding 'nokey' in [mode.move]: unknown key 'nokey'")
    }

    func testASaveFromTheSettingsWindowIsReadOnce() throws {
        try Data("[gaps]\ninner = 20\n".utf8).write(to: mac.configURL)
        backend.reloadConfig()
        mac.settle()
        XCTAssertEqual(backend.config.gapInner, 20)
        XCTAssertEqual(changes, 1, "the menu bar item is drawn again")
        XCTAssertFalse(watcher.changed(), "the watcher does not make the app read the same file again")
    }

    func testPausingFromTheSettingsWindow() {
        backend.setPaused(true)
        mac.settle()
        XCTAssertTrue(mac.wm.paused)
        XCTAssertTrue(backend.isPaused)
        XCTAssertEqual(changes, 1)
        backend.setPaused(false)
        mac.settle()
        XCTAssertFalse(backend.isPaused)
        XCTAssertEqual(changes, 2)
    }

    func testShortcutsAreReleasedWhileOneIsRecordedAndComeBackAsThoseOfBindings() {
        mac.run("mode resize")
        shortcuts.register()
        XCTAssertEqual(service.keys, ["h", "l", "return", "esc"])

        backend.suspendShortcuts(true)
        XCTAssertEqual(service.keys, [])
        XCTAssertEqual(mac.wm.mode, "resize", "nothing else changes while the keys are released")

        backend.suspendShortcuts(false)
        XCTAssertEqual(mac.wm.mode, Config.defaultMode, "a mode does not outlast the pause")
        XCTAssertEqual(service.keys, mac.wm.config.bindings.map(\.source))
    }

    func testThePreviewNeedsTwoWindows() {
        let app = mac.system.launch("Terminal")
        let first = mac.system.open(app)
        mac.settle()
        XCTAssertNil(backend.desktopPreview(), "one window is too little to show")

        let second = mac.system.open(app)
        mac.settle()
        let preview = backend.desktopPreview()
        XCTAssertEqual(preview?.visible, [first.id, second.id])
        XCTAssertEqual(preview?.focused, second.id)
        XCTAssertEqual(preview?.screen, CGSize(width: 1440, height: 900))
        XCTAssertEqual(preview?.isExample, false)
    }

    func testCheckingForAnUpdateAsksTheChecker() {
        let answered = expectation(description: "the check answers")
        var outcome: UpdateCheck.Outcome?
        backend.checkForUpdate {
            outcome = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(asked, 1)
        guard case .newer(let found)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(found.version, "0.1.3")
    }
}
