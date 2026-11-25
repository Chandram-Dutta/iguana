import XCTest
@testable import IguanaCore

/// `focus recent`, `space recent` and `move-to-space recent`: what they go back to, and how they are written.
final class RecentTests: XCTestCase {
    let any: (WindowID) -> Bool = { _ in true }

    // MARK: Windows

    func testFocusRecentGoesBackAndForth() {
        var history = FocusHistory()
        history.record(1)
        history.record(2)
        XCTAssertEqual(history.previous(current: 2, eligible: any), 1)
        history.record(1)
        XCTAssertEqual(history.previous(current: 1, eligible: any), 2, "pressed twice, it is back where it started")
        history.record(2)
        XCTAssertEqual(history.previous(current: 2, eligible: any), 1)
    }

    func testNothingToGoBackTo() {
        var history = FocusHistory()
        XCTAssertNil(history.previous(current: nil, eligible: any))
        history.record(1)
        XCTAssertNil(history.previous(current: 1, eligible: any), "the only window is the focused one")
        XCTAssertEqual(history.previous(current: nil, eligible: any), 1, "with no window focused, the last one counts")
    }

    func testAClosedWindowIsSkipped() {
        var history = FocusHistory()
        for id: WindowID in [1, 2, 3] { history.record(id) }
        history.forget(2)
        XCTAssertEqual(history.windows, [3, 1])
        XCTAssertEqual(history.previous(current: 3, eligible: any), 1)
        history.forget(9)
        XCTAssertEqual(history.windows, [3, 1], "forgetting a window it never saw changes nothing")
    }

    func testAWindowThatIsNotEligibleIsPassedOverButKept() {
        var history = FocusHistory()
        for id: WindowID in [1, 2, 3] { history.record(id) }
        // Window 2 is on a desktop that is not being shown.
        XCTAssertEqual(history.previous(current: 3, eligible: { $0 != 2 }), 1)
        XCTAssertNil(history.previous(current: 3, eligible: { $0 == 3 }), "the focused window itself never counts")
        XCTAssertEqual(history.previous(current: 3, eligible: any), 2, "back on screen, it is next again")
    }

    func testAWindowIsInTheHistoryOnceAtItsLatestPlace() {
        var history = FocusHistory()
        for id: WindowID in [1, 2, 1, 3, 1, 1] { history.record(id) }
        XCTAssertEqual(history.windows, [1, 3, 2])
    }

    func testTheHistoryIsBounded() {
        var history = FocusHistory()
        for id in 1...WindowID(FocusHistory.limit + 10) { history.record(id) }
        XCTAssertEqual(history.windows.count, FocusHistory.limit)
        XCTAssertEqual(history.windows.first, WindowID(FocusHistory.limit + 10))
        XCTAssertEqual(history.windows.last, 11, "the oldest are forgotten first")
    }

    // MARK: Desktops

    func testSpaceRecentTogglesBetweenTwoDesktops() {
        var history = DesktopHistory()
        XCTAssertNil(history.previous(display: "laptop"))
        history.record(display: "laptop", space: 10)
        XCTAssertNil(history.previous(display: "laptop", showing: 10), "nothing was shown before the first desktop")
        history.record(display: "laptop", space: 20)
        XCTAssertEqual(history.previous(display: "laptop", showing: 20), 10)
        history.record(display: "laptop", space: 10)
        XCTAssertEqual(history.previous(display: "laptop", showing: 10), 20)
        history.record(display: "laptop", space: 20)
        XCTAssertEqual(history.previous(display: "laptop"), 10)
    }

    func testLookingAgainAtTheSameDesktopIsNotAChange() {
        var history = DesktopHistory()
        for space: UInt64 in [10, 20, 20, 20] { history.record(display: "laptop", space: space) }
        XCTAssertEqual(history.previous(display: "laptop", showing: 20), 10)
        history.record(display: "laptop", space: 30)
        XCTAssertEqual(history.previous(display: "laptop", showing: 30), 20)
    }

