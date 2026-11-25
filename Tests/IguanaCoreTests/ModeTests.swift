import XCTest
@testable import IguanaCore

/// Modes: `[mode.NAME]` tables of shortcuts that take the place of `[bindings]` while they are on.
final class ModeTests: XCTestCase {
    static let resize = """
    [bindings]
    option-r = "mode resize"

    [mode.resize]
    h = "resize shrink width"
    l = "resize grow width"
    j = "resize grow height"
    k = "resize shrink height"
    shift-h = "move left"
    return = "mode default"
    """

    private func source(_ list: [Binding]?) -> [String] { (list ?? []).map(\.source).sorted() }

    func testTheModeCommand() throws {
        XCTAssertEqual(try Command.parse("mode resize"), .mode("resize"))
        XCTAssertEqual(try Command.parse("Mode DEFAULT"), .mode("default"))
        XCTAssertEqual(try Command.parse("mode move-2"), .mode("move-2"))
        for bad in ["mode", "mode a b", "mode re_size", "mode ünder"] {
            XCTAssertThrowsError(try Command.parse(bad), bad) {
                XCTAssertEqual("\($0)", "'mode' needs the name of a mode, or 'default'")
            }
        }
        XCTAssertTrue(Command.usage.contains("\nmode NAME|default "))
        XCTAssertEqual(try Command.parse("mode resize; flip"), .sequence([.mode("resize"), .flip]), "a mode can be part of a chain")
    }

    func testModeTablesAreRead() throws {
        let (c, warnings) = try Config.load(Self.resize)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(source(c.modes["resize"]), ["h", "j", "k", "l", "return", "shift-h"])
        let h = try XCTUnwrap(c.modes["resize"]?.first { $0.source == "h" })
        XCTAssertEqual(h.combo, KeyCombo(modifiers: [], key: "h"))
        XCTAssertEqual(h.command, .resize(axis: .horizontal, grow: -1))
        XCTAssertEqual(c.modes["resize"]?.first { $0.source == "shift-h" }?.combo.modifiers, [.shift])
        // [bindings] is merged over the built-in shortcuts as before, and keeps none of the mode's.
        XCTAssertEqual(c.bindings.count, 42)
        XCTAssertEqual(c.bindings.first { $0.source == "option-r" }?.command, .mode("resize"))
        XCTAssertFalse(c.bindings.contains { $0.source == "h" })
        // An inline table is the same table.
        XCTAssertEqual(try Config.load("[mode]\nresize = { h = \"flip\" }\n").config.modes["resize"]?.map(\.command), [.flip])
        XCTAssertEqual(Config.default.modes, [:], "no mode is built in")
        XCTAssertEqual(try Config.load(Config.defaultText).config.modes, [:], "the default file shows one in comments only")
        XCTAssertTrue(Config.defaultText.contains("# [mode.resize]"))
    }

    func testAKeyWithoutAModifierIsAShortcutOnlyInAMode() throws {
        XCTAssertEqual(try KeyCombo.parse("h", requireModifier: false), KeyCombo(modifiers: [], key: "h"))
        XCTAssertEqual(try KeyCombo.parse("return", requireModifier: false).modifiers, [])
        XCTAssertEqual(try KeyCombo.parse("-", requireModifier: false), KeyCombo(modifiers: [], key: "minus"))
        XCTAssertThrowsError(try KeyCombo.parse("h")) { XCTAssertEqual("\($0)", "'h': a binding needs at least one modifier") }
        XCTAssertThrowsError(try KeyCombo.parse("hyper-h", requireModifier: false))

        let (c, warnings) = try Config.load("[bindings]\nh = \"flip\"\n[mode.x]\nh = \"flip\"\n")
        XCTAssertEqual(warnings, ["binding 'h': 'h': a binding needs at least one modifier"])
        XCTAssertFalse(c.bindings.contains { $0.source == "h" })
        XCTAssertEqual(source(c.modes["x"]), ["h"])
    }

