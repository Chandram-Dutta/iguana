import CoreGraphics
import XCTest
@testable import IguanaCore

final class SplitHintTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func frames(_ t: Tree) -> [WindowID: CGRect] { computeLayout(t, in: screen, gap: 0) }

    func win(_ id: WindowID) -> NodeSnapshot { NodeSnapshot(window: id, orientation: nil, weight: 1, children: nil) }

    func testParse() throws {
        XCTAssertEqual(try Command.parse("split horizontal"), .split(.horizontal))
        XCTAssertEqual(try Command.parse("split Vertical"), .split(.vertical))
        XCTAssertEqual(try Command.parse("SPLIT auto"), .split(nil))
        for bad in ["split", "split left", "split side", "split auto vertical"] {
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
        XCTAssertTrue(Command.usage.contains("split horizontal|vertical|auto"))
    }

    func testVerticalOpensBelowAWideWindow() {
        // Along its longer side a lone window on a wide screen would be split left and right.
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .vertical)
        XCTAssertEqual(frames(t), [1: CGRect(x: 0, y: 0, width: 1000, height: 300), 2: CGRect(x: 0, y: 300, width: 1000, height: 300)])
    }

    func testHorizontalOpensBesideATallWindow() {
        // 2 is taller than it is wide, and would be split top and bottom; side by side it joins the row.
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.insert(3, after: 2, split: .horizontal)
        XCTAssertEqual(t.windows, [1, 2, 3])
        XCTAssertEqual(frames(t)[2], CGRect(x: 333, y: 0, width: 334, height: 600))
        XCTAssertEqual(frames(t)[3], CGRect(x: 667, y: 0, width: 333, height: 600))

        // In a column, the window's own tile is cut in two.
        let c = Tree()
        c.insert(1)
        c.insert(2, after: 1, split: .horizontal)
        c.insert(3, after: 2, split: .vertical)   // 1 | (2 / 3)
        c.insert(4, after: 3, split: .horizontal)
        let f = frames(c)
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 300, width: 250, height: 300))
        XCTAssertEqual(f[4], CGRect(x: 750, y: 300, width: 250, height: 300))
    }

    func testInAStackANewWindowJoinsTheStack() {
        let t = Tree(snapshot: NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: [win(1), win(2)], stacked: true))
        XCTAssertTrue(t.newWindowJoinsStack(beside: 1))
        t.insert(3, after: 1, split: .vertical)
        XCTAssertTrue(t.root.stacked)
        XCTAssertEqual(t.root.orientation, .horizontal)
        XCTAssertEqual(t.windows, [1, 3, 2])

        // A split inside a stack is not a stack: there the hint does cut the window's tile.
        let nested = NodeSnapshot(window: nil, orientation: .vertical, weight: 1, children: [win(2), win(3)])
        let s = Tree(snapshot: NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: [win(1), nested], stacked: true))
        XCTAssertTrue(s.newWindowJoinsStack(beside: 1))
        XCTAssertFalse(s.newWindowJoinsStack(beside: 2))

        let plain = Tree()
        [1, 2].forEach { plain.insert($0) }
        XCTAssertFalse(plain.newWindowJoinsStack(beside: 1))
        XCTAssertFalse(plain.newWindowJoinsStack(beside: 9))
    }
}
