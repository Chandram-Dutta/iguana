import XCTest
import IguanaCore
@testable import iguana

/// Reading the config file: what the reply says, what is kept when the file is wrong, and what
/// happens to the windows and to the mode that is on.
final class ConfigReloadScenarioTests: ScenarioTestCase {
    private var path: String { mac.configURL.path }

    /// The lines of the log about reading the config.
    private var configLog: [String] { mac.log.filter { $0.hasPrefix("config: ") } }

    /// Two windows side by side, to see the gaps by.
    private func openTwoWindows() -> (left: FakeWindow, right: FakeWindow) {
        let app = mac.system.launch("Terminal")
        let left = mac.system.open(app, title: "One")
        mac.settle()
        let right = mac.system.open(app, title: "Two")
        mac.settle()
        return (left, right)
    }

    func testWithoutAFileTheBuiltInSettingsAreUsed() {
        let none = "ok: no config file at \(path), using the built-in defaults (`iguana config init` writes one)"
        XCTAssertEqual(mac.run("reload"), none)
        XCTAssertEqual(mac.wm.config, .default)
        XCTAssertTrue(mac.wm.configWarnings.isEmpty)

        // A file is written, and later thrown away.
        let (left, right) = openTwoWindows()
        mac.writeConfig("[gaps]\ninner = 40\n")
        XCTAssertEqual(right.rect.minX - left.rect.maxX, 40, accuracy: 1)

        try? FileManager.default.removeItem(at: mac.configURL)
        XCTAssertEqual(mac.run("reload"), none)
        XCTAssertEqual(mac.wm.config, .default)
        XCTAssertFrame(left.rect, CGRect(x: 8, y: 33, width: 708, height: 859), "back to the built-in gaps")
        XCTAssertFrame(right.rect, CGRect(x: 724, y: 33, width: 708, height: 859))
    }

    func testAValidFileIsLoadedAndItsGapsAreAppliedAtOnce() {
        let (left, right) = openTwoWindows()

        let reply = mac.writeConfig("""
        [gaps]
        inner = 20
        outer = 30
        """)

        XCTAssertEqual(reply, "ok: loaded \(path)")
        XCTAssertTrue(mac.wm.configWarnings.isEmpty)
        XCTAssertFrame(left.rect, CGRect(x: 30, y: 55, width: 680, height: 815))
        XCTAssertFrame(right.rect, CGRect(x: 730, y: 55, width: 680, height: 815))
        XCTAssertEqual(mac.usable(), CGRect(x: 30, y: 55, width: 1380, height: 815))
        XCTAssertEqual(mac.run("reload"), reply, "the reload command reads the file the same way")
    }

    func testAFileWithMistakesIsLoadedAndTheReplyListsThem() {
        let (left, right) = openTwoWindows()

        let reply = mac.writeConfig("""
        [gaps]
        inner = 20
        colour = "green"

        [[rule]]
        app = "Notes"
        float = false
        size = [400, 600]
        """)

        let warnings = [
            "unknown key 'colour' in [gaps]",
            "rule 1: size is only for windows the rule floats, so it has no effect here",
        ]
        XCTAssertEqual(reply, "ok: loaded \(path) with warnings:\n  - \(warnings[0])\n  - \(warnings[1])")
        XCTAssertEqual(mac.wm.configWarnings, warnings)
        XCTAssertEqual(right.rect.minX - left.rect.maxX, 20, accuracy: 1, "what is right in the file is used")
    }

    func testAFileThatCannotBeParsedKeepsThePreviousSettings() {
        let (left, right) = openTwoWindows()
        mac.writeConfig("""
        [gaps]
        inner = 20

        [[rule]]
        app = "Notes"
        float = true
        """)
        let notes = mac.system.open(mac.system.launch("Notes"), frame: CGRect(x: 300, y: 200, width: 400, height: 300))
        mac.settle()
        let before = (left.rect, right.rect)

        let reply = mac.writeConfig("[gaps]\ninner = \"40\n")

        XCTAssertEqual(reply, "error: \(path): line 2: string is not closed\n(keeping the previous settings)")
        XCTAssertEqual(mac.wm.configWarnings, ["line 2: string is not closed"], "the settings window shows what is wrong")
        XCTAssertEqual(mac.wm.config.gapInner, 20)
        XCTAssertEqual(left.rect, before.0)
        XCTAssertEqual(right.rect, before.1)
        XCTAssertNil(mac.tiles[notes.id], "the rule of the last good file still floats its window")
    }

