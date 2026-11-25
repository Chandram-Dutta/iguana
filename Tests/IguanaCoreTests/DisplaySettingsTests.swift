import CoreGraphics
import XCTest
@testable import IguanaCore

/// `[[display]]`: gaps and a maximum width for one display, with `[gaps]` for the rest.
final class DisplaySettingsTests: XCTestCase {
    func load(_ text: String) throws -> (config: Config, warnings: [String]) { try Config.load(text) }

    func edges(top: Double, left: Double, bottom: Double, right: Double) -> Edges {
        var e = Edges(all: 0)
        (e.top, e.left, e.bottom, e.right) = (top, left, bottom, right)
        return e
    }

    // MARK: Reading the file

    func testNoDisplayIsConfiguredByDefault() throws {
        XCTAssertEqual(Config.default.displays, [])
        XCTAssertTrue(Config.defaultText.contains("# [[display]]\n# name = \"LG ULTRAWIDE\""), "the default file shows an example")
        XCTAssertFalse(try TOML.parse(Config.defaultText).keys.contains("display"), "and only in comments")
    }

    func testByName() throws {
        let (c, warnings) = try load("""
        [[display]]
        name = "LG ULTRAWIDE"   # part of the name
        inner = 12
        outer = 16
        max-width = 2560
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.displays, [DisplaySettings(name: "LG ULTRAWIDE", inner: 12, outer: Edges(all: 16), maxWidth: 2560)])
    }

    func testByNumber() throws {
        let (c, warnings) = try load("[[display]]\nnumber = 2\nmax-width = 3000\n")
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.displays, [DisplaySettings(number: 2, maxWidth: 3000)])
    }

    func testATableNeedsExactlyOneOfNameAndNumber() throws {
        let (c, warnings) = try load("""
        [[display]]
        inner = 4

        [[display]]
        name = "LG"
        number = 2

        [[display]]
        number = 1
        inner = 6
        """)
        XCTAssertEqual(warnings, ["display 1 needs 'name' or 'number'", "display 2 needs 'name' or 'number', not both"])
        XCTAssertEqual(c.displays, [DisplaySettings(number: 1, inner: 6)], "the other tables are skipped whole")
    }

    func testABadNameOrNumberSkipsTheTable() throws {
        for (line, problem) in [
            ("name = \"\"", "name must be part of the display's name"),
            ("name = \"   \"", "name must be part of the display's name"),
            ("name = 5", "name must be part of the display's name"),
            ("number = 0", "number must be a whole number from 1 to 16"),
            ("number = 17", "number must be a whole number from 1 to 16"),
            ("number = 2.5", "number must be a whole number from 1 to 16"),
            ("number = \"2\"", "number must be a whole number from 1 to 16"),
        ] {
            let (c, warnings) = try load("[[display]]\n\(line)\ninner = 4\n")
            XCTAssertEqual(c.displays, [], line)
            XCTAssertEqual(warnings.count, 1, line)
            XCTAssertTrue(warnings.first?.hasPrefix("display 1: \(problem)") == true, "\(line): \(warnings)")
        }
    }

    func testABadValueIsIgnoredAndTheRestApplies() throws {
        let (c, warnings) = try load("""
        [[display]]
        name = "LG"
        inner = 300
        outer = -1
        max-width = 100

        [[display]]
        number = 2
        inner = "wide"
        outer = "none"
        max-width = 20000
        """)
        XCTAssertEqual(warnings, [
            "display 1: inner must be a number from 0 to 200; ignoring it",
            "display 1: outer must be a number from 0 to 500; ignoring it",
            "display 1: max-width must be a number from 400 to 10000; ignoring it",
            "display 2: inner must be a number from 0 to 200; ignoring it",
            "display 2: outer must be a number from 0 to 500; ignoring it",
            "display 2: max-width must be a number from 400 to 10000; ignoring it",
        ])
        XCTAssertEqual(c.displays, [DisplaySettings(name: "LG"), DisplaySettings(number: 2)])
        XCTAssertEqual(try load("[[display]]\nnumber = 1\nmax-width = 400\n").config.displays.first?.maxWidth, 400, "the ends of the range are allowed")
        XCTAssertEqual(try load("[[display]]\nnumber = 1\nmax-width = 10000\n").config.displays.first?.maxWidth, 10000)
    }

    func testUnknownKeysAreWarnedAbout() throws {
        let (c, warnings) = try load("""
        [[display]]
        name = "LG"
        gap = 4
        outer = { top = 4, middle = 9 }
        """)
        XCTAssertEqual(warnings, ["unknown key 'gap' in display 1", "unknown key 'middle' in outer of display 1"])
        XCTAssertEqual(c.displays.first?.outer?.top, 4, "the keys it knows still apply")
    }

    func testOuterAsANumberAndAsAPartialTable() throws {
        // [gaps] may come after the [[display]] that falls back to it.
        let (c, warnings) = try load("""
        [[display]]
        number = 1
        outer = 20

        [[display]]
        number = 2
        outer = { left = 30, right = 40, bottom = 900 }

        [gaps]
        outer = { top = 2 }
        """)
        XCTAssertEqual(warnings, ["display 2: outer.bottom must be a number from 0 to 500; ignoring it"])
        XCTAssertEqual(c.displays.map(\.outer), [Edges(all: 20), edges(top: 2, left: 30, bottom: 8, right: 40)],
                       "a side left out keeps the [gaps] value for it")
    }

    func testDisplayMustBeWrittenAsAnArrayOfTables() throws {
        for text in ["[display]\nname = \"LG\"\n", "display = 3\n", "display = [1, 2]\n"] {
            let (c, warnings) = try load(text)
            XCTAssertEqual(warnings, ["display settings are written as [[display]] sections"], text)
            XCTAssertEqual(c.displays, [], text)
        }
    }

    // MARK: Which settings a display gets

    func testFallsBackToGaps() throws {
        let (c, _) = try load("""
        [gaps]
        inner = 5
        outer = 7

        [[display]]
        name = "LG"
        max-width = 2560
        """)
        XCTAssertEqual(c.displaySettings(name: "LG ULTRAWIDE", number: 2), .init(inner: 5, outer: Edges(all: 7), maxWidth: 2560))
        XCTAssertEqual(c.displaySettings(name: "Built-in Retina Display", number: 1), .init(inner: 5, outer: Edges(all: 7), maxWidth: nil),
                       "a display no table names has [gaps] and no maximum width")
        XCTAssertEqual(Config.default.displaySettings(name: "Anything", number: 1), .init(inner: 8, outer: Edges(all: 8), maxWidth: nil))
    }

    func testNameMatchesPartOfTheNameIgnoringCase() throws {
        let (c, _) = try load("[[display]]\nname = \"ultrawide\"\ninner = 20\n")
        XCTAssertEqual(c.displaySettings(name: "LG ULTRAWIDE", number: 2).inner, 20)
        XCTAssertEqual(c.displaySettings(name: "Dell UltraWide 34", number: 3).inner, 20)
        XCTAssertEqual(c.displaySettings(name: "LG UltraFine", number: 2).inner, 8)
        XCTAssertEqual(c.displaySettings(name: "Studio Display", number: 2).inner, 8)
    }

    func testNumberMatchesTheDisplaysNumber() throws {
        let (c, _) = try load("[[display]]\nnumber = 2\ninner = 20\n")
        XCTAssertEqual(c.displaySettings(name: "LG ULTRAWIDE", number: 2).inner, 20)
        XCTAssertEqual(c.displaySettings(name: "LG ULTRAWIDE", number: 1).inner, 8)
        // Numbers are the ones DisplayOrder gives: left to right.
        let frames = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -2560, y: -200, width: 2560, height: 1080)]
        XCTAssertEqual(DisplayOrder.numbers(frames), [2, 1])
    }

    func testTheFirstTableThatMatchesWins() throws {
        let (c, _) = try load("""
        [[display]]
        name = "ultrawide"
        inner = 20

        [[display]]
        number = 2
        inner = 30
        outer = 40
        max-width = 3000
        """)
        // The first table says nothing about outer or max-width: those come from [gaps], not from the second table.
        XCTAssertEqual(c.displaySettings(name: "LG ULTRAWIDE", number: 2), .init(inner: 20, outer: Edges(all: 8), maxWidth: nil))
        XCTAssertEqual(c.displaySettings(name: "Studio Display", number: 2), .init(inner: 30, outer: Edges(all: 40), maxWidth: 3000))
    }

    // MARK: Maximum width

    func testMaxWidthNarrowsAndCentres() {
        let usable = CGRect(x: 8, y: 33, width: 5104, height: 1400)
        XCTAssertEqual(DisplaySettings.narrow(usable, maxWidth: 2560), CGRect(x: 1280, y: 33, width: 2560, height: 1400))
        // A display to the left of the main one has negative x.
        XCTAssertEqual(DisplaySettings.narrow(CGRect(x: -3440, y: 0, width: 3440, height: 1440), maxWidth: 2440),
                       CGRect(x: -2940, y: 0, width: 2440, height: 1440))
        // Centred to a whole point.
        XCTAssertEqual(DisplaySettings.narrow(CGRect(x: 0, y: 0, width: 1001, height: 500), maxWidth: 800).minX, 101)
    }

    func testMaxWidthLeavesANarrowerAreaAlone() {
        let usable = CGRect(x: 8, y: 33, width: 1496, height: 941)
        XCTAssertEqual(DisplaySettings.narrow(usable, maxWidth: 2560), usable)
        XCTAssertEqual(DisplaySettings.narrow(usable, maxWidth: 1496), usable)
        XCTAssertEqual(DisplaySettings.narrow(usable, maxWidth: nil), usable)
    }

    // MARK: Elsewhere

    func testTheSchemaDescribesTheKeysThatAreRead() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let display = try XCTUnwrap((schema["properties"] as? [String: Any])?["display"] as? [String: Any])
        let item = try XCTUnwrap(display["items"] as? [String: Any])
        let properties = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["name", "number", "inner", "outer", "max-width"])
        let (_, warnings) = try load("[[display]]\nname = \"LG\"\ninner = 1\nouter = { top = 1, left = 1, bottom = 1, right = 1 }\nmax-width = 999\n")
        XCTAssertEqual(warnings, [])
    }

    /// A drop is tried out with the gap of the display it lands on.
    func testADropUsesTheGapOfItsDisplay() throws {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 600), right = CGRect(x: 1000, y: 0, width: 800, height: 600)
        func row(_ ids: WindowID...) -> Tree {
            Tree(snapshot: NodeSnapshot(window: nil, orientation: .horizontal, weight: 1,
                                        children: ids.map { NodeSnapshot(window: $0, orientation: nil, weight: 1, children: nil) }))
        }
        let home = row(1, 2), there = row(3)
        var tiles = computeLayout(home, in: left, gap: 0, visible: [1, 2, 3])
        tiles.merge(computeLayout(there, in: right, gap: 40, visible: [1, 2, 3])) { a, _ in a }
        let plan = try XCTUnwrap(DragDrop.plan(DropScene(
            dragged: 1, pointer: CGPoint(x: 1400, y: 300), tiles: tiles, frontToBack: [1, 2, 3],
            desks: [DropScene.Desk(tree: home, area: left), DropScene.Desk(tree: there, area: right, gap: 40)], visible: [1, 2, 3])))

        let homeAfter = Tree(snapshot: home.snapshot), thereAfter = Tree(snapshot: there.snapshot)
        XCTAssertTrue(DragDrop.carryOut(plan.drop, of: 1, in: [homeAfter, thereAfter], visible: [1, 2, 3]))
        XCTAssertEqual(plan.rect, computeLayout(thereAfter, in: right, gap: 40, visible: [1, 2, 3])[1])
        XCTAssertNotEqual(plan.rect, computeLayout(thereAfter, in: right, gap: 0, visible: [1, 2, 3])[1])
    }
}
