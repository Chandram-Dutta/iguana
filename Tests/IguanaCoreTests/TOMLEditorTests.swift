import XCTest
@testable import IguanaCore

/// Changing a config file in place: one value is set, added or removed, and the rest stays as it was.
final class TOMLEditorTests: XCTestCase {
    func testASettingWrittenAsItsOwnSectionIsReplacedNotDoubled() throws {
        let text = """
        [gaps]
        inner = 8

        # each edge by itself
        [gaps.outer]
        top = 4
        left = 6
        bottom = 4
        right = 6

        [layout]
        auto-split = true
        """
        // One number for all four edges: the section must go, or the file defines outer twice.
        var uniform = TOMLEditor(text)
        uniform.set(["gaps", "outer"], to: .int(12))
        XCTAssertFalse(uniform.text.contains("[gaps.outer]"))
        var (config, warnings) = try Config.load(uniform.text)
        XCTAssertEqual(config.gapOuter, Edges(all: 12))
        XCTAssertEqual(config.gapInner, 8)
        XCTAssertTrue(config.autoSplit)
        XCTAssertTrue(warnings.isEmpty)

        // Each edge again, now as an inline table: the old section must not win.
        var edges = TOMLEditor(text)
        edges.set(["gaps", "outer"], to: .table(["top": .int(1), "left": .int(2), "bottom": .int(3), "right": .int(4)]))
        (config, warnings) = try Config.load(edges.text)
        XCTAssertEqual(config.gapOuter.top, 1)
        XCTAssertEqual(config.gapOuter.right, 4)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(edges.text.contains("[layout]"), "the sections after it are untouched")
    }

    let original = """
    # my settings
    top = 1

    [gaps]
    inner = 8      # between windows
    outer = { top = 8, left = 8 }

    [bindings]
    option-h = "focus left"
    "option-shift-h" = "move left"   # quoted key

    # floating apps
    [[rule]]
    app = "Calculator"
    float = true

    [[rule]]
    app = "Music"
    """

    func parsed(_ e: TOMLEditor) throws -> [String: TOMLValue] { try TOML.parse(e.text) }

    func testChangingAValueKeepsEverythingElse() throws {
        var e = TOMLEditor(original)
        e.set(["gaps", "inner"], to: .int(12))
        XCTAssertTrue(e.text.contains("inner = 12      # between windows"), "the trailing comment and spacing survive")
        XCTAssertEqual(e.text.replacingOccurrences(of: "inner = 12", with: "inner = 8"), original, "nothing else changed")
        e.set(["bindings", "option-shift-h"], to: .string("move right"))
        XCTAssertTrue(e.text.contains("\"option-shift-h\" = \"move right\"   # quoted key"))
        e.set(["gaps", "outer"], to: .int(4))
        XCTAssertEqual(try parsed(e)["gaps"], .table(["inner": .int(12), "outer": .int(4)]))
    }

    func testAddingKeysAndTables() throws {
        var e = TOMLEditor(original)
        e.set(["gaps", "extra"], to: .bool(true))
        e.set(["bindings", "option-l"], to: .string("focus right"))
        e.set(["animation", "duration"], to: .double(0.25))
        e.set(["animation", "enabled"], to: .bool(false))
        e.set(["other"], to: .string("x"))
        let doc = try parsed(e)
        XCTAssertEqual(doc["gaps"]?.tableValue?["extra"], .bool(true))
        XCTAssertEqual(doc["bindings"]?.tableValue?.count, 3)
        XCTAssertEqual(doc["animation"], .table(["duration": .double(0.25), "enabled": .bool(false)]))
        XCTAssertEqual(doc["other"], .string("x"))
        XCTAssertEqual(doc["top"], .int(1))
        XCTAssertEqual(doc["rule"]?.arrayValue?.count, 2, "rules untouched")
        XCTAssertTrue(e.text.contains("# floating apps"))
        let lines = e.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.firstIndex(of: "extra = true"), lines.firstIndex { $0.hasPrefix("outer") }! + 1, "new key goes to the end of its table")
    }

    func testRemove() throws {
        var e = TOMLEditor(original)
        XCTAssertTrue(e.remove(["bindings", "option-h"]))
        XCTAssertFalse(e.remove(["bindings", "option-h"]))
        XCTAssertFalse(e.remove(["nope", "x"]))
        XCTAssertEqual(try parsed(e)["bindings"]?.tableValue?.keys.sorted(), ["option-shift-h"])
    }

    func testMultiLineValuesAndHashesInStrings() throws {
        var e = TOMLEditor("""
        list = [
          1,   # one
          2,
        ]
        title = "a # b"  # real comment
        after = true
        """)
        e.set(["title"], to: .string("c # d"))
        XCTAssertTrue(e.text.contains("title = \"c # d\"  # real comment"))
        e.set(["list"], to: .array([.int(9)]))
        XCTAssertEqual(try parsed(e), ["list": .array([.int(9)]), "title": .string("c # d"), "after": .bool(true)])
        XCTAssertTrue(e.remove(["title"]))
        XCTAssertEqual(try parsed(e).keys.sorted(), ["after", "list"])
    }

    func testReplacingRules() throws {
        var e = TOMLEditor(original)
        e.replaceArrayOfTables("rule", with: [[("app", .string("Preview")), ("title", .string("^Info")), ("float", .bool(true))]])
        let doc = try parsed(e)
        XCTAssertEqual(doc["rule"], .array([.table(["app": .string("Preview"), "title": .string("^Info"), "float": .bool(true)])]))
        XCTAssertTrue(e.text.contains("# floating apps"), "the comment above the rules stays")
        XCTAssertEqual(doc["bindings"]?.tableValue?.count, 2)
        e.replaceArrayOfTables("rule", with: [])
        XCTAssertNil(try parsed(e)["rule"])
        e.replaceArrayOfTables("rule", with: [[("app", .string("A"))], [("app", .string("B"))]])
        XCTAssertEqual(try parsed(e)["rule"]?.arrayValue?.count, 2)
    }

    func testEditingAnEmptyFileAndTheDefaultConfig() throws {
        var empty = TOMLEditor("")
        empty.set(["gaps", "inner"], to: .int(3))
        XCTAssertEqual(try parsed(empty), ["gaps": .table(["inner": .int(3)])])

        var e = TOMLEditor(Config.defaultText)
        e.set(["gaps", "inner"], to: .int(20))
        e.set(["animation", "duration"], to: .double(0.4))
        e.set(["bindings", "option-h"], to: .string(""))
        e.set(["stage-manager", "reserve-strip"], to: .bool(false))
        let (c, warnings) = try Config.load(e.text)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.gapInner, 20)
        XCTAssertEqual(c.animationDuration, 0.4)
        XCTAssertEqual(c.stripReserve, .off)
        XCTAssertFalse(c.bindings.contains { $0.source == "option-h" })
        XCTAssertEqual(e.text.components(separatedBy: "\n").count, Config.defaultText.components(separatedBy: "\n").count, "no lines added or lost")
    }

    func testFormatting() {
        XCTAssertEqual(TOMLEditor.format(.double(0.05)), "0.05")
        XCTAssertEqual(TOMLEditor.format(.double(2)), "2.0")
        XCTAssertEqual(TOMLEditor.format(.string("a\"b\\")), "\"a\\\"b\\\\\"")
        XCTAssertEqual(TOMLEditor.formatKey("option-shift-h"), "option-shift-h")
        XCTAssertEqual(TOMLEditor.formatKey("has space"), "\"has space\"")
    }
}
