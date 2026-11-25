import XCTest
@testable import IguanaCore

/// Placing floating windows: the `place` command's frames, where a window goes that will not
/// take its size, and rules that size and place an app's windows when they open.
final class PlacementTests: XCTestCase {
    /// A display's usable area that does not start at zero, as on a second display or below the menu bar.
    private let area = CGRect(x: 100, y: 50, width: 1000, height: 800)
    private let gap = 10.0

    private func frame(_ p: Placement, size: CGSize = CGSize(width: 400, height: 300)) -> CGRect {
        p.frame(in: area, gap: gap, size: size)
    }

    func testEveryPlacement() {
        XCTAssertEqual(frame(.left), CGRect(x: 100, y: 50, width: 495, height: 800))
        XCTAssertEqual(frame(.right), CGRect(x: 605, y: 50, width: 495, height: 800))
        XCTAssertEqual(frame(.top), CGRect(x: 100, y: 50, width: 1000, height: 395))
        XCTAssertEqual(frame(.bottom), CGRect(x: 100, y: 455, width: 1000, height: 395))
        XCTAssertEqual(frame(.topLeft), CGRect(x: 100, y: 50, width: 495, height: 395))
        XCTAssertEqual(frame(.topRight), CGRect(x: 605, y: 50, width: 495, height: 395))
        XCTAssertEqual(frame(.bottomLeft), CGRect(x: 100, y: 455, width: 495, height: 395))
        XCTAssertEqual(frame(.bottomRight), CGRect(x: 605, y: 455, width: 495, height: 395))
        XCTAssertEqual(frame(.full), area, "full fills the area, inside the outer gaps")
        XCTAssertEqual(frame(.center), CGRect(x: 400, y: 300, width: 400, height: 300), "center keeps the window's size")

        // Neighbouring halves and quarters leave exactly the inner gap between them.
        XCTAssertEqual(frame(.right).minX - frame(.left).maxX, 10)
        XCTAssertEqual(frame(.bottom).minY - frame(.top).maxY, 10)
        XCTAssertEqual(frame(.bottomRight).minX - frame(.bottomLeft).maxX, 10)
        // Only center looks at the window's size.
        for p in Placement.allCases where p != .center {
            XCTAssertEqual(frame(p, size: CGSize(width: 123, height: 456)), frame(p), p.rawValue)
        }
        XCTAssertEqual(Placement.left.frame(in: area, gap: 0, size: .zero).width, 500)
    }

    func testCenterShrinksAWindowBiggerThanTheArea() {
        XCTAssertEqual(frame(.center, size: CGSize(width: 1200, height: 500)), CGRect(x: 100, y: 200, width: 1000, height: 500))
        XCTAssertEqual(frame(.center, size: CGSize(width: 2000, height: 2000)), area)
    }

    func testAWindowThatRefusesItsSizeKeepsToThePlacementsEdges() {
        func fit(_ p: Placement, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            p.fit(CGSize(width: w, height: h), to: frame(p), in: area)
        }
        // Too wide for its half: a left placement keeps its left edge, a right one its right edge.
        XCTAssertEqual(fit(.left, 600, 800), CGRect(x: 100, y: 50, width: 600, height: 800))
        XCTAssertEqual(fit(.right, 600, 800), CGRect(x: 500, y: 50, width: 600, height: 800))
        XCTAssertEqual(fit(.bottom, 1000, 500), CGRect(x: 100, y: 350, width: 1000, height: 500))
        // A window of a fixed, smaller size goes into the corner, or is centred along the side.
        XCTAssertEqual(fit(.bottomRight, 300, 200), CGRect(x: 800, y: 650, width: 300, height: 200))
        XCTAssertEqual(fit(.topLeft, 300, 200), CGRect(x: 100, y: 50, width: 300, height: 200))
        XCTAssertEqual(fit(.left, 300, 200), CGRect(x: 100, y: 350, width: 300, height: 200))
        XCTAssertEqual(fit(.center, 500, 500), CGRect(x: 350, y: 200, width: 500, height: 500), "still centred")
        // Bigger than the whole area: the top-left corner stays in it, so the title bar can be reached.
        XCTAssertEqual(fit(.full, 1200, 900), CGRect(x: 100, y: 50, width: 1200, height: 900))
        XCTAssertEqual(fit(.bottomRight, 1200, 900), CGRect(x: 100, y: 50, width: 1200, height: 900))
        XCTAssertEqual(fit(.center, 1200, 900), CGRect(x: 100, y: 50, width: 1200, height: 900))
        // A window that took its size stays where it was put.
        for p in Placement.allCases { XCTAssertEqual(p.fit(frame(p).size, to: frame(p), in: area), frame(p), p.rawValue) }
    }

