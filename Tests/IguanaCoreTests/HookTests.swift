import XCTest
@testable import IguanaCore

/// `[hooks]`: when a hook is due, what its command is told, and how the config file carries it.
final class HookTests: XCTestCase {
    typealias Showing = HookTracker.Showing

    let laptop = Showing(display: "laptop", space: "space-a", desktop: 1)
    let monitor = Showing(display: "monitor", space: "space-m", desktop: 4)

    func testTheFirstLookIsWhereIguanaStartsFrom() {
        var tracker = HookTracker()
        XCTAssertEqual(tracker.observe(showing: [laptop, monitor], focused: 10), [])
        XCTAssertEqual(tracker.observe(showing: [laptop, monitor], focused: 10), [], "nothing changed, however often Iguana looks")
    }

    func testADesktopHookIsDueOnlyWhenADisplayShowsSomethingElse() {
        var tracker = HookTracker()
        _ = tracker.observe(showing: [laptop, monitor], focused: nil)

        let second = Showing(display: "laptop", space: "space-b", desktop: 2)
        XCTAssertEqual(tracker.observe(showing: [second, monitor], focused: nil), [.desktop(display: "laptop")], "only the display that changed")
        for _ in 0..<5 { XCTAssertEqual(tracker.observe(showing: [second, monitor], focused: nil), []) }

        // The desktop before it was removed in Mission Control: same Space, new number.
        let renumbered = Showing(display: "laptop", space: "space-b", desktop: 1)
        XCTAssertEqual(tracker.observe(showing: [renumbered, monitor], focused: nil), [.desktop(display: "laptop")])

        // An app went fullscreen on the monitor, and came back.
        let fullscreen = Showing(display: "monitor", space: "space-f", desktop: nil)
        XCTAssertEqual(tracker.observe(showing: [renumbered, fullscreen], focused: nil), [.desktop(display: "monitor")])
        XCTAssertEqual(tracker.observe(showing: [renumbered, monitor], focused: nil), [.desktop(display: "monitor")])

        // Both at once.
        XCTAssertEqual(tracker.observe(showing: [laptop, fullscreen], focused: nil), [.desktop(display: "laptop"), .desktop(display: "monitor")])
    }

    func testADisplayThatComesBackToTheSameDesktopIsNotAChange() {
        var tracker = HookTracker()
        _ = tracker.observe(showing: [laptop, monitor], focused: nil)
        XCTAssertEqual(tracker.observe(showing: [laptop], focused: nil), [], "unplugged")
        XCTAssertEqual(tracker.observe(showing: [], focused: nil), [], "asleep")
        XCTAssertEqual(tracker.observe(showing: [laptop, monitor], focused: nil), [], "back, showing what it showed")

        let projector = Showing(display: "projector", space: "space-p", desktop: 5)
        XCTAssertEqual(tracker.observe(showing: [laptop, monitor, projector], focused: nil), [.desktop(display: "projector")], "a display never seen before")
    }

    func testAFocusHookIsDueOnlyForADifferentWindow() {
        var tracker = HookTracker()
        _ = tracker.observe(showing: [laptop], focused: 10)
        XCTAssertEqual(tracker.observe(showing: [laptop], focused: 11), [.focus(11)])
        XCTAssertEqual(tracker.observe(showing: [laptop], focused: 11), [])
        XCTAssertEqual(tracker.observe(showing: [laptop], focused: nil), [.focus(nil)], "the last window closed")
        XCTAssertEqual(tracker.observe(showing: [laptop], focused: nil), [])
        XCTAssertEqual(tracker.observe(showing: [laptop], focused: 10), [.focus(10)])

        // Arriving on another desktop: the desktop is reported before the window on it.
        let second = Showing(display: "laptop", space: "space-b", desktop: 2)
        XCTAssertEqual(tracker.observe(showing: [second], focused: 12), [.desktop(display: "laptop"), .focus(12)])
    }