    func testAFileThatIsNotTextKeepsThePreviousSettings() throws {
        mac.writeConfig("[gaps]\ninner = 20\n")
        let (left, right) = openTwoWindows()

        try Data([0xFF, 0xFE, 0xC3, 0x28]).write(to: mac.configURL)
        let reply = mac.run("reload")

        XCTAssertEqual(reply, "error: \(path) cannot be read as UTF-8 text\n(keeping the previous settings)")
        XCTAssertEqual(mac.wm.configWarnings, ["the config file cannot be read as UTF-8 text"])
        XCTAssertEqual(mac.wm.config.gapInner, 20, "not taken for a missing file, which would mean the defaults")
        XCTAssertEqual(right.rect.minX - left.rect.maxX, 20, accuracy: 1)
    }

    func testTheLogOnlySaysWhatIsNew() {
        // The file was read once as Iguana started.
        XCTAssertEqual(configLog.count, 1)
        mac.run("reload")
        mac.run("reload")
        XCTAssertEqual(configLog.count, 1, "the same answer is not written again")

        let loaded = mac.writeConfig("[gaps]\ninner = 20\n")
        // The settings window saves many times a second while a slider is dragged.
        mac.writeConfig("[gaps]\ninner = 21\n")
        mac.writeConfig("[gaps]\ninner = 22\n")
        XCTAssertEqual(configLog.count, 2)
        XCTAssertEqual(configLog.last, "config: \(loaded)")

        let broken = mac.writeConfig("[gaps\n")
        mac.run("reload")
        XCTAssertEqual(configLog.count, 3)
        XCTAssertEqual(configLog.last, "config: \(broken)")

        mac.writeConfig("[gaps]\ninner = 20\n")
        XCTAssertEqual(configLog.count, 4, "the answer changed back, so it is said again")
    }

    func testEveryReadingTellsTheAppShell() {
        var told = 0
        mac.wm.onConfigChange = { told += 1 }

        mac.writeConfig("[gaps]\ninner = 20\n")
        XCTAssertEqual(told, 1)
        mac.run("reload")
        XCTAssertEqual(told, 2, "also when nothing in the file changed")
        mac.writeConfig("[gaps\n")
        XCTAssertEqual(told, 3, "and when the file is wrong, so that the warning can be shown")
    }

    func testAModeThatIsNoLongerInTheFileIsLeft() {
        var changes = 0
        mac.wm.onModeChange = { changes += 1 }
        mac.writeConfig("""
        [mode.resize]
        h = "resize shrink width"
        l = "resize grow width"
        """)
        XCTAssertEqual(mac.run("mode resize"), "ok")
        XCTAssertEqual(mac.wm.mode, "resize")
        XCTAssertEqual(changes, 1)

        mac.writeConfig("[gaps]\ninner = 8\n")

        XCTAssertEqual(mac.wm.mode, Config.defaultMode)
        XCTAssertEqual(changes, 2, "the app shell is told, so that it puts the usual shortcuts back")
        XCTAssertEqual(mac.run("mode resize"), "error: no mode 'resize'")
    }

    func testAModeWhoseShortcutsChangedIsLeft() {
        mac.writeConfig("""
        [mode.resize]
        h = "resize shrink width"
        """)
        mac.run("mode resize")
        XCTAssertEqual(mac.wm.mode, "resize")

        mac.writeConfig("""
        [mode.resize]
        h = "resize grow width"
        """)

        XCTAssertEqual(mac.wm.mode, Config.defaultMode, "left, so that no key does what it did not say when the mode was entered")
        XCTAssertEqual(mac.run("mode resize"), "ok", "the mode is still there to go back into")
    }

    func testAModeThatIsUnchangedStaysOnThroughAReload() {
        let modes = """
        [mode.resize]
        h = "resize shrink width"

        """
        var changes = 0
        mac.writeConfig(modes)
        XCTAssertEqual(mac.run("mode nowhere"), "error: no mode 'nowhere'")
        mac.run("mode resize")
        mac.wm.onModeChange = { changes += 1 }

        mac.writeConfig(modes + "[gaps]\ninner = 20\n")
        XCTAssertEqual(mac.wm.mode, "resize", "only the gaps changed")

        mac.writeConfig("[mode.resize\n")
        XCTAssertEqual(mac.wm.mode, "resize", "a file that cannot be read changes nothing")

        XCTAssertEqual(mac.run("mode resize"), "ok")
        XCTAssertEqual(changes, 0, "going into the mode that is on already is no change")
        XCTAssertEqual(mac.run("mode default"), "ok")
        XCTAssertEqual(mac.wm.mode, Config.defaultMode)
        XCTAssertEqual(changes, 1)
    }
}
