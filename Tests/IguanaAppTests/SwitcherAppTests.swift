import AppKit
import XCTest
import IguanaCore
@testable import iguana

/// The window switcher's list as the panel works it, and how the panel is set up. The panel is
/// never put on screen here.
final class SwitcherAppTests: XCTestCase {
    let windows = [
        Switcher.Window(id: 1, app: "Safari", title: "Start Page", desktop: 1),
        Switcher.Window(id: 2, app: "Notes", title: "Shopping", desktop: 1),
        Switcher.Window(id: 3, app: "Terminal", title: "zsh", desktop: 1, focused: true),
    ]

    func testTheArrowsGoRoundTheList() {
        let model = SwitcherModel()
        model.load(windows, icons: [:])
        XCTAssertEqual(model.selection, 0, "the first row is the window before the focused one")
        model.move(-1)
        XCTAssertEqual(model.selection, 2, "up from the first row is the last")
        model.move(1)
        XCTAssertEqual(model.selection, 0, "down from the last row is the first")
        model.move(1)
        model.move(1)
        XCTAssertEqual(model.selection, 2)
    }

    func testTypingFiltersAndStartsFromTheTop() {
        let model = SwitcherModel()
        var resized = 0
        model.onResize = { resized += 1 }
        model.load(windows, icons: [:])
        model.move(1)
        model.query = "s"
        XCTAssertEqual(model.matches.map(\.window.id), [1, 2, 3])
        XCTAssertEqual(model.selection, 0)
        model.query = "sh"
        XCTAssertEqual(model.matches.map(\.window.id), [2, 3])
        XCTAssertEqual(resized, 3, "the panel follows every change of the list")

        model.query = "nothing like it"
        XCTAssertEqual(model.matches, [])
        model.move(1)
        XCTAssertEqual(model.selection, 0)

        // Opened again, it starts afresh.
        model.load(windows, icons: [:])
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.matches.count, 3)
    }

    func testReturnPicksTheSelectedRow() {
        let model = SwitcherModel()
        var chosen: [WindowID] = []
        model.onChoose = { chosen.append($0) }
        model.load(windows, icons: [:])
        model.choose()
        model.move(1)
        model.choose()
        model.choose(2)
        model.query = "nothing like it"
        model.choose()
        XCTAssertEqual(chosen, [1, 2, 3], "nothing is chosen from an empty list")
    }

    func testDesktopsAreShownOnlyWhenThereAreSeveral() {
        let model = SwitcherModel()
        model.load(windows, icons: [:])
        XCTAssertFalse(model.showsDesktops)
        model.load(windows + [Switcher.Window(id: 4, app: "Mail", title: "Inbox", desktop: 2, visibility: .elsewhere)], icons: [:])
        XCTAssertTrue(model.showsDesktops)
    }

    func testThePanelTakesTheKeyboardWithoutActivatingIguana() throws {
        let switcher = SwitcherController()
        let window = switcher.window
        XCTAssertTrue(window.canBecomeKey, "it takes the keyboard")
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel), "the app in front stays in front")
        XCTAssertFalse(window.hidesOnDeactivate, "Iguana is hardly ever the app in front")
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace), "on the desktop being shown")
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary), "over a fullscreen app too")
        XCTAssertTrue(window.collectionBehavior.contains(.transient), "not a window to Mission Control")
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle), "not in the window cycle")
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertFalse(window.isVisible, "making one puts nothing on screen")
        XCTAssertFalse(switcher.isShowing)

        // The field it hands the keyboard to is there once the panel is laid out.
        window.contentView?.layoutSubtreeIfNeeded()
        func field(in view: NSView) -> NSView? {
            view is SwitcherSearchField ? view : view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        XCTAssertNotNil(field(in: try XCTUnwrap(window.contentView)))
    }

    func testTheHeightFollowsTheRowsUpToTen() {
        XCTAssertEqual(SwitcherView.height(rows: 0), SwitcherView.height(rows: 1), "room to say that nothing matches")
        XCTAssertEqual(SwitcherView.height(rows: 3) - SwitcherView.height(rows: 2), SwitcherView.rowHeight + 2)
        XCTAssertEqual(SwitcherView.height(rows: 25), SwitcherView.height(rows: 10), "beyond ten rows the list scrolls")
    }

    func testTheTourRefusesTheSwitcher() {
        let tour = TourModel(config: .default)
        tour.play = { _ in }
        tour.after = { _, _ in }
        XCTAssertEqual(tour.handle(.switcher), "ok: in the welcome tour")
    }
}