    func testTheCommand() throws {
        for p in Placement.allCases { XCTAssertEqual(try Command.parse("place \(p.rawValue)"), .place(p)) }
        XCTAssertEqual(try Command.parse("PLACE Top-Left"), .place(.topLeft))
        for bad in ["place", "place middle", "place left right", "place centre"] {
            XCTAssertThrowsError(try Command.parse(bad), bad) { error in
                XCTAssertEqual("\(error)", "'place' needs one of: center, left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, full")
            }
        }
        // The usage line lists every placement, in order.
        let line = try XCTUnwrap(Command.usage.split(separator: "\n").first { $0.hasPrefix("place ") })
        XCTAssertEqual(line.split(separator: " ")[1], Substring(Placement.allCases.map(\.rawValue).joined(separator: "|")))
    }

    // MARK: Rules

    /// Where a window opened, before any rule.
    private let opened = CGRect(x: 700, y: 600, width: 300, height: 200)
    private let size = CGSize(width: 400, height: 600)

    private func ruled(size: CGSize? = nil, position: Placement? = nil, float: Bool? = true, desktop: Int? = nil) -> CGRect? {
        Rule(app: "Calculator", title: nil, float: float, desktop: desktop, size: size, position: position)
            .frame(for: opened, in: area, gap: gap)
    }

    func testARuleWithOnlyASizeKeepsTheTopLeftCorner() {
        // The window would hang below the area at its new height, so it moves up as far as it must.
        XCTAssertEqual(ruled(size: size), CGRect(x: 700, y: 250, width: 400, height: 600))
        XCTAssertEqual(ruled(size: CGSize(width: 200, height: 100)), CGRect(x: 700, y: 600, width: 200, height: 100))
        XCTAssertEqual(ruled(size: CGSize(width: 2000, height: 900)), area, "never bigger than the area")
    }

    func testARuleWithOnlyAPositionUsesTheWindowsOwnSize() {
        XCTAssertEqual(ruled(position: .center), CGRect(x: 450, y: 350, width: 300, height: 200))
        XCTAssertEqual(ruled(position: .left), frame(.left))
        XCTAssertEqual(ruled(position: .full), area)
    }

    func testARuleWithBothSizesTheWindowFirst() {
        XCTAssertEqual(ruled(size: size, position: .center), CGRect(x: 400, y: 150, width: 400, height: 600))
        // Halves, quarters and full have a size of their own.
        XCTAssertEqual(ruled(size: size, position: .right), frame(.right))
        XCTAssertEqual(ruled(size: size, position: .bottomLeft), frame(.bottomLeft))
        XCTAssertEqual(ruled(size: size, position: .full), area)
    }

    func testOnlyARuleThatFloatsPlacesWindows() {
        XCTAssertNil(ruled(), "nothing to do")
        XCTAssertNil(ruled(size: size, position: .center, float: false))
        XCTAssertNil(ruled(position: .center, float: nil, desktop: 3), "a rule with only a desktop does not float its windows")
        XCTAssertNotNil(ruled(position: .center, float: true, desktop: 3))
        XCTAssertNotNil(ruled(position: .center, float: nil), "a rule with neither float nor desktop floats")
    }

    func testWhereARuledWindowGoesIfItRefusesTheSize() {
        let sized = Rule(app: "Calculator", title: nil, size: size)
        let asked = CGRect(x: 700, y: 250, width: 400, height: 600)
        XCTAssertEqual(sized.fit(CGSize(width: 500, height: 600), to: asked, in: area), CGRect(x: 600, y: 250, width: 500, height: 600),
                       "it keeps its top-left corner, moved in as far as it must")
        let right = Rule(app: "Calculator", title: nil, position: .right)
        XCTAssertEqual(right.fit(CGSize(width: 600, height: 800), to: frame(.right), in: area), CGRect(x: 500, y: 50, width: 600, height: 800))
    }

