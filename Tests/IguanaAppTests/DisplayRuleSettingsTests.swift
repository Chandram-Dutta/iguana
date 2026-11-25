import CoreGraphics
import XCTest
import IguanaCore
@testable import iguana

/// The display of a rule in the Window Rules pane: what its menu offers, and what saving writes.
final class DisplayRuleSettingsTests: XCTestCase {
    var backend: SettingsModelTests.FakeBackend!
    var model: SettingsModel!

    override func setUp() {
        backend = SettingsModelTests.FakeBackend()
        model = SettingsModel(backend: backend)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent())
    }

    var fileText: String { (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? "" }

    private func write(_ text: String) throws {
        try ConfigFile.write(text, to: backend.configURL)
        backend.reloadConfig()
        model.refresh()
    }

    private let rules = """
    [gaps]
    inner = 8

    [[rule]]
    app = "com.tinyspeck.slackmacgap"
    display = "studio"

    [[rule]]
    app = "Music"
    float = true
    display = 2

    [[rule]]
    app = "Notes"
    desktop = 1

    """

    func testRulesKeepTheirDisplay() throws {
        try write(rules)
        let written = model.config.rules
        XCTAssertEqual(written.map(\.display), [.name("studio"), .number(2), nil])

        // Saved from the window with another rule added, every rule says what it said before.
        model.setRules(written + [Rule(app: "Preview", title: nil)])
        XCTAssertEqual(model.config.rules, written + [Rule(app: "Preview", title: nil)])
        XCTAssertTrue(fileText.contains("app = \"com.tinyspeck.slackmacgap\"\ndisplay = \"studio\"\n"),
                      "a name is written as it was, and a rule with only a display is not given a float key")
        XCTAssertTrue(fileText.contains("app = \"Music\"\nfloat = true\ndisplay = 2\n"))
        XCTAssertEqual(model.problems, [])
    }

    func testChangingADisplayRewritesOnlyThatValue() throws {
        try write(rules)
        let before = fileText.components(separatedBy: "\n")
        var changed = model.config.rules
        changed[1].display = .number(1)
        model.setRules(changed)
        let after = fileText.components(separatedBy: "\n")
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.map { "\($0) -> \($1)" }, ["display = 2 -> display = 1"])

        // Taken away from a rule that says nothing else, the pane writes the rule as tiled.
        changed[0].display = nil
        changed[0].float = false
        model.setRules(changed)
        XCTAssertEqual(model.config.rules[0], Rule(app: "com.tinyspeck.slackmacgap", title: nil, float: false))
        XCTAssertTrue(fileText.contains("app = \"com.tinyspeck.slackmacgap\"\nfloat = false\n"))

        // Given to a rule that had none, it is written as a number.
        changed[2] = Rule(app: "Notes", title: nil, display: .number(3))
        model.setRules(changed)
        XCTAssertEqual(model.config.rules[2].display, .number(3))
        XCTAssertNil(model.config.rules[2].desktop)
        XCTAssertTrue(fileText.contains("app = \"Notes\"\ndisplay = 3\n"))
        XCTAssertEqual(model.problems, [])
    }

    // MARK: The menu

    /// Given in another order than they stand: the built-in display is on the left.
    private let names = ["Studio Display", "Built-in Retina Display"]
    private let frames = [CGRect(x: 1512, y: 0, width: 2560, height: 1440), CGRect(x: 0, y: 200, width: 1512, height: 982)]

    func testTheMenuListsTheConnectedDisplaysByNumber() {
        let menu = DisplayChoice.menu(for: nil, names: names, frames: frames)
        XCTAssertEqual(menu.map(\.display), [.number(1), .number(2)])
        XCTAssertEqual(menu.map(\.title), ["Display 1: Built-in Retina Display", "Display 2: Studio Display"])
        XCTAssertEqual(DisplayChoice.menu(for: .number(2), names: names, frames: frames), menu, "a display that is there is in the list already")
        XCTAssertEqual(DisplayChoice.menu(for: nil, names: [], frames: []), [], "no displays known")
    }

    func testTheMenuKeepsWhatTheRuleSays() {
        // A name is offered as it is written, so the menu shows it and saving keeps it.
        let named = DisplayChoice.menu(for: .name("studio"), names: names, frames: frames)
        XCTAssertEqual(named.map(\.display), [.name("studio"), .number(1), .number(2)])
        XCTAssertEqual(named.first?.title, "“studio”")
        XCTAssertEqual(DisplayChoice.menu(for: .name("Sidecar"), names: names, frames: frames).first?.title, "“Sidecar” (not there now)")

        let away = DisplayChoice.menu(for: .number(4), names: names, frames: frames)
        XCTAssertEqual(away.map(\.display), [.number(1), .number(2), .number(4)])
        XCTAssertEqual(away.last?.title, "Display 4 (not there now)")
    }
}