    func testFromAFullscreenSpaceTheWayBackIsTheLastDesktop() {
        var history = DesktopHistory()
        history.record(display: "laptop", space: 10)
        history.record(display: "laptop", space: 20)
        // An app went fullscreen. Its Space is never recorded.
        XCTAssertEqual(history.previous(display: "laptop", showing: 99), 20)
    }

    func testDisplaysKeepTheirOwnHistory() {
        var history = DesktopHistory()
        history.record(display: "laptop", space: 10)
        history.record(display: "monitor", space: 40)
        history.record(display: "laptop", space: 20)
        history.record(display: "monitor", space: 50)
        XCTAssertEqual(history.previous(display: "laptop", showing: 20), 10)
        XCTAssertEqual(history.previous(display: "monitor", showing: 50), 40)
        XCTAssertNil(history.previous(display: "projector"))
    }

    // MARK: Commands

    func testParsingRecent() throws {
        XCTAssertEqual(try Command.parse("focus recent"), .focusRecent)
        XCTAssertEqual(try Command.parse("Focus RECENT"), .focusRecent)
        XCTAssertEqual(try Command.parse("focus left"), .focus(.left), "directions are unchanged")
        XCTAssertEqual(try Command.parse("space recent"), .space(.recent))
        XCTAssertEqual(try Command.parse("move-to-space recent"), .moveToSpace(.recent, follow: true))
        XCTAssertEqual(try Command.parse("move-to-space recent --stay"), .moveToSpace(.recent, follow: false))
        XCTAssertEqual(try Command.parse("move-to-space --follow recent"), .moveToSpace(.recent, follow: true))
        for bad in ["focus recent left", "focus recent recent", "move recent", "join recent", "space recent 2", "space recent --stay",
                    "move-to-space recent --stay --follow", "space last"] {
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
    }

    func testErrorsNameRecent() {
        func message(_ text: String) -> String {
            do {
                _ = try Command.parse(text)
                return ""
            } catch {
                return "\(error)"
            }
        }
        XCTAssertEqual(message("focus north"), "'focus' needs one of: left, right, up, down, recent")
        XCTAssertEqual(message("move north"), "'move' needs one of: left, right, up, down", "only focus has a recent")
        XCTAssertEqual(message("space"), "'space' needs a Space number, 'next', 'prev' or 'recent'")
        XCTAssertEqual(message("move-to-space 99"), "'move-to-space' needs a Space number from 1 to 16, 'next', 'prev' or 'recent'")
    }

    func testTheDefaultShortcuts() throws {
        let bindings = Config.default.bindings
        XCTAssertEqual(bindings.first { $0.source == "option-tab" }?.command, .focusRecent)
        XCTAssertEqual(bindings.first { $0.source == "option-shift-tab" }?.command, .space(.recent))
        XCTAssertTrue(Command.usage.contains("focus left|right|up|down|recent"))
        XCTAssertTrue(Command.usage.contains("space N|next|prev|recent"))
        XCTAssertTrue(Command.usage.contains("move-to-space N|next|prev|recent --stay"))
    }

    /// The schema that editors check a config file against takes the new words too.
    func testTheSchemaTakesRecent() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let bindings = try XCTUnwrap((schema["properties"] as? [String: Any])?["bindings"] as? [String: Any])
        let entry = try XCTUnwrap((bindings["patternProperties"] as? [String: Any])?.values.first as? [String: Any])
        let choices = try XCTUnwrap(entry["oneOf"] as? [[String: Any]])
        func accepted(_ command: String) throws -> Int {
            try choices.filter { choice in
                if let constant = choice["const"] as? String { return constant == command }
                if let list = choice["enum"] as? [String] { return list.contains(command) }
                guard let pattern = choice["pattern"] as? String else { return false }
                return try NSRegularExpression(pattern: pattern).firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
            }.count
        }
        for command in ["focus recent", "space recent", "move-to-space recent", "move-to-space recent --stay", "focus left"] {
            XCTAssertEqual(try accepted(command), 1, command)
        }
        XCTAssertEqual(try accepted("move recent"), 0)
    }
}
