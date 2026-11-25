import AppKit
import XCTest
@testable import iguana

/// The icons kept for the menu and the switcher, with the system's answers played by the test.
final class AppIconsTests: XCTestCase {
    var asked: [pid_t] = []
    var known: [pid_t: NSImage] = [:]
    var icons: AppIcons!

    override func setUp() {
        asked = []
        known = [10: NSImage(size: NSSize(width: 1, height: 1)), 20: NSImage(size: NSSize(width: 2, height: 2))]
        icons = AppIcons { [unowned self] pid in
            asked.append(pid)
            return known[pid]
        }
    }

    func testEachWindowGetsTheIconOfItsApp() {
        let found = icons.icons(for: [1: 10, 2: 10, 3: 20])
        XCTAssertTrue(found[1] === known[10])
        XCTAssertTrue(found[2] === known[10])
        XCTAssertTrue(found[3] === known[20])
        XCTAssertEqual(asked.sorted(), [10, 20], "an app is asked for once, however many windows it has")
    }

    func testAnIconIsAskedForOnce() {
        _ = icons.icons(for: [1: 10])
        _ = icons.icons(for: [1: 10, 4: 10])
        XCTAssertEqual(asked, [10])
    }

    func testAnAppWithoutAnIconIsLeftOutAndAskedAgain() {
        XCTAssertTrue(icons.icons(for: [1: 30]).isEmpty)
        known[30] = NSImage(size: NSSize(width: 3, height: 3))
        XCTAssertTrue(icons.icons(for: [1: 30])[1] === known[30])
        XCTAssertEqual(asked, [30, 30])
    }

    func testAnAppThatQuitIsForgotten() {
        _ = icons.icons(for: [1: 10])
        // The pid now belongs to another app.
        let other = NSImage(size: NSSize(width: 9, height: 9))
        known[10] = other
        XCTAssertFalse(icons.icons(for: [1: 10])[1] === other, "still the icon it knew")
        icons.forget(10)
        XCTAssertTrue(icons.icons(for: [1: 10])[1] === other)
    }
}
