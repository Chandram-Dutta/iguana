import AppKit
import XCTest
@testable import iguana

/// The menu bar the app has for its own windows.
final class MainMenuTests: XCTestCase {
    func testTheMenusAndTheirKeys() {
        let menu = MainMenu().make()
        XCTAssertEqual(menu.items.map(\.title), ["Iguana", "Edit", "Window"])
        func items(_ index: Int) -> [String] {
            menu.items[index].submenu?.items.map { $0.isSeparatorItem ? "-" : "\($0.title) \($0.keyEquivalent)" } ?? []
        }
        XCTAssertEqual(items(0), ["Settings… ,", "-", "Quit Iguana q"])
        XCTAssertEqual(items(1), ["Undo z", "Redo Z", "-", "Cut x", "Copy c", "Paste v", "Select All a"])
        XCTAssertEqual(items(2), ["Close w", "Minimize m"])
    }

    func testSettingsOpensTheSettings() throws {
        let main = MainMenu()
        var opened = 0
        main.onSettings = { opened += 1 }
        let item = try XCTUnwrap(main.make().items.first?.submenu?.items.first)
        XCTAssertTrue(item.target === main)
        _ = item.target?.perform(try XCTUnwrap(item.action))
        XCTAssertEqual(opened, 1)
    }

    func testEverythingElseGoesToWhateverHasTheKeyboard() {
        let main = MainMenu()
        let items = main.make().items.flatMap { $0.submenu?.items ?? [] }
        XCTAssertEqual(items.filter { $0.target != nil }.map(\.title), ["Settings…"])
        XCTAssertEqual(items.filter { $0.target === main }.map(\.title), ["Settings…"])
    }
}