    func testModeNames() throws {
        let (c, warnings) = try Config.load("""
        [mode.default]
        h = "flip"
        [mode.Big]
        h = "flip"
        [mode.move-2]
        h = "flip"
        """)
        XCTAssertEqual(Array(c.modes.keys), ["move-2"])
        XCTAssertEqual(warnings, [
            "[mode.Big]: a mode name is lower-case letters, digits and -; ignoring this table",
            "[mode.default]: 'default' stands for [bindings] and cannot be a mode; ignoring this table",
        ])
        XCTAssertEqual(try Config.load("mode = 3\n").warnings, ["modes are written as [mode.NAME] sections"])
        XCTAssertEqual(try Config.load("[mode]\nresize = \"flip\"\n").warnings, ["mode.resize must be a table of shortcuts, written as [mode.resize]"])
    }

    func testAShortcutForAModeThatIsNotThereIsAWarning() throws {
        let (c, warnings) = try Config.load("""
        [bindings]
        option-r = "mode resize"
        option-m = "flip; mode move"
        option-d = "mode default"
        [mode.resize]
        m = "mode move"
        """)
        XCTAssertEqual(warnings, [
            "binding 'option-m': no mode 'move' (there is no [mode.move] table)",
            "binding 'm' in [mode.resize]: no mode 'move' (there is no [mode.move] table)",
        ])
        // The shortcut stays, and answers with an error when it is used.
        XCTAssertEqual(c.bindings.first { $0.source == "option-m" }?.command, .sequence([.flip, .mode("move")]))
        XCTAssertNil(c.bindings(inMode: "move"))
        XCTAssertEqual(try Config.load("[bindings]\noption-r = \"mode resize\"\n").warnings,
                       ["binding 'option-r': no mode 'resize' (there is no [mode.resize] table)"])
    }

    func testEntriesAreReadLikeThoseOfBindings() throws {
        let (c, warnings) = try Config.load("""
        [mode.resize]
        h = "resize shrink width; balance"
        j = ""
        k = false
        l = 3
        n = "explode"
        ctrl-shift-x = "flip"
        shift-ctrl-x = "zoom"
        """)
        let resize = c.modes["resize"] ?? []
        XCTAssertEqual(resize.first { $0.source == "h" }?.command, .sequence([.resize(axis: .horizontal, grow: -1), .balance]))
        XCTAssertEqual(source(resize), ["ctrl-shift-x", "h"], "\"\" and false leave a key unbound; a mistake leaves it out")
        XCTAssertEqual(warnings, [
            "binding 'l' in [mode.resize]: the command must be a string (or \"\" to leave the key unbound)",
            "binding 'n' in [mode.resize]: unknown command 'explode'",
            "binding 'shift-ctrl-x' in [mode.resize] is defined twice",
        ])
    }

    func testEscAlwaysLeadsOutOfAMode() throws {
        let c = try Config.load(Self.resize).config
        let live = try XCTUnwrap(c.bindings(inMode: "resize"))
        XCTAssertEqual(source(live), ["esc", "h", "j", "k", "l", "return", "shift-h"], "only the mode's shortcuts, and esc")
        let esc = try XCTUnwrap(live.first { $0.source == "esc" })
        XCTAssertEqual(esc.combo, KeyCombo(modifiers: [], key: "esc"))
        XCTAssertEqual(esc.command, .mode("default"))
        XCTAssertEqual(c.bindings(inMode: "default"), c.bindings)
        XCTAssertNil(c.bindings(inMode: "move"))

        // A mode that binds esc itself keeps its own; "" leaves esc unbound, so the way out is added.
        for (line, command) in [("esc = \"flip\"", Command.flip), ("escape = \"flip\"", .flip), ("esc = \"\"", .mode("default"))] {
            let mode = try XCTUnwrap(try Config.load("[mode.x]\n\(line)\n").config.bindings(inMode: "x"), line)
            XCTAssertEqual(mode.map(\.command), [command], line)
        }
        // Esc with a modifier is another key.
        let shifted = try XCTUnwrap(try Config.load("[mode.x]\nshift-esc = \"flip\"\n").config.bindings(inMode: "x"))
        XCTAssertEqual(source(shifted), ["esc", "shift-esc"])
        XCTAssertEqual(try Config.load("[mode.empty]\n").config.bindings(inMode: "empty")?.map(\.source), ["esc"])
    }

    func testStatusSaysWhichModeIsOn() throws {
        var status = ReportTests.status
        XCTAssertTrue(Report.encode(status).contains("\"mode\" : null"))
        status.mode = "resize"
        XCTAssertTrue(Report.encode(status).contains("\"mode\" : \"resize\""))
    }
}
