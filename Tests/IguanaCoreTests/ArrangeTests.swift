import CoreGraphics
import XCTest
@testable import IguanaCore

final class ArrangeTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func frames(_ t: Tree, visible: Set<WindowID>? = nil) -> [WindowID: CGRect] {
        computeLayout(t, in: screen, gap: 0, visible: visible)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// A row of these windows, in this order.
    func row(_ ids: [WindowID]) -> Tree {
        let t = Tree()
        ids.forEach { t.insert($0) }
        return t
    }

    func win(_ id: WindowID) -> NodeSnapshot { NodeSnapshot(window: id, orientation: nil, weight: 1, children: nil) }

    /// The tree is in the form `normalize` leaves, holds every window once, and has no stack.
    func assertCanonical(_ t: Tree, file: StaticString = #filePath, line: UInt = #line) {
        let before = t.snapshot
        t.normalize()
        XCTAssertEqual(t.snapshot, before, "not normalized", file: file, line: line)
        XCTAssertEqual(Set(t.windows).count, t.windows.count, "a window twice", file: file, line: line)
        func walk(_ n: Node) {
            XCTAssertFalse(n.stacked, "a stack is left", file: file, line: line)
            for c in n.children {
                XCTAssertTrue(c.parent === n, file: file, line: line)
                walk(c)
            }
        }
        walk(t.root)
    }

    /// Windows 1 to n in a row, arranged in that order, laid out on the screen.
    func arranged(_ a: Arrangement, _ n: Int, main: WindowID? = nil, file: StaticString = #filePath, line: UInt = #line) -> [WindowID: CGRect] {
        let ids = (1...n).map { WindowID($0) }
        let t = row(ids)
        t.arrange(a, order: ids, main: main)
        assertCanonical(t, file: file, line: line)
        XCTAssertEqual(t.windows, ids, file: file, line: line)
        return frames(t)
    }

