import XCTest
import IguanaCore
@testable import iguana

/// The Window Rules pane has no controls for a rule's `size` and `position`. When it rewrites
/// the rules, it must still write them back as the file had them.
final class FloatRuleFileTests: XCTestCase {
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

    /// The rows the pane shows for the rules in the file.
    var rows: [FloatingPane.RuleRow] { model.config.rules.map(FloatingPane.RuleRow.init) }

    /// What the pane does when a row changes: every row with an app or a title becomes a rule.
    func save(_ rows: [FloatingPane.RuleRow]) { model.setRules(rows.compactMap(\.rule)) }

    func testEditingTheRulesKeepsSizeAndPosition() throws {
        try ConfigFile.write("""
        [[rule]]
        app = "com.apple.calculator"
        float = true
        size = [400, 600]
        position = "center"

        [[rule]]
        app = "Preview"
        size = [800.5, 600]

        [[rule]]
        app = "Notes"
        float = true
        position = "bottom-right"

        """, to: backend.configURL)
        backend.reloadConfig()
        model.refresh()
        XCTAssertEqual(rows.compactMap(\.rule), model.config.rules, "a rule comes back from its row unchanged")

        // A title for one rule, a desktop for another, a new app, and a row still being typed.
        var edited = rows
        edited[0].title = "^Calculator$"
        edited[1].desktop = 2
        edited.append(FloatingPane.RuleRow(app: "Music", title: ""))
        edited.append(FloatingPane.RuleRow(app: " ", title: "", isDraft: true))
        save(edited)

        XCTAssertEqual(model.config.rules.map(\.app), ["com.apple.calculator", "Preview", "Notes", "Music"])
        XCTAssertEqual(model.config.rules.map(\.size), [CGSize(width: 400, height: 600), CGSize(width: 800.5, height: 600), nil, nil])
        XCTAssertEqual(model.config.rules.map(\.position), [.center, nil, .bottomRight, nil])
        XCTAssertTrue(fileText.contains("""
        app = "com.apple.calculator"
        title = "^Calculator$"
        float = true
        size = [400, 600]
        position = "center"

        """), fileText)
        XCTAssertTrue(fileText.contains("app = \"Preview\"\nfloat = true\ndesktop = 2\nsize = [800.5, 600]\n"), fileText)
        XCTAssertEqual(model.problems, [])
    }

    func testSwitchingFloatOffAndOnAgainKeepsThem() {
        let calculator = Rule(app: "com.apple.calculator", title: nil, float: true, size: CGSize(width: 400, height: 600), position: .center)
        model.setRules([calculator])

        var edited = rows
        edited[0].float = false
        save(edited)
        XCTAssertEqual(model.problems, ["rule 1: size and position are only for windows the rule floats, so they have no effect here"])
        XCTAssertTrue(fileText.contains("size = [400, 600]\nposition = \"center\"\n"), "a tiled rule keeps them in the file, where they do nothing")

        // The pane reads the rules again after every change, and the switch goes back on.
        edited = rows
        edited[0].float = true
        save(edited)
        XCTAssertEqual(model.config.rules, [calculator])
        XCTAssertEqual(model.problems, [])
    }
}