    func testRulesCanGiveASizeAndAPosition() throws {
        let (c, warnings) = try Config.load("""
        [[rule]]
        app = "com.apple.calculator"
        float = true
        size = [400, 600]
        position = "center"

        [[rule]]
        app = "Preview"
        size = [800.5, 600]

        [[rule]]
        app = "Notes"
        float = true
        desktop = 2
        position = "bottom-right"

        [[rule]]
        app = "Music"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.rules.map(\.size), [size, CGSize(width: 800.5, height: 600), nil, nil])
        XCTAssertEqual(c.rules.map(\.position), [.center, nil, .bottomRight, nil])
        XCTAssertEqual(c.rules.map(\.placesWindows), [true, true, true, false])
        XCTAssertEqual(c.rules[0], Rule(app: "com.apple.calculator", title: nil, float: true, size: size, position: .center))
        XCTAssertEqual(Config.default.rules.map(\.size), [nil, nil, nil])
        XCTAssertEqual(Config.default.rules.map(\.position), [nil, nil, nil])
        // Every name the command takes is a position a rule can name.
        for p in Placement.allCases {
            let (c, warnings) = try Config.load("[[rule]]\napp = \"Notes\"\nposition = \"\(p.rawValue)\"\n")
            XCTAssertEqual(c.rules.first?.position, p)
            XCTAssertEqual(warnings, [])
        }
    }

    func testAWrongSizeOrPositionIsIgnoredOnItsOwn() throws {
        for bad in ["[400]", "[400, 600, 800]", "[99, 600]", "[400, 10001]", "[400, -600]", "\"400x600\"", "400", "[\"400\", \"600\"]", "[true, 600]"] {
            let (c, warnings) = try Config.load("[[rule]]\napp = \"Notes\"\nsize = \(bad)\nposition = \"left\"\n")
            XCTAssertEqual(warnings, ["rule 1: size must be two numbers from 100 to 10000, such as [400, 600]; ignoring it"], "size = \(bad)")
            XCTAssertEqual(c.rules, [Rule(app: "Notes", title: nil, position: .left)], "the rest of the rule still applies: size = \(bad)")
        }
        for good in ["[100, 10000]", "[100.0, 250.5]"] {
            let (c, warnings) = try Config.load("[[rule]]\napp = \"Notes\"\nsize = \(good)\n")
            XCTAssertEqual(warnings, [], good)
            XCTAssertNotNil(c.rules.first?.size, good)
        }
        for bad in ["\"centre\"", "\"middle\"", "\"Left\"", "3", "true", "[\"left\"]"] {
            let (c, warnings) = try Config.load("[[rule]]\napp = \"Notes\"\nsize = [400, 600]\nposition = \(bad)\n")
            XCTAssertEqual(warnings, ["rule 1: position must be one of: center, left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, full; ignoring it"], "position = \(bad)")
            XCTAssertEqual(c.rules, [Rule(app: "Notes", title: nil, size: size)], "position = \(bad)")
        }
    }

    func testARuleThatDoesNotFloatIgnoresSizeAndPosition() throws {
        let (c, warnings) = try Config.load("""
        [[rule]]
        app = "Slack"
        desktop = 3
        size = [400, 600]
        position = "center"

        [[rule]]
        app = "Safari"
        float = false
        position = "left"

        [[rule]]
        app = "Mail"
        float = false
        size = [1, 1]
        """)
        XCTAssertEqual(warnings, [
            "rule 1: size and position are only for windows the rule floats, so they have no effect here",
            "rule 2: position is only for windows the rule floats, so it has no effect here",
            "rule 3: size must be two numbers from 100 to 10000, such as [400, 600]; ignoring it",
        ])
        // They do nothing, but stay in the rule, so the settings window can write them back.
        XCTAssertEqual(c.rules.map(\.placesWindows), [false, false, false])
        XCTAssertEqual(c.rules.map(\.position), [.center, .left, nil])
        XCTAssertEqual(c.rules.map(\.desktop), [3, nil, nil], "the rest of each rule still applies")
    }

    func testTheSchemaDescribesSizeAndPosition() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let rule = try XCTUnwrap((properties["rule"] as? [String: Any])?["items"] as? [String: Any])
        let keys = try XCTUnwrap(rule["properties"] as? [String: Any])
        let position = try XCTUnwrap(keys["position"] as? [String: Any])
        XCTAssertEqual(position["enum"] as? [String], Placement.allCases.map(\.rawValue))
        let size = try XCTUnwrap(keys["size"] as? [String: Any])
        XCTAssertEqual(size["minItems"] as? Int, 2)
        XCTAssertEqual(size["maxItems"] as? Int, 2)
        let item = try XCTUnwrap(size["items"] as? [String: Any])
        XCTAssertEqual(item["minimum"] as? Double, Rule.sizeRange.lowerBound)
        XCTAssertEqual(item["maximum"] as? Double, Rule.sizeRange.upperBound)

        // A shortcut can run every `place` command.
        let bindings = try XCTUnwrap((properties["bindings"] as? [String: Any])?["patternProperties"] as? [String: Any])
        let command = try XCTUnwrap(bindings.values.first as? [String: Any])
        let patterns = (command["oneOf"] as? [[String: Any]] ?? []).compactMap { $0["pattern"] as? String }
        for p in Placement.allCases {
            let text = "place \(p.rawValue)"
            XCTAssertTrue(patterns.contains { text.range(of: $0, options: .regularExpression) != nil }, text)
        }
        XCTAssertFalse(patterns.contains { "place middle".range(of: $0, options: .regularExpression) != nil })
    }

    // MARK: Which windows are new

    private let start = Date(timeIntervalSince1970: 1_000)
    private let rule = Rule(app: "Calculator", title: nil, size: CGSize(width: 400, height: 600), position: .center)

    private func entry(_ window: WindowID) -> PlacementRuleQueue.Entry {
        PlacementRuleQueue.Entry(window: window, rule: rule, app: "Calculator")
    }

    func testOnlyWindowsThatOpenWhileIguanaRunsArePlacedAndOnlyOnce() {
        var queue = PlacementRuleQueue()
        queue.note(7, rule: rule, app: "Calculator", at: start)
        queue.firstLook(existing: [7, 8])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "nothing counts as new before the first look")
        queue.note(8, rule: rule, app: "Calculator", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "window 8 was open all along, out of sight")
        queue.note(12, rule: rule, app: "Calculator", at: start)
        queue.note(13, rule: Rule(app: "Calculator", title: nil, float: false, size: size), app: "Calculator", at: start)
        queue.note(14, rule: Rule(app: "Calculator", title: nil), app: "Calculator", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [entry(12)], "only rules that place the windows they float")
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "after that the window is the user's to move")
    }

    func testReadingTheConfigAgainPlacesNothingThatIsOpen() {
        var queue = PlacementRuleQueue()
        queue.firstLook(existing: [])
        queue.note(12, rule: rule, app: "Calculator", at: start)
        queue.markExisting([12, 14])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
        queue.note(14, rule: rule, app: "Calculator", at: start)
        queue.note(15, rule: rule, app: "Calculator", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [entry(15)])
    }

    func testAWindowGetsAMomentToSettleAndNothingIsPlacedWhilePaused() {
        var queue = PlacementRuleQueue()
        queue.firstLook(existing: [])
        queue.note(12, rule: rule, app: "Calculator", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in false }, [], "not a standard window yet")
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(1), paused: false) { _ in true }, [entry(12)])

        queue.note(20, rule: rule, app: "Calculator", at: start)
        let late = start.addingTimeInterval(DesktopRuleQueue.patience + 0.1)
        XCTAssertEqual(queue.due(at: late, paused: false) { _ in true }, [], "too late: the user may be working in it")

        queue.note(30, rule: rule, app: "Calculator", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in nil }, [], "gone, or tiled by hand meanwhile")
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])

        queue.note(40, rule: rule, app: "Calculator", at: start)
        XCTAssertEqual(queue.due(at: start, paused: true) { _ in true }, [])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "and it does not jump when tiling resumes")
    }
}