    func testParse() throws {
        XCTAssertEqual(try Command.parse("arrange columns"), .arrange(.columns))
        XCTAssertEqual(try Command.parse("arrange rows"), .arrange(.rows))
        XCTAssertEqual(try Command.parse("Arrange GRID"), .arrange(.grid))
        XCTAssertEqual(try Command.parse("arrange main"), .arrange(.main))
        for bad in ["arrange", "arrange spiral", "arrange rows columns"] {
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
        XCTAssertTrue(Command.usage.contains("arrange columns|rows|grid|main"))
    }

    func testColumns() {
        XCTAssertEqual(arranged(.columns, 1), [1: rect(0, 0, 1000, 600)])
        XCTAssertEqual(arranged(.columns, 2), [1: rect(0, 0, 500, 600), 2: rect(500, 0, 500, 600)])
        XCTAssertEqual(arranged(.columns, 3), [1: rect(0, 0, 333, 600), 2: rect(333, 0, 334, 600), 3: rect(667, 0, 333, 600)])
        XCTAssertEqual(arranged(.columns, 4), [1: rect(0, 0, 250, 600), 2: rect(250, 0, 250, 600),
                                               3: rect(500, 0, 250, 600), 4: rect(750, 0, 250, 600)])
        XCTAssertEqual(arranged(.columns, 5), [1: rect(0, 0, 200, 600), 2: rect(200, 0, 200, 600), 3: rect(400, 0, 200, 600),
                                               4: rect(600, 0, 200, 600), 5: rect(800, 0, 200, 600)])
    }

    func testRows() {
        XCTAssertEqual(arranged(.rows, 1), [1: rect(0, 0, 1000, 600)])
        XCTAssertEqual(arranged(.rows, 2), [1: rect(0, 0, 1000, 300), 2: rect(0, 300, 1000, 300)])
        XCTAssertEqual(arranged(.rows, 3), [1: rect(0, 0, 1000, 200), 2: rect(0, 200, 1000, 200), 3: rect(0, 400, 1000, 200)])
        XCTAssertEqual(arranged(.rows, 4), [1: rect(0, 0, 1000, 150), 2: rect(0, 150, 1000, 150),
                                            3: rect(0, 300, 1000, 150), 4: rect(0, 450, 1000, 150)])
        XCTAssertEqual(arranged(.rows, 5), [1: rect(0, 0, 1000, 120), 2: rect(0, 120, 1000, 120), 3: rect(0, 240, 1000, 120),
                                            4: rect(0, 360, 1000, 120), 5: rect(0, 480, 1000, 120)])
    }

    func testGrid() {
        XCTAssertEqual(arranged(.grid, 1), [1: rect(0, 0, 1000, 600)])
        XCTAssertEqual(arranged(.grid, 2), [1: rect(0, 0, 500, 600), 2: rect(500, 0, 500, 600)])
        // Two columns; the last row has one window, as wide as the row.
        XCTAssertEqual(arranged(.grid, 3), [1: rect(0, 0, 500, 300), 2: rect(500, 0, 500, 300), 3: rect(0, 300, 1000, 300)])
        XCTAssertEqual(arranged(.grid, 4), [1: rect(0, 0, 500, 300), 2: rect(500, 0, 500, 300),
                                            3: rect(0, 300, 500, 300), 4: rect(500, 300, 500, 300)])
        // Three columns; the last row has two wider windows.
        XCTAssertEqual(arranged(.grid, 5), [1: rect(0, 0, 333, 300), 2: rect(333, 0, 334, 300), 3: rect(667, 0, 333, 300),
                                            4: rect(0, 300, 500, 300), 5: rect(500, 300, 500, 300)])
    }

    func testMain() {
        XCTAssertEqual(arranged(.main, 1), [1: rect(0, 0, 1000, 600)])
        XCTAssertEqual(arranged(.main, 2), [1: rect(0, 0, 600, 600), 2: rect(600, 0, 400, 600)])
        XCTAssertEqual(arranged(.main, 3), [1: rect(0, 0, 600, 600), 2: rect(600, 0, 400, 300), 3: rect(600, 300, 400, 300)])
        XCTAssertEqual(arranged(.main, 4), [1: rect(0, 0, 600, 600), 2: rect(600, 0, 400, 200),
                                            3: rect(600, 200, 400, 200), 4: rect(600, 400, 400, 200)])
        XCTAssertEqual(arranged(.main, 5), [1: rect(0, 0, 600, 600), 2: rect(600, 0, 400, 150), 3: rect(600, 150, 400, 150),
                                            4: rect(600, 300, 400, 150), 5: rect(600, 450, 400, 150)])
    }

    func testMainTakesTheFocusedWindowOutOfReadingOrder() {
        let t = row([1, 2, 3])
        t.focused = 3
        t.arrange(.main, order: [1, 2, 3], main: 3)
        assertCanonical(t)
        XCTAssertEqual(t.windows, [3, 1, 2])
        XCTAssertEqual(frames(t), [3: rect(0, 0, 600, 600), 1: rect(600, 0, 400, 300), 2: rect(600, 300, 400, 300)])
        XCTAssertEqual(t.focused, 3, "the focused window stays focused")
    }

    func testOrderComesFromWhatIsOnScreen() {
        // 3 | (1 / 2): read from the screen, the order is 3, 1, 2.
        let t = Tree()
        t.insert(3)
        t.insert(1, after: 3, split: .horizontal)
        t.insert(2, after: 1, split: .vertical)
        let order = readingOrder(frames(t))
        XCTAssertEqual(order, [3, 1, 2])
        t.arrange(.rows, order: order)
        XCTAssertEqual(frames(t), [3: rect(0, 0, 1000, 200), 1: rect(0, 200, 1000, 200), 2: rect(0, 400, 1000, 200)])
    }

    func testHiddenWindowsKeepAPlaceAndTakeNoRoom() {
        // Window 4 is minimised. It was first in the tree; it comes back at the end.
        let t = row([4, 1, 2, 3])
        t.arrange(.columns, order: [1, 2, 3], hidden: [4])
        assertCanonical(t)
        XCTAssertEqual(t.windows, [1, 2, 3, 4])
        XCTAssertEqual(frames(t, visible: [1, 2, 3]), [1: rect(0, 0, 333, 600), 2: rect(333, 0, 334, 600), 3: rect(667, 0, 333, 600)])
        XCTAssertEqual(frames(t)[4], rect(750, 0, 250, 600))

        // In a grid it joins the last row.
        let grid = row([1, 2, 3, 4])
        grid.arrange(.grid, order: [1, 2, 3], hidden: [4])
        assertCanonical(grid)
        XCTAssertEqual(frames(grid, visible: [1, 2, 3]), [1: rect(0, 0, 500, 300), 2: rect(500, 0, 500, 300), 3: rect(0, 300, 1000, 300)])
        XCTAssertEqual(frames(grid)[3], rect(0, 300, 500, 300))
        XCTAssertEqual(frames(grid)[4], rect(500, 300, 500, 300))

        // Beside the main window it joins the column of the others, even when there are none yet.
        let main = row([1, 2, 3])
        main.arrange(.main, order: [1], main: 1, hidden: [2, 3])
        assertCanonical(main)
        XCTAssertEqual(frames(main, visible: [1]), [1: rect(0, 0, 1000, 600)])
        XCTAssertEqual(frames(main, visible: [1, 3]), [1: rect(0, 0, 600, 600), 3: rect(600, 0, 400, 600)])
        XCTAssertEqual(frames(main)[3], rect(600, 300, 400, 300))
    }

    func testEveryWindowIsKeptAndNoneAdded() {
        let t = row([1, 2, 3])
        t.arrange(.columns, order: [2, 9, 2])
        assertCanonical(t)
        XCTAssertEqual(t.windows, [2, 1, 3], "left out of both lists, 1 and 3 still have a place; 9 was never in the tree")
    }

    func testStacksAreDissolved() {
        // 1 | stack of 2 and 3.
        let stacked = NodeSnapshot(window: nil, orientation: .vertical, weight: 1, children: [win(2), win(3)], stacked: true)
        let t = Tree(snapshot: NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: [win(1), stacked]))
        t.arrange(.rows, order: [1, 2, 3])
        assertCanonical(t)
        XCTAssertEqual(frames(t), [1: rect(0, 0, 1000, 200), 2: rect(0, 200, 1000, 200), 3: rect(0, 400, 1000, 200)])

        // A stack that fills the screen.
        let whole = Tree(snapshot: NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: [win(1), win(2)], stacked: true))
        whole.arrange(.columns, order: [1, 2])
        assertCanonical(whole)
        XCTAssertEqual(frames(whole), [1: rect(0, 0, 500, 600), 2: rect(500, 0, 500, 600)])
    }

    func testReadingOrderTreatsSlightlyMisalignedTopsAsOneRow() {
        let order = readingOrder([
            5: rect(0, 3, 500, 300), 2: rect(500, 0, 500, 296),
            9: rect(0, 305, 500, 295), 1: rect(500, 298, 500, 302),
        ])
        XCTAssertEqual(order, [5, 2, 9, 1])
        // A window as tall as two rows comes before the ones beside it.
        XCTAssertEqual(readingOrder([7: rect(500, 300, 500, 300), 8: rect(500, 0, 500, 300), 6: rect(0, 0, 500, 600)]), [6, 8, 7])
        XCTAssertEqual(readingOrder([:]), [])
    }
}