    func testVariables() {
        let desktop = HookEnvironment.variables(event: .desktopChanged, desktop: 3, display: "Studio Display")
        XCTAssertEqual(desktop, ["IGUANA_EVENT": "desktop-changed", "IGUANA_DESKTOP": "3", "IGUANA_DISPLAY": "Studio Display"])
        XCTAssertEqual(HookEnvironment.variables(event: .desktopChanged, desktop: nil, display: "Studio Display")["IGUANA_DESKTOP"], "",
                       "a fullscreen Space has no number")

        let focus = HookEnvironment.variables(event: .focusChanged, desktop: 1, display: "Built-in Retina Display",
                                              window: (1187, "Terminal", "zsh"))
        XCTAssertEqual(focus, [
            "IGUANA_EVENT": "focus-changed", "IGUANA_DESKTOP": "1", "IGUANA_DISPLAY": "Built-in Retina Display",
            "IGUANA_WINDOW_ID": "1187", "IGUANA_APP": "Terminal", "IGUANA_TITLE": "zsh",
        ])
        let none = HookEnvironment.variables(event: .focusChanged, desktop: 1, display: nil)
        XCTAssertEqual(none["IGUANA_WINDOW_ID"], "", "set and empty when no window has the focus, so a script can test for it")
        XCTAssertEqual(none["IGUANA_TITLE"], "")
        XCTAssertEqual(Set(focus.keys), Set(HookEnvironment.allVariables))
        XCTAssertEqual(Set(HookEvent.allCases.map(\.rawValue)), ["desktop-changed", "focus-changed"])
    }

    func testATitleTravelsAsItIs() {
        // Nothing in a title is special to Iguana. It is the shell script's job to quote the variable.
        let hostile = "$(touch /tmp/x); `id` \"; rm -rf ~ #' \n&& echo"
        XCTAssertEqual(HookEnvironment.variables(event: .focusChanged, desktop: 1, display: nil, window: (1, "Safari", hostile))["IGUANA_TITLE"], hostile)

        // A NUL would end the value early.
        XCTAssertEqual(HookEnvironment.clean("a\0b\0"), "ab")

        // No title is long enough to stop the command from starting.
        XCTAssertEqual(HookEnvironment.clean(String(repeating: "x", count: 100_000)).utf8.count, HookEnvironment.longestValue)
        let wide = HookEnvironment.clean(String(repeating: "東", count: 5000))
        XCTAssertLessThanOrEqual(wide.utf8.count, HookEnvironment.longestValue)
        XCTAssertEqual(wide, String(repeating: "東", count: HookEnvironment.longestValue / 3), "cut between characters, not inside one")
        XCTAssertEqual(HookEnvironment.clean("zsh — ~/code 🦎"), "zsh — ~/code 🦎")
    }

