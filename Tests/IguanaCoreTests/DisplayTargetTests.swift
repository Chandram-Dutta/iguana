import XCTest
@testable import IguanaCore

/// `focus-display` and `move-to-display`: which display they go to, which window gets the
/// focus there, and where a floating window lands.
final class DisplayTargetTests: XCTestCase {
    func position(_ target: DisplayTarget, active: Int?, count: Int) -> Int? {
        try? target.resolve(active: active, count: count).get()
    }

    func reply(_ target: DisplayTarget, active: Int? = 0, count: Int) -> String? {
        guard case .failure(let refusal) = target.resolve(active: active, count: count) else { return nil }
        return refusal.reply
    }

    // MARK: Which display

    func testNextAndPrevWrapAroundFromTheActiveDisplay() {
        XCTAssertEqual(position(.next, active: 0, count: 3), 1)
        XCTAssertEqual(position(.next, active: 2, count: 3), 0, "after the last display comes the first")
        XCTAssertEqual(position(.prev, active: 1, count: 3), 0)
        XCTAssertEqual(position(.prev, active: 0, count: 3), 2, "before the first display comes the last")
        XCTAssertEqual(position(.next, active: 1, count: 2), 0)
        XCTAssertEqual(position(.prev, active: 1, count: 2), 0)
    }

    func testWithoutAnActiveDisplayNextIsTheFirstAndPrevTheLast() {
        XCTAssertEqual(position(.next, active: nil, count: 3), 0)
        XCTAssertEqual(position(.prev, active: nil, count: 3), 2)
        XCTAssertEqual(position(.next, active: 7, count: 3), 0, "a position that is not there counts as none")
    }

    func testANumberIsTheDisplayInDisplayOrder() {
        XCTAssertEqual(position(.index(1), active: 2, count: 3), 0)
        XCTAssertEqual(position(.index(3), active: nil, count: 3), 2)
        XCTAssertEqual(reply(.index(4), count: 3), "error: there is no display 4 (there are 3)")
        XCTAssertEqual(reply(.index(0), count: 2), "error: there is no display 0 (there are 2)")
    }

    func testOneDisplayHasNowhereToGo() {
        for target in [DisplayTarget.next, .prev, .index(1), .index(2)] {
            XCTAssertEqual(reply(target, count: 1), "ok: only one display", "\(target)")
        }
        XCTAssertEqual(reply(.next, active: nil, count: 0), "error: no display")
    }

    // MARK: The commands

