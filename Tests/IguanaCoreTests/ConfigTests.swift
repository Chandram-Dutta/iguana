import XCTest
@testable import IguanaCore

/// The config file: the built-in settings, what a file changes about them, and the warnings it gets.
final class ConfigTests: XCTestCase {
    func testMenuBarDesktopsIsOffUntilAskedFor() throws {
        XCTAssertEqual(Config.default.menuBarDesktops, .current)
        let (all, none) = try Config.load("[menu-bar]\ndesktops = \"all\"\n")
        XCTAssertEqual(all.menuBarDesktops, .all)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(try Config.load("[menu-bar]\ndesktops = \"occupied\"\n").0.menuBarDesktops, .occupied)

        let (kept, warnings) = try Config.load("[menu-bar]\ndesktops = \"some\"\nicons = true\n")
        XCTAssertEqual(kept.menuBarDesktops, .current)
        XCTAssertEqual(warnings.count, 2, "one for the value, one for the unknown key")

        // A click on a drawn desktop only switches when that is asked for as well.
        XCTAssertFalse(Config.default.menuBarClickSwitches)
        XCTAssertFalse(all.menuBarClickSwitches)
        XCTAssertTrue(try Config.load("[menu-bar]\ndesktops = \"all\"\nclick-to-switch = true\n").0.menuBarClickSwitches)
    }

    func testDefaultConfigLoadsCleanly() throws {
        let (c, warnings) = try Config.load(Config.defaultText)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.gapInner, 8)
        XCTAssertEqual(c.stripReserve, .auto)
        XCTAssertEqual(c.bindings.count, 50)
        XCTAssertEqual(c.rules.count, 3)
        XCTAssertTrue(c.bindings.contains { $0.source == "option-shift-3" && $0.command == .moveToSpace(.index(3), follow: true) })
        XCTAssertEqual(Config.default, c)
    }

    func testConfigOverridesAndWarnings() throws {
        let (c, warnings) = try Config.load("""
        [gaps]
        inner = 0
        outer = { top = 20 }
        bogus = 1
        [layout]
        auto-split = "yes"
        [stage-manager]
        reserve-strip = false
        [bindings]
        cmd-option-left = "focus left"
        option-q = "explode"
        hyper-x = "zoom"
        """)
        XCTAssertEqual(c.gapInner, 0)
        XCTAssertEqual(c.gapOuter.top, 20)
        XCTAssertEqual(c.gapOuter.left, 8)
        XCTAssertTrue(c.autoSplit)
        XCTAssertEqual(c.stripReserve, .off)
        XCTAssertEqual(c.bindings.count, 51, "the file's shortcut is added to the 50 built-in ones")
        XCTAssertTrue(c.bindings.contains { $0.source == "cmd-option-left" && $0.commandText == "focus left" })
        XCTAssertEqual(warnings.count, 4)
    }

    func testFileSettingsLayerOverTheDefaults() throws {
        let (c, warnings) = try Config.load("""
        [bindings]
        option-h = "focus right"    # replaces a built-in shortcut
        option-l = ""               # switches one off
        option-j = false            # also switches one off
        ctrl-option-z = "zoom"      # adds one

        [animation]
        enabled = false
        duration = 0.3
        easing = "linear"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.bindings.first { $0.source == "option-h" }?.command, .focus(.right))
        XCTAssertFalse(c.bindings.contains { $0.source == "option-l" || $0.source == "option-j" })
        XCTAssertTrue(c.bindings.contains { $0.source == "option-k" }, "untouched shortcuts stay")
        XCTAssertEqual(c.bindings.count, 50 - 2 + 1)
        XCTAssertEqual(c.rules, Config.default.rules, "no [[rule]] in the file keeps the built-in rules")
        XCTAssertFalse(c.animate)
        XCTAssertEqual(c.animationDuration, 0.3)
        XCTAssertEqual(c.animationEasing, .linear)

        let (withRules, _) = try Config.load("[[rule]]\napp = \"Preview\"\n")
        XCTAssertEqual(withRules.rules.map(\.app), ["Preview"], "a file with rules lists all of them")

        let (bad, problems) = try Config.load("[animation]\nduration = 9\neasing = \"bouncy\"\n")
        XCTAssertEqual(bad.animationDuration, Config.default.animationDuration)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(try Config.load("").config, Config.default, "an empty file is the defaults")
    }
}