    func testTheCommandsEnvironment() {
        let inherited = ["HOME": "/Users/you", "PATH": "/usr/bin:/bin", "IGUANA_TITLE": "left over", "IGUANA_DESKTOP": "9"]
        let env = HookEnvironment.merged(inherited: inherited, variables: HookEnvironment.variables(event: .desktopChanged, desktop: 2, display: "D"))
        XCTAssertEqual(env["HOME"], "/Users/you")
        XCTAssertEqual(env["IGUANA_DESKTOP"], "2")
        XCTAssertNil(env["IGUANA_TITLE"], "a variable of another event is not left over from where Iguana was started")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")

        XCTAssertEqual(HookEnvironment.path("/opt/homebrew/bin:/usr/bin"), "/opt/homebrew/bin:/usr/bin:/usr/local/bin", "what was found first is still found first")
        XCTAssertEqual(HookEnvironment.path(nil), "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        XCTAssertEqual(HookEnvironment.path(""), HookEnvironment.path(nil))
    }

    // MARK: The config file

    func testNoHooksUnlessTheFileHasThem() throws {
        XCTAssertEqual(Config.default.hooks, [:])
        XCTAssertEqual(try Config.load("[gaps]\ninner = 4\n").config.hooks, [:], "a missing section")
        XCTAssertEqual(try Config.load("[hooks]\n").config.hooks, [:], "a missing key")

        let (c, warnings) = try Config.load("""
        [hooks]
        desktop-changed = "sketchybar --trigger iguana_desktop"
        focus-changed = ""
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.hooks, [.desktopChanged: "sketchybar --trigger iguana_desktop"])
        XCTAssertEqual(try Config.load("[hooks]\nfocus-changed = \"   \"\n").config.hooks, [:], "only spaces is no command")

        // A literal string keeps a shell script's own quotes readable.
        let quoted = try Config.load("[hooks]\nfocus-changed = 'echo \"$IGUANA_TITLE\" >> ~/focus.log'\n").config
        XCTAssertEqual(quoted.hooks[.focusChanged], "echo \"$IGUANA_TITLE\" >> ~/focus.log")
    }

    func testHookMistakesAreWarnings() throws {
        let (c, warnings) = try Config.load("""
        [hooks]
        desktop-changed = true
        focus-changed = "true"
        window-opened = "true"
        """)
        XCTAssertEqual(c.hooks, [.focusChanged: "true"])
        XCTAssertEqual(warnings.count, 2, "one for the value that is not a string, one for the unknown key")
        XCTAssertTrue(warnings.contains { $0.contains("hooks.desktop-changed") })
        XCTAssertTrue(warnings.contains { $0.contains("window-opened") })
    }

    // MARK: The settings window rewrites the file around them

    func testEditingTheFileLeavesHooksAlone() throws {
        let hooks = """
        [hooks]
        desktop-changed = "sketchybar --trigger iguana_desktop"   # [bar] items
        focus-changed = 'printf "%s\\n" "$IGUANA_TITLE" >> "$HOME/focus.log"   # not a comment'
        """
        let rules = "[[rule]]\napp = \"Calculator\"\n"
        // Wherever the section sits: first, between the others, or last.
        for text in ["# for SketchyBar\n\(hooks)\n\n[gaps]\ninner = 8\n\n\(rules)", "[gaps]\ninner = 8\n\n# for SketchyBar\n\(hooks)\n\n\(rules)",
                     "[gaps]\ninner = 8\n\n\(rules)\n# for SketchyBar\n\(hooks)\n"] {
            var e = TOMLEditor(text)
            e.set(["gaps", "inner"], to: .int(12))
            e.set(["gaps", "outer"], to: .table(["top": .int(4), "left": .int(8)]))
            e.set(["animation", "enabled"], to: .bool(false))
            e.set(["bindings", "option-h"], to: .string(""))
            e.set(["bindings", "cmd-option-left"], to: .string("focus left"))
            e.remove(["bindings", "option-h"])
            e.replaceArrayOfTables("rule", with: [[("app", .string("Preview")), ("float", .bool(true))], [("title", .string("^Info"))]])
            e.replaceArrayOfTables("rule", with: [])
            e.set(["rule"], to: .array([]))
            e.remove(["rule"])
            e.replaceArrayOfTables("rule", with: [[("app", .string("Notes"))]])

            XCTAssertTrue(e.text.contains(hooks), "the section, its comments and its spacing are as they were written:\n\(e.text)")
            XCTAssertTrue(e.text.contains("# for SketchyBar"))
            let (c, warnings) = try Config.load(e.text)
            XCTAssertEqual(warnings, [])
            XCTAssertEqual(c.hooks[.desktopChanged], "sketchybar --trigger iguana_desktop")
            XCTAssertEqual(c.hooks[.focusChanged], "printf \"%s\\n\" \"$IGUANA_TITLE\" >> \"$HOME/focus.log\"   # not a comment")
            XCTAssertEqual(c.gapInner, 12)
            XCTAssertFalse(c.animate)
            XCTAssertEqual(c.rules.map(\.app), ["Notes"])
            XCTAssertTrue(c.bindings.contains { $0.source == "cmd-option-left" })
        }
    }

    func testTheDefaultFileShowsBothHooksSwitchedOff() throws {
        let hooks = try XCTUnwrap(try TOML.parse(Config.defaultText)["hooks"]?.tableValue)
        XCTAssertEqual(hooks, ["desktop-changed": .string(""), "focus-changed": .string("")])
        XCTAssertEqual(Set(hooks.keys), Set(HookEvent.allCases.map(\.rawValue)), "every event has a line to fill in")
    }
}
