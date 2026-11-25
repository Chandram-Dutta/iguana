import CoreGraphics
import XCTest
@testable import IguanaCore

/// Rules that send an app's windows to a display: reading them, which display a rule means,
/// what is done with a new window, which windows count as new, and `apply-rules`.
final class DisplayRuleTests: XCTestCase {
    func testRulesCanNameADisplay() throws {
        let (c, warnings) = try Config.load("""
        [[rule]]
        app = "com.tinyspeck.slackmacgap"
        display = "Studio Display"

        [[rule]]
        app = "Music"
        float = true
        display = 2

        [[rule]]
        app = "Notes"
        display = 16

        [[rule]]
        app = "Preview"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.rules.map(\.display), [.name("Studio Display"), .number(2), .number(16), nil])
        XCTAssertEqual(c.rules.map(\.float), [nil, true, nil, true], "a rule with only a display says nothing about floating")
        XCTAssertEqual(c.rules.map(\.floats), [false, true, false, true])
        XCTAssertEqual(c.rules[0], Rule(app: "com.tinyspeck.slackmacgap", title: nil, display: .name("Studio Display")))
        XCTAssertNil(c.rules[0].desktop)
        XCTAssertEqual(Rule(app: "Preview", title: nil), Rule(app: "Preview", title: nil, float: true), "a rule with no key of its own still floats")
    }

    func testADisplayThatCannotBeUsedIsLeftOut() throws {
        for bad in ["0", "17", "-2", "2.5", "\"\"", "\"   \"", "true", "[2]", "{ name = \"Studio\" }"] {
            let (c, warnings) = try Config.load("""
            [[rule]]
            app = "Slack"
            display = \(bad)

            [[rule]]
            app = "Music"
            float = true
            display = \(bad)
            """)
            XCTAssertEqual(c.rules.map(\.display), [nil, nil], "display = \(bad)")
            // Kept, and still not floating: without the display the rule does the rest of what it says.
            XCTAssertEqual(c.rules.map(\.floats), [false, true], "display = \(bad)")
            XCTAssertEqual(warnings, [
                "rule 1: display must be part of a display's name or a number from 1 to 16; keeping the rule without it",
                "rule 2: display must be part of a display's name or a number from 1 to 16; keeping the rule without it",
            ], "display = \(bad)")
        }
        XCTAssertEqual(DisplayRef.numbers, Rule.desktopNumbers, "displays are numbered as far as desktops are")
    }

    func testWithADesktopTheDesktopDecides() throws {
        let (c, warnings) = try Config.load("""
        [[rule]]
        app = "Slack"
        desktop = 3
        display = "Studio"

        [[rule]]
        app = "Mail"
        desktop = 2
        display = 40
        """)
        XCTAssertEqual(c.rules, [Rule(app: "Slack", title: nil, desktop: 3), Rule(app: "Mail", title: nil, desktop: 2)])
        XCTAssertEqual(warnings, ["rule 1: desktop and display both given; desktop decides", "rule 2: desktop and display both given; desktop decides"])

        // A rule that is skipped for its desktop gets that one warning only.
        let (skipped, why) = try Config.load("[[rule]]\napp = \"Slack\"\ndesktop = 30\ndisplay = 2\n")
        XCTAssertEqual(skipped.rules, [])
        XCTAssertEqual(why, ["rule 1: desktop must be a whole number from 1 to 16; skipping this rule"])
    }

    func testTheFirstMatchingRuleDecidesTheDisplay() throws {
        let (c, _) = try Config.load("""
        [[rule]]
        app = "Slack"
        title = "Huddle"
        float = true

        [[rule]]
        app = "Slack"
        display = 2
        """)
        XCTAssertNil(c.rule(bundleID: nil, appName: "Slack", title: "Huddle with Ada")?.display, "the rule above answers for it")
        XCTAssertEqual(c.rule(bundleID: nil, appName: "Slack", title: "general")?.display, .number(2))
    }

    func testTheSchemaDescribesARulesDisplay() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let rule = try XCTUnwrap(((schema["properties"] as? [String: Any])?["rule"] as? [String: Any])?["items"] as? [String: Any])
        let display = try XCTUnwrap((rule["properties"] as? [String: Any])?["display"] as? [String: Any])
        let forms = try XCTUnwrap(display["oneOf"] as? [[String: Any]])
        XCTAssertEqual(forms.map { $0["type"] as? String }, ["string", "integer"])
        XCTAssertEqual(forms[0]["minLength"] as? Int, 1)
        XCTAssertEqual(forms[1]["minimum"] as? Int, DisplayRef.numbers.lowerBound)
        XCTAssertEqual(forms[1]["maximum"] as? Int, DisplayRef.numbers.upperBound)
    }

    // MARK: Which display a rule means

    /// From the left: the built-in display, a Studio Display above a second one of the same
    /// kind, and a Dell. Given in another order, as the system may list them.
    private let names = ["Studio Display (2)", "DELL U2720Q", "Built-in Retina Display", "Studio Display (1)"]
    private let frames = [
        CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        CGRect(x: 4072, y: 0, width: 2560, height: 1440),
        CGRect(x: 0, y: 200, width: 1512, height: 982),
        CGRect(x: 1512, y: -1440, width: 2560, height: 1440),
    ]

    func testANameIsPartOfTheDisplaysName() {
        func find(_ name: String) -> Int? { DisplayRef.name(name).resolve(names: names, frames: frames) }
        XCTAssertEqual(find("dell"), 1, "case is ignored")
        XCTAssertEqual(find("Built-in"), 2)
        XCTAssertEqual(find("  u2720q "), 1, "spaces around the name are not part of it")
        XCTAssertEqual(find("Studio Display (2)"), 0)
        XCTAssertEqual(find("studio"), 3, "of two that match, the first in display order: the upper one")
        XCTAssertEqual(find("Display"), 2, "the built-in display is display 1")
        XCTAssertNil(find("LG"))
        XCTAssertNil(DisplayRef.name("Studio").resolve(names: [], frames: []), "no displays at all")

        // A name that is a whole display's name means that display, even where another contains it.
        XCTAssertEqual(DisplayRef.name("lg").resolve(names: ["LG UltraFine", "LG"], frames: [.init(x: 0, y: 0, width: 10, height: 10), .init(x: 10, y: 0, width: 10, height: 10)]), 1)
    }

    func testANumberCountsFromTheLeft() {
        func find(_ n: Int) -> Int? { DisplayRef.number(n).resolve(names: names, frames: frames) }
        XCTAssertEqual(DisplayOrder.numbers(frames), [3, 4, 1, 2], "the order rules use is DisplayOrder's")
        XCTAssertEqual(find(1), 2)
        XCTAssertEqual(find(2), 3, "the upper of two displays with the same left edge comes first")
        XCTAssertEqual(find(3), 0)
        XCTAssertEqual(find(4), 1)
        XCTAssertNil(find(5))
        XCTAssertNil(find(0))
    }

    func testWhatADisplayRuleDoesToANewWindow() {
        func decide(_ wanted: DisplayRef?, standard: Bool = true, on: Int? = 2) -> DisplayRuleAction {
            .decide(wanted: wanted, standardWindow: standard, windowDisplay: on, names: names, frames: frames)
        }
        XCTAssertEqual(decide(.number(2)), .send(3))
        XCTAssertEqual(decide(.name("dell")), .send(1))
        XCTAssertEqual(decide(nil), .leave, "the rule names no display")
        XCTAssertEqual(decide(.number(1)), .leave, "already there")
        XCTAssertEqual(decide(.name("built-in")), .leave, "already there")
        XCTAssertEqual(decide(.number(1), on: nil), .send(2), "a window whose display is not known is sent")
        XCTAssertEqual(decide(.number(2), standard: false), .leave, "dialogs and sheets stay with their app")
        XCTAssertEqual(decide(.number(5)), .missing)
        XCTAssertEqual(decide(.name("Sidecar")), .missing)
        XCTAssertEqual(decide(.name("Sidecar"), standard: false), .leave)
    }

    func testTheConfigFileSpellingOfADisplay() throws {
        XCTAssertEqual(DisplayRef(.string("Studio")), .name("Studio"))
        XCTAssertEqual(DisplayRef(.int(3)), .number(3))
        XCTAssertNil(DisplayRef(.double(3)))
        for ref in [DisplayRef.name("Studio \"2\""), .number(3)] {
            XCTAssertEqual(DisplayRef(ref.toml), ref)
            let (c, warnings) = try Config.load("[[rule]]\napp = \"Slack\"\ndisplay = \(TOMLEditor.format(ref.toml))\n")
            XCTAssertEqual(c.rules.first?.display, ref)
            XCTAssertEqual(warnings, [])
        }
    }

    // MARK: Which windows are new

    private let start = Date(timeIntervalSince1970: 1_000)
    private func entry(_ window: WindowID, _ display: DisplayRef, rule: Int = 1) -> DisplayRuleQueue.Entry {
        DisplayRuleQueue.Entry(window: window, display: display, rule: rule, app: "Slack")
    }

    func testWindowsThatWereOpenBeforeIguanaAreNeverSent() {
        var queue = DisplayRuleQueue()
        queue.note(7, display: .number(2), rule: 1, app: "Slack", at: start)
        queue.firstLook(existing: [7, 8, 9])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "before the first look nothing counts as new")
        queue.note(9, display: .number(2), rule: 1, app: "Slack", at: start.addingTimeInterval(60))
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(60), paused: false) { _ in true }, [], "open all along, on another desktop")
        queue.note(12, display: .name("Studio"), rule: 2, app: "Slack", at: start.addingTimeInterval(61))
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(61), paused: false) { _ in true }, [entry(12, .name("Studio"), rule: 2)])
    }

    func testANewWindowIsSentOnce() {
        var queue = DisplayRuleQueue()
        queue.firstLook(existing: [])
        queue.note(13, display: .number(1), rule: 1, app: "Slack", at: start)
        queue.note(12, display: .number(2), rule: 1, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [entry(12, .number(2)), entry(13, .number(1))])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "the user may move it now, and it stays where they put it")
    }

    func testReadingTheConfigAgainMovesNothing() {
        var queue = DisplayRuleQueue()
        queue.firstLook(existing: [1])
        queue.note(12, display: .number(2), rule: 1, app: "Slack", at: start)
        queue.markExisting([1, 12, 14])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
        queue.note(14, display: .number(2), rule: 1, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
        queue.note(15, display: .number(2), rule: 1, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [entry(15, .number(2))], "windows that open afterwards are sent")
    }

    func testAWindowGetsAMomentToBecomeAStandardWindow() {
        var queue = DisplayRuleQueue()
        queue.firstLook(existing: [])
        queue.note(12, display: .number(2), rule: 1, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in false }, [], "not a standard window yet")
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(0.5), paused: false) { _ in true }, [entry(12, .number(2))], "it settled")

        queue.note(20, display: .number(2), rule: 1, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(1), paused: false) { _ in false }, [])
        let late = start.addingTimeInterval(DesktopRuleQueue.patience + 0.1)
        XCTAssertEqual(queue.due(at: late, paused: false) { _ in true }, [], "the same patience as for desktops")

        queue.note(30, display: .number(2), rule: 1, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in nil }, [], "closed, or a tab of another window")
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
    }

    func testNothingIsSentWhileTilingIsPaused() {
        var queue = DisplayRuleQueue()
        queue.firstLook(existing: [])
        queue.note(12, display: .number(2), rule: 1, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: true) { _ in true }, [])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "and it does not jump away when tiling resumes")
    }

    // MARK: apply-rules

    func testApplyRulesIsACommand() throws {
        XCTAssertEqual(try Command.parse("apply-rules"), .applyRules)
        XCTAssertEqual(try Command.parse("APPLY-RULES"), .applyRules)
        XCTAssertThrowsError(try Command.parse("apply-rules now"))
        XCTAssertThrowsError(try Command.parseRequest("apply-rules --json"), "it answers with one line")
        XCTAssertTrue(Command.usage.contains("\napply-rules "))
        let (c, warnings) = try Config.load("[bindings]\noption-shift-r = \"apply-rules\"\n")
        XCTAssertEqual(warnings, [])
        XCTAssertTrue(c.bindings.contains { $0.command == .applyRules })
    }
}
