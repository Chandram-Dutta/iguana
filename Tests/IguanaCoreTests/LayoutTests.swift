import CoreGraphics
import XCTest
@testable import IguanaCore

/// Where the windows of a tree land on the screen, and which one is nearest in a direction.
final class LayoutTests: XCTestCase, TestScreen {
    func testHiddenWindowsKeepTheirSlotButTakeNoSpace() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        let f = frames(t, visible: [1, 3])
        XCTAssertNil(f[2])
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(frames(t)[2]?.minX, 333, "the slot is still there when it comes back")
    }

    func testGapsAndMinimumSizes() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        let f = frames(t, gap: 10)
        XCTAssertEqual(f[1]!.maxX + 10, f[2]!.minX)
        XCTAssertEqual(f[2]!.maxX + 10, f[3]!.minX)
        XCTAssertEqual(f[3]!.maxX, 1000)

        let m = frames(t, mins: [1: CGSize(width: 600, height: 0)])
        XCTAssertEqual(m[1]!.width, 600)
        XCTAssertEqual(m[3]!.width, 200)
        XCTAssertEqual(m[2]!.width, 200)
    }

    func testMinimumSizesThatDoNotFitAreScaled() {
        XCTAssertEqual(distribute(total: 100, weights: [1, 1], mins: [80, 80]), [50, 50])
        XCTAssertEqual(distribute(total: 100, weights: [1, 3], mins: [0, 0]), [25, 75])
    }

    func testNearestPrefersOverlapThenDistance() {
        let frames: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 500, height: 600),
            2: CGRect(x: 500, y: 0, width: 500, height: 300),
            3: CGRect(x: 500, y: 300, width: 500, height: 300),
        ]
        XCTAssertEqual(nearestWindow(from: frames[1]!, direction: .right, among: frames, excluding: 1), 2)
        XCTAssertEqual(nearestWindow(from: frames[3]!, direction: .left, among: frames, excluding: 3), 1)
        XCTAssertEqual(nearestWindow(from: frames[2]!, direction: .down, among: frames, excluding: 2), 3)
        XCTAssertNil(nearestWindow(from: frames[1]!, direction: .left, among: frames, excluding: 1))
        XCTAssertNil(nearestWindow(from: frames[2]!, direction: .up, among: frames, excluding: 2))
    }
}
