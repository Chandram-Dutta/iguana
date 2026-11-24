import IguanaCore
import XCTest
@testable import iguana

final class StatusIconTests: XCTestCase {
    private func desk(_ number: Int, active: Bool = false, windows: [WindowID] = []) -> StatusIcon.Desk {
        let tree = Tree()
        var last: WindowID?
        for id in windows {
            tree.insert(id, after: last, split: .horizontal)
            last = id
        }
        return StatusIcon.Desk(number: number, isActive: active, layout: tree.snapshot, windows: Set(windows), focused: windows.last)
    }

    func testEveryPointOfTheRowBelongsToOneDesktop() {
        let (image, slots) = StatusIcon.row([desk(1, windows: [1, 2]), desk(2, active: true, windows: [3]), desk(5)])
        XCTAssertEqual(slots.map(\.number), [1, 2, 5])
        XCTAssertTrue(image.isTemplate)
        // A click anywhere on the picture lands on exactly one desktop, with no dead strip between two.
        let drawing = slots.last?.range.upperBound ?? 0
        XCTAssertEqual(image.size.height, StatusIcon.height)
        var x: CGFloat = 0.25
        while x < drawing - 2.5 {
            XCTAssertEqual(slots.filter { $0.range.contains(x) && $0.range.upperBound != x }.count, 1, "at \(x)")
            x += 0.5
        }
        // Left to right, as the desktops are numbered.
        XCTAssertEqual(slots.first { $0.range.contains(2) }?.number, 1)
        XCTAssertEqual(slots.first { $0.range.contains(drawing - 4) }?.number, 5)

        // The number is drawn into the same picture, after the desktops, and belongs to none of them.
        let labelled = StatusIcon.row([desk(1), desk(2, active: true)], label: "2")
        XCTAssertGreaterThan(labelled.image.size.width, StatusIcon.row([desk(1), desk(2, active: true)]).image.size.width)
        XCTAssertNil(labelled.slots.first { $0.range.contains(labelled.image.size.width - 1) })
        XCTAssertEqual(StatusIcon.image(.paused, label: "2").size.height, StatusIcon.height, "every icon has one height, so nothing shifts")
    }

    func testTheRowGrowsWithTheDesktops() {
        let two = StatusIcon.row([desk(1), desk(2)]).image.size.width
        let four = StatusIcon.row([desk(1), desk(2), desk(3), desk(4)]).image.size.width
        XCTAssertGreaterThan(four, two)
        XCTAssertLessThan(four / 4, 26, "a desktop takes about 23 points")
    }
}