    func testParse() throws {
        XCTAssertEqual(try Command.parse("focus-display next"), .focusDisplay(.next))
        XCTAssertEqual(try Command.parse("focus-display prev"), .focusDisplay(.prev))
        XCTAssertEqual(try Command.parse("focus-display previous"), .focusDisplay(.prev))
        XCTAssertEqual(try Command.parse("focus-display 2"), .focusDisplay(.index(2)))
        XCTAssertEqual(try Command.parse("move-to-display 1"), .moveToDisplay(.index(1)))
        XCTAssertEqual(try Command.parse("move-to-display 16"), .moveToDisplay(.index(16)))
        XCTAssertEqual(try Command.parse("MOVE-TO-DISPLAY  Next"), .moveToDisplay(.next))
        for bad in ["focus-display", "focus-display 0", "focus-display 17", "focus-display left", "focus-display 1 2",
                    "move-to-display -1", "move-to-display next --stay"] {
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
        XCTAssertThrowsError(try Command.parse("focus-display 17")) { error in
            XCTAssertEqual("\(error)", "'focus-display' needs a display number from 1 to 16, 'next' or 'prev'")
        }
        XCTAssertThrowsError(try Command.parse("move-to-display")) { error in
            XCTAssertEqual("\(error)", "'move-to-display' needs a display number, 'next' or 'prev'")
        }
        XCTAssertFalse(try Command.parseRequest("focus-display 2").json)
        XCTAssertThrowsError(try Command.parseRequest("focus-display 2 --json"), "only the reports have a JSON form")
    }

    func testUsageAndDefaultShortcuts() {
        XCTAssertTrue(Command.usage.contains("focus-display next|prev|N"))
        XCTAssertTrue(Command.usage.contains("move-to-display next|prev|N"))
        let shortcuts = Dictionary(uniqueKeysWithValues: Config.default.bindings.map { ($0.source, $0.command) })
        XCTAssertEqual(shortcuts["option-comma"], .focusDisplay(.prev))
        XCTAssertEqual(shortcuts["option-period"], .focusDisplay(.next))
        XCTAssertEqual(shortcuts["option-shift-comma"], .moveToDisplay(.prev))
        XCTAssertEqual(shortcuts["option-shift-period"], .moveToDisplay(.next))
    }

    func testTheSchemaAcceptsTheCommandsInAShortcut() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let bindings = try XCTUnwrap((schema["properties"] as? [String: Any])?["bindings"] as? [String: Any])
        let value = try XCTUnwrap((bindings["patternProperties"] as? [String: Any])?.values.first as? [String: Any])
        let patterns = try XCTUnwrap(value["oneOf"] as? [[String: Any]]).compactMap { $0["pattern"] as? String }
        func accepted(_ command: String) -> Bool {
            patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
        }
        for good in ["focus-display next", "focus-display previous", "move-to-display prev", "move-to-display 1", "focus-display 16"] {
            XCTAssertTrue(accepted(good), good)
            XCTAssertNoThrow(try Command.parse(good), good)
        }
        for bad in ["focus-display 0", "focus-display 17", "move-to-display", "move-to-display next --stay"] {
            XCTAssertFalse(accepted(bad), bad)
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
    }

    // MARK: Which window gets the focus

    let centre = CGPoint(x: 1000, y: 500)
    let left = CGRect(x: 0, y: 0, width: 600, height: 1000)
    let middle = CGRect(x: 700, y: 0, width: 600, height: 1000)
    let right = CGRect(x: 1400, y: 0, width: 600, height: 1000)

    func testTheWindowLastFocusedThereComesFirst() {
        XCTAssertEqual(DisplayTarget.windowToFocus(remembered: 3, tiles: [1: left, 2: middle, 3: right], others: [9], centre: centre), 3)
    }

    func testOtherwiseTheTileNearestTheCentre() {
        let tiles: [WindowID: CGRect] = [1: left, 2: middle, 3: right]
        XCTAssertEqual(DisplayTarget.windowToFocus(remembered: nil, tiles: tiles, others: [9], centre: centre), 2)
        XCTAssertEqual(DisplayTarget.windowToFocus(remembered: 4, tiles: tiles, others: [], centre: centre), 2,
                       "a remembered window that is not on screen there does not count")
        // Two tiles as near as each other: the same one every time.
        let pair: [WindowID: CGRect] = [8: CGRect(x: 0, y: 0, width: 1000, height: 1000), 5: CGRect(x: 1000, y: 0, width: 1000, height: 1000)]
        XCTAssertEqual(DisplayTarget.windowToFocus(remembered: nil, tiles: pair, others: [], centre: centre), 5)
    }

    func testOtherwiseTheFrontmostOtherWindow() {
        XCTAssertEqual(DisplayTarget.windowToFocus(remembered: 1, tiles: [:], others: [7, 6], centre: centre), 7)
        XCTAssertNil(DisplayTarget.windowToFocus(remembered: 1, tiles: [:], others: [], centre: centre))
    }

    // MARK: Where a floating window lands

    let laptop = CGRect(x: 0, y: 38, width: 1512, height: 900)
    let studio = CGRect(x: 1512, y: -200, width: 2560, height: 1400)

    func testAFloatingWindowKeepsItsSizeAndItsPlaceInProportion() {
        // In the middle stays in the middle.
        let centred = CGRect(x: 456, y: 288, width: 600, height: 400)
        XCTAssertEqual(DisplayTarget.floatingFrame(centred, from: laptop, to: studio), CGRect(x: 2492, y: 300, width: 600, height: 400))
        // Against the top left corner stays there, against the right edge stays against it.
        XCTAssertEqual(DisplayTarget.floatingFrame(CGRect(x: 0, y: 38, width: 600, height: 400), from: laptop, to: studio),
                       CGRect(x: 1512, y: -200, width: 600, height: 400))
        XCTAssertEqual(DisplayTarget.floatingFrame(CGRect(x: 912, y: 538, width: 600, height: 400), from: laptop, to: studio),
                       CGRect(x: 3472, y: 800, width: 600, height: 400))
        // A quarter of the way along the room it has.
        XCTAssertEqual(DisplayTarget.floatingFrame(CGRect(x: 2002, y: -200, width: 600, height: 400), from: studio, to: laptop),
                       CGRect(x: 228, y: 38, width: 600, height: 400))
    }

    func testAFloatingWindowTooBigForTheDisplayIsMadeToFit() {
        let big = CGRect(x: 1600, y: -100, width: 2000, height: 1200)
        let landed = DisplayTarget.floatingFrame(big, from: studio, to: laptop)
        XCTAssertEqual(landed.size, CGSize(width: 1512, height: 900))
        XCTAssertEqual(landed, laptop)
    }

    func testAFloatingWindowAlwaysLandsInside() {
        // Partly off the edge of its display.
        let hanging = CGRect(x: -300, y: 800, width: 600, height: 400)
        let landed = DisplayTarget.floatingFrame(hanging, from: laptop, to: studio)
        XCTAssertTrue(studio.contains(landed), "\(landed)")
        XCTAssertEqual(landed.origin, CGPoint(x: 1512, y: 800))
        // As big as its display, or bigger: centred on the one it goes to.
        let filling = CGRect(x: -10, y: 30, width: 1600, height: 950)
        XCTAssertEqual(DisplayTarget.floatingFrame(filling, from: laptop, to: studio), CGRect(x: 1992, y: 25, width: 1600, height: 950))
        for _ in 0..<200 {
            let frame = CGRect(x: .random(in: -2000...4000), y: .random(in: -1000...2000), width: .random(in: 50...3000), height: .random(in: 50...2000))
            let landed = DisplayTarget.floatingFrame(frame, from: laptop, to: studio)
            XCTAssertTrue(studio.insetBy(dx: -0.001, dy: -0.001).contains(landed), "\(frame) -> \(landed)")
            XCTAssertEqual(landed.width, min(frame.width, studio.width))
            XCTAssertEqual(landed.height, min(frame.height, studio.height))
        }
    }
}
