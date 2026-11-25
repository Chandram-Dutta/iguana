import XCTest
@testable import IguanaCore

/// Commands as text: what `Command.parse` reads and what it refuses.
final class CommandTests: XCTestCase {
    func testCommands() throws {
        XCTAssertEqual(try Command.parse("focus left"), .focus(.left))
        XCTAssertEqual(try Command.parse("  Move   DOWN "), .move(.down))
        XCTAssertEqual(try Command.parse("resize grow"), .resize(axis: nil, grow: 1))
        XCTAssertEqual(try Command.parse("resize height shrink"), .resize(axis: .vertical, grow: -1))
        XCTAssertEqual(try Command.parse("space prev"), .space(.prev))
        XCTAssertEqual(try Command.parse("move-to-space 4"), .moveToSpace(.index(4), follow: true))
        XCTAssertEqual(try Command.parse("move-to-space next --stay"), .moveToSpace(.next, follow: false))
        XCTAssertEqual(try Command.parse("move-to-space --stay 2"), .moveToSpace(.index(2), follow: false))
        XCTAssertEqual(try Command.parse("move-to-space 2 --follow"), .moveToSpace(.index(2), follow: true))
        XCTAssertThrowsError(try Command.parse("space 2 --stay"))
        XCTAssertThrowsError(try Command.parse("move-to-space --stay"))
        XCTAssertThrowsError(try Command.parse("move-to-space 2 --stay --follow"))
        for bad in ["", "focus", "focus north", "space 0", "space 99", "resize", "zoom now", "nope"] {
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
    }
}
