import XCTest
@testable import IguanaCore

/// How displays are numbered: from 1, left to right, and top to bottom where two displays
/// share a left edge. Frames are in top-left coordinates, so above the main display is a
/// negative y.
final class DisplayOrderTests: XCTestCase {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testSideBySideCountsFromTheLeft() {
        let right = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(DisplayOrder.order([laptop, right]), [0, 1])
        XCTAssertEqual(DisplayOrder.numbers([laptop, right]), [1, 2])

        // The main display is not display 1 when another one is on its left.
        let left = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        XCTAssertEqual(DisplayOrder.order([laptop, left]), [1, 0])
        XCTAssertEqual(DisplayOrder.numbers([laptop, left]), [2, 1])
    }

    func testAVerticalStackGoesByTheLeftEdgeFirst() {
        // A wide display above the laptop that reaches further to the left comes first, and
        // one below that starts further right comes after it, whatever their height.
        let above = CGRect(x: -500, y: -1440, width: 2560, height: 1440)
        let below = CGRect(x: 200, y: 982, width: 1920, height: 1080)
        XCTAssertEqual(DisplayOrder.order([laptop, above, below]), [1, 0, 2])
        XCTAssertEqual(DisplayOrder.numbers([laptop, above, below]), [2, 1, 3])
    }

    func testASharedLeftEdgeCountsFromTheTop() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(DisplayOrder.order([laptop, above]), [1, 0])
        XCTAssertEqual(DisplayOrder.numbers([laptop, above]), [2, 1])
        let below = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        XCTAssertEqual(DisplayOrder.numbers([laptop, below]), [1, 2])
    }

    func testFramesAlreadyInOrderKeepIt() {
        let frames = [laptop, CGRect(x: 1512, y: 0, width: 1920, height: 1080), CGRect(x: 3432, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(DisplayOrder.order(frames), [0, 1, 2])
        XCTAssertEqual(DisplayOrder.numbers(frames), [1, 2, 3])
    }

    func testFramesInReverseAreCountedFromTheLeft() {
        let frames = [CGRect(x: 3432, y: 0, width: 1920, height: 1080), CGRect(x: 1512, y: 0, width: 1920, height: 1080), laptop]
        XCTAssertEqual(DisplayOrder.order(frames), [2, 1, 0])
        XCTAssertEqual(DisplayOrder.numbers(frames), [3, 2, 1])
    }

    func testASingleDisplayIsDisplayOne() {
        XCTAssertEqual(DisplayOrder.order([laptop]), [0])
        XCTAssertEqual(DisplayOrder.numbers([laptop]), [1])
        XCTAssertEqual(DisplayOrder.numbers([]), [])
    }
}
