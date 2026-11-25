import XCTest
import IguanaCore
@testable import iguana

/// The settings window's logic, run against a throwaway config file.
final class SettingsModelTests: XCTestCase {
    final class FakeBackend: SettingsBackend {
        let configURL: URL
        var config = Config.default
        var problems: [String] = []
        var isPaused = false
        var suspensions: [Bool] = []

        init() {
            configURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("iguana-tests-\(UUID().uuidString)/iguana.toml")
        }

        func reloadConfig() {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
                config = .default
                return
            }
            if let loaded = try? Config.load(text) { (config, problems) = loaded }
        }

        func setPaused(_ paused: Bool) { isPaused = paused }
        func suspendShortcuts(_ suspended: Bool) { suspensions.append(suspended) }
    }

    var backend: FakeBackend!
    var model: SettingsModel!

    override func setUp() {
        backend = FakeBackend()
        model = SettingsModel(backend: backend)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent())
    }

    var fileText: String { (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? "" }

    func source(of commandText: String) -> [String] {
        model.config.bindings.filter { $0.commandText == commandText }.map(\.source).sorted()
    }

    func testFirstChangeCreatesADocumentedFileAndTheSchema() {
        XCTAssertFalse(model.fileExists)
        model.setNumber(["gaps", "inner"], 14)
        XCTAssertTrue(model.fileExists)
        XCTAssertEqual(model.config.gapInner, 14)
        XCTAssertTrue(fileText.contains("# Iguana configuration."), "the new file keeps the explanatory comments")
        XCTAssertTrue(fileText.contains("inner = 14"))
        XCTAssertEqual(fileText.components(separatedBy: "\n").count, (Config.defaultText + "\n").components(separatedBy: "\n").count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backend.configURL.deletingLastPathComponent().appendingPathComponent("iguana.schema.json").path))
        XCTAssertEqual(model.problems, [])
    }

    func testEditsKeepHandWrittenComments() throws {
        try ConfigFile.write("# mine\n[gaps]\ninner = 4   # tight\n", to: backend.configURL)
        backend.reloadConfig()
        model.refresh()
        model.setNumber(["gaps", "inner"], 9)
        model.set(["animation", "enabled"], .bool(false))
        XCTAssertTrue(fileText.hasPrefix("# mine\n[gaps]\ninner = 9   # tight\n"))
        XCTAssertFalse(model.config.animate)
        XCTAssertEqual(model.config.bindings.count, 45, "a file without [bindings] keeps every built-in shortcut")
    }

    func testOuterGap() {
        model.setOuterGap(Edges(all: 20))
        XCTAssertEqual(model.config.gapOuter, Edges(all: 20))
        XCTAssertTrue(fileText.contains("outer = 20"))
        var e = Edges(all: 20)
        e.top = 4
        model.setOuterGap(e)
        XCTAssertEqual(model.config.gapOuter, e)
        model.setOuterGap(Edges(all: 6))
        XCTAssertEqual(model.config.gapOuter, Edges(all: 6))
    }

    func testChangingABuiltInShortcut() throws {
        let old = try XCTUnwrap(model.config.bindings.first { $0.source == "option-h" })
        model.bind("cmd-option-left", to: "focus left", replacing: old)
        XCTAssertEqual(source(of: "focus left"), ["cmd-option-left"])
        XCTAssertTrue(fileText.contains("option-h = \"\""), "the built-in shortcut is switched off, not just forgotten")
        XCTAssertEqual(model.config.bindings.count, 45)
        XCTAssertEqual(model.problems, [])

        // Changing it back restores the original line.
        let current = try XCTUnwrap(model.config.bindings.first { $0.source == "cmd-option-left" })
        model.bind("option-h", to: "focus left", replacing: current)
        XCTAssertEqual(source(of: "focus left"), ["option-h"])
        XCTAssertFalse(fileText.contains("cmd-option-left"), "a shortcut that was never built in is removed from the file")
        XCTAssertFalse(model.shortcutsDifferFromBuiltIn)
    }

    func testAddingRemovingAndStealingShortcuts() throws {
        model.bind("ctrl-option-z", to: "zoom", replacing: nil)
        XCTAssertEqual(source(of: "zoom"), ["ctrl-option-z", "option-f"])

        // option-f currently zooms; giving it to another command takes it away from zoom.
        model.bind("option-f", to: "float", replacing: nil)
        XCTAssertEqual(source(of: "zoom"), ["ctrl-option-z"])
        XCTAssertTrue(source(of: "float").contains("option-f"))
        XCTAssertNotNil(model.notice)

        let extra = try XCTUnwrap(model.config.bindings.first { $0.source == "ctrl-option-z" })
        model.unbind(extra)
        XCTAssertEqual(source(of: "zoom"), [])
        let builtIn = try XCTUnwrap(model.config.bindings.first { $0.source == "option-slash" })
        model.unbind(builtIn)
        XCTAssertEqual(source(of: "flip"), [])
        XCTAssertTrue(model.shortcutsDifferFromBuiltIn)

        model.resetShortcuts()
        XCTAssertFalse(model.shortcutsDifferFromBuiltIn)
        XCTAssertEqual(model.config.bindings.count, 45)
        XCTAssertEqual(model.problems, [])
    }

    func testCustomCommandsAreListedSeparately() {
        XCTAssertEqual(model.customBindings.count, 0)
        model.bind("option-shift-0", to: "move-to-space 3 --stay", replacing: nil)
        XCTAssertEqual(model.customBindings.map(\.commandText), ["move-to-space 3 --stay"])
        model.bind("option-x", to: "not a command", replacing: nil)
        XCTAssertEqual(model.customBindings.count, 1, "an invalid command is never written")
    }

    func testEveryListedCommandIsValidAndCoversTheDefaults() {
        let listed = CommandGroup.all.flatMap(\.commands)
        for info in listed { XCTAssertNotNil(info.command, info.text) }
        XCTAssertEqual(Set(listed.map(\.text)).count, listed.count, "no command is listed twice")
        for binding in Config.default.bindings {
            XCTAssertTrue(listed.contains { $0.command == binding.command }, "\(binding.commandText) has a row in the Shortcuts pane")
        }
    }

    func testRules() {
        XCTAssertEqual(model.config.rules.count, 3, "the built-in rules apply until the file says otherwise")
        model.setRules([Rule(app: "Preview", title: nil), Rule(app: nil, title: "^Inspector")])
        XCTAssertEqual(model.config.rules, [Rule(app: "Preview", title: nil), Rule(app: nil, title: "^Inspector")])

        // An exception written by hand survives being saved from the window.
        model.setRules([Rule(app: "Safari", title: "^Reader", float: false), Rule(app: "Safari", title: nil)])
        XCTAssertEqual(model.config.rules.map(\.float), [false, true])

        // Removing the last rule means no rules, not the built-in ones again.
        model.setRules([])
        XCTAssertEqual(model.config.rules, [])
        XCTAssertTrue(fileText.contains("rule = []"))
        model.setRules([Rule(app: "Notes", title: nil)])
        XCTAssertEqual(model.config.rules, [Rule(app: "Notes", title: nil)])
        XCTAssertFalse(fileText.contains("rule = []"), "the empty marker goes away when a rule is added")
        XCTAssertEqual(model.problems, [])
    }

    func testRulesKeepTheirDesktop() throws {
        try ConfigFile.write("""
        [[rule]]
        app = "com.tinyspeck.slackmacgap"
        desktop = 3

        [[rule]]
        app = "Music"
        float = true
        desktop = 2

        [[rule]]
        app = "Notes"
        float = false
        desktop = 1

        """, to: backend.configURL)
        backend.reloadConfig()
        model.refresh()
        let written = model.config.rules
        XCTAssertEqual(written.map(\.desktop), [3, 2, 1])

        // Saved from the window with another rule added, every rule says what it said before.
        model.setRules(written + [Rule(app: "Preview", title: nil)])
        XCTAssertEqual(model.config.rules, written + [Rule(app: "Preview", title: nil)])
        XCTAssertEqual(model.config.rules.map(\.float), [nil, true, false, true])
        XCTAssertTrue(fileText.contains("app = \"com.tinyspeck.slackmacgap\"\ndesktop = 3\n"), "a rule that only names a desktop is not given a float key")
        XCTAssertTrue(fileText.contains("app = \"Music\"\nfloat = true\ndesktop = 2\n"))

        // The window can take the desktop away again, or give one to a rule that had none.
        model.setRules([Rule(app: "Music", title: nil, float: true), Rule(app: "Preview", title: nil, float: nil, desktop: 4)])
        XCTAssertEqual(model.config.rules.map(\.desktop), [nil, 4])
        XCTAssertEqual(model.config.rules.map(\.floats), [true, false])
        XCTAssertEqual(model.problems, [])
    }

    func testRecordingSuspendsGlobalShortcuts() {
        model.startRecording(slot: "x") { _ in }
        XCTAssertEqual(model.recording, "x")
        model.stopRecording()
        XCTAssertNil(model.recording)
        XCTAssertEqual(backend.suspensions, [true, false])
        model.stopRecording()
        XCTAssertEqual(backend.suspensions, [true, false], "stopping twice does not re-register twice")
    }

    func testShortcutDisplay() throws {
        XCTAssertEqual(ShortcutFormat.display(try KeyCombo.parse("option-shift-h")), "⌥⇧H")
        XCTAssertEqual(ShortcutFormat.display(try KeyCombo.parse("ctrl-cmd-left")), "⌃⌘←")
        XCTAssertEqual(Hotkeys.keyName(for: 4), "h")
        XCTAssertEqual(Hotkeys.keyName(for: 36), "return")
        XCTAssertEqual(Hotkeys.keyName(for: 53), "esc")
        XCTAssertNil(Hotkeys.keyName(for: 999))
    }

    func testConfigCheck() throws {
        let folder = backend.configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let good = folder.appendingPathComponent("good.toml"), warn = folder.appendingPathComponent("warn.toml"), bad = folder.appendingPathComponent("bad.toml")
        try Config.defaultText.write(to: good, atomically: true, encoding: .utf8)
        try "[gaps]\ninner = 9999\n".write(to: warn, atomically: true, encoding: .utf8)
        try "[gaps\ninner = 1\n".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertTrue(ConfigFile.check(good).ok)
        XCTAssertEqual(ConfigFile.check(good).report.count, 1)
        XCTAssertTrue(ConfigFile.check(warn).ok)
        XCTAssertEqual(ConfigFile.check(warn).report.count, 2)
        XCTAssertFalse(ConfigFile.check(bad).ok)
        XCTAssertTrue(ConfigFile.check(bad).report[0].contains("line 1"))
        XCTAssertTrue(ConfigFile.check(folder.appendingPathComponent("missing.toml")).ok, "no file is a valid state: the built-in settings apply")
    }
}
