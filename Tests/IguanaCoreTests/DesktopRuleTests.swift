import XCTest
@testable import IguanaCore

/// Rules that send an app's windows to a desktop: reading them, which rule decides, what is
/// done with a new window, and which windows count as new.
final class DesktopRuleTests: XCTestCase {
    func testRulesCanNameADesktop() throws {
        let (c, warnings) = try Config.load("""
        [[rule]]
        app = "com.tinyspeck.slackmacgap"
        desktop = 3

        [[rule]]
        app = "Music"
        float = true
        desktop = 16

        [[rule]]
        app = "Notes"
        float = false
        desktop = 1

        [[rule]]
        app = "Preview"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.rules.map(\.desktop), [3, 16, 1, nil])
        XCTAssertEqual(c.rules.map(\.float), [nil, true, false, true], "only a rule with a desktop can say nothing about floating")
        XCTAssertEqual(c.rules.map(\.floats), [false, true, false, true])
        XCTAssertEqual(c.rules[0], Rule(app: "com.tinyspeck.slackmacgap", title: nil, desktop: 3))
        XCTAssertEqual(c.rules[3], Rule(app: "Preview", title: nil), "a rule with neither key floats, as before")
        XCTAssertEqual(Config.default.rules.map(\.float), [true, true, true])
        XCTAssertEqual(Config.default.rules.map(\.desktop), [nil, nil, nil])

        // The numbers a rule takes are the ones the commands take.
        XCTAssertNoThrow(try Command.parse("move-to-space \(Rule.desktopNumbers.upperBound)"))
        XCTAssertThrowsError(try Command.parse("move-to-space \(Rule.desktopNumbers.upperBound + 1)"))
        XCTAssertThrowsError(try Command.parse("move-to-space \(Rule.desktopNumbers.lowerBound - 1)"))
    }

    func testARuleWithABadDesktopIsSkipped() throws {
        for bad in ["0", "17", "-2", "2.5", "\"3\"", "true", "[3]"] {
            let (c, warnings) = try Config.load("""
            [[rule]]
            app = "Slack"
            float = true
            desktop = \(bad)

            [[rule]]
            app = "Mail"
            desktop = 2
            """)
            XCTAssertEqual(c.rules, [Rule(app: "Mail", title: nil, desktop: 2)], "desktop = \(bad)")
            XCTAssertEqual(warnings, ["rule 1: desktop must be a whole number from 1 to 16; skipping this rule"], "desktop = \(bad)")
        }
    }

    func testTheFirstMatchingRuleDecidesFloatingAndDesktopTogether() throws {
        let (c, _) = try Config.load("""
        [[rule]]
        app = "Slack"
        title = "Huddle"
        float = true

        [[rule]]
        app = "Slack"
        desktop = 3

        [[rule]]
        title = "^Preferences$"
        float = true

        [[rule]]
        app = "Slack"
        float = true
        desktop = 5
        """)
        func rule(_ app: String, _ title: String) -> Rule? { c.rule(bundleID: nil, appName: app, title: title) }
        // The rule above answers for both things, so the huddle floats and is sent nowhere.
        XCTAssertEqual(rule("Slack", "Huddle with Ada")?.floats, true)
        XCTAssertNil(rule("Slack", "Huddle with Ada")?.desktop)
        // A rule with only a desktop does not float its windows, and the rules below it are not asked.
        XCTAssertEqual(rule("Slack", "general")?.floats, false)
        XCTAssertEqual(rule("Slack", "general")?.desktop, 3)
        XCTAssertEqual(rule("Slack", "Preferences")?.floats, false)
        XCTAssertEqual(rule("Slack", "Preferences")?.desktop, 3)
        XCTAssertEqual(rule("Mail", "Preferences")?.floats, true)
        XCTAssertNil(rule("Mail", "Preferences")?.desktop)
        XCTAssertNil(rule("Mail", "Inbox"), "no rule matches, so the window is tiled and stays")
        XCTAssertNil(Config.default.rule(bundleID: "com.apple.calculator", appName: "Calculator", title: nil)?.desktop)
    }

    func testWhatADesktopRuleDoesToANewWindow() {
        func decide(_ wanted: Int?, standard: Bool = true, on: [Int] = [1], of count: Int = 4, canStay: Bool = true) -> DesktopRuleAction {
            .decide(wanted: wanted, standardWindow: standard, windowDesktops: on, desktopCount: count, canStay: canStay)
        }
        XCTAssertEqual(decide(3), .send(3))
        XCTAssertEqual(decide(nil), .leave, "the rule names no desktop")
        XCTAssertEqual(decide(1), .leave, "already there")
        XCTAssertEqual(decide(3, on: [1, 2, 3, 4]), .leave, "a window on every desktop is on that one too")
        XCTAssertEqual(decide(3, on: []), .send(3), "a window whose desktop is not known yet is sent")
        XCTAssertEqual(decide(3, standard: false), .leave, "dialogs and sheets are not sent anywhere")
        XCTAssertEqual(decide(5), .missing)
        XCTAssertEqual(decide(4), .send(4))
        XCTAssertEqual(decide(1, of: 0), .missing, "no desktops known")
        // Where a window can only be carried to a desktop, the rule does nothing rather than take the user along.
        XCTAssertEqual(decide(3, canStay: false), .cannotStay)
        XCTAssertEqual(decide(1, canStay: false), .leave, "nothing to say about a window that is where it belongs")
        XCTAssertEqual(decide(5, canStay: false), .missing)
        XCTAssertEqual(decide(3, standard: false, canStay: false), .leave)
    }

    func testTheSchemaDescribesARulesDesktop() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let rule = try XCTUnwrap(((schema["properties"] as? [String: Any])?["rule"] as? [String: Any])?["items"] as? [String: Any])
        let keys = try XCTUnwrap(rule["properties"] as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["app", "title", "float", "desktop", "display"])
        let desktop = try XCTUnwrap(keys["desktop"] as? [String: Any])
        XCTAssertEqual(desktop["type"] as? String, "integer")
        XCTAssertEqual(desktop["minimum"] as? Int, Rule.desktopNumbers.lowerBound)
        XCTAssertEqual(desktop["maximum"] as? Int, Rule.desktopNumbers.upperBound)
    }

    // MARK: Which windows are new

    private let start = Date(timeIntervalSince1970: 1_000)
    private func entry(_ window: WindowID, _ desktop: Int) -> DesktopRuleQueue.Entry {
        DesktopRuleQueue.Entry(window: window, desktop: desktop, app: "Slack")
    }

    func testWindowsThatWereOpenBeforeIguanaAreNeverSent() {
        var queue = DesktopRuleQueue()
        // Before the first look nothing counts as new, whatever is reported.
        queue.note(7, desktop: 3, app: "Slack", at: start)
        queue.firstLook(existing: [7, 8, 9])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
        // Window 9 was on another desktop and only comes into view now. It was open all along.
        queue.note(9, desktop: 3, app: "Slack", at: start.addingTimeInterval(60))
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(60), paused: false) { _ in true }, [])
        // A window that opens later is new.
        queue.note(12, desktop: 3, app: "Slack", at: start.addingTimeInterval(61))
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(61), paused: false) { _ in true }, [entry(12, 3)])
    }

    func testANewWindowIsSentOnce() {
        var queue = DesktopRuleQueue()
        queue.firstLook(existing: [])
        queue.note(12, desktop: 3, app: "Slack", at: start)
        queue.note(13, desktop: 2, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [entry(12, 3), entry(13, 2)])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "the user may move it now, and it stays where they put it")
        var asked = 0
        _ = queue.due(at: start, paused: false) { _ in
            asked += 1
            return true
        }
        XCTAssertEqual(asked, 0, "with nothing waiting, no window is asked about")
    }

    func testReadingTheConfigAgainMovesNothing() {
        var queue = DesktopRuleQueue()
        queue.firstLook(existing: [1])
        queue.note(12, desktop: 3, app: "Slack", at: start)
        // The config is read while window 12 waits, and window 14 is open somewhere out of sight.
        queue.markExisting([1, 12, 14])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
        queue.note(14, desktop: 3, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
        queue.note(15, desktop: 3, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [entry(15, 3)], "windows that open afterwards are sent")
    }

    func testAWindowGetsAMomentToBecomeAStandardWindow() {
        var queue = DesktopRuleQueue()
        queue.firstLook(existing: [])
        queue.note(12, desktop: 3, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in false }, [], "not a standard window yet")
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(0.5), paused: false) { _ in true }, [entry(12, 3)], "it settled")

        // A dialog never becomes one. Once patience is over it is not sent even if it changes.
        queue.note(20, desktop: 3, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start.addingTimeInterval(1), paused: false) { _ in false }, [])
        let late = start.addingTimeInterval(DesktopRuleQueue.patience + 0.1)
        XCTAssertEqual(queue.due(at: late, paused: false) { _ in true }, [])
        XCTAssertEqual(queue.due(at: late, paused: false) { _ in true }, [])

        // A window that closed, or that is a tab of another window, is dropped at once.
        queue.note(30, desktop: 3, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in nil }, [])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [])
    }

    func testNothingIsSentWhileTilingIsPaused() {
        var queue = DesktopRuleQueue()
        queue.firstLook(existing: [])
        queue.note(12, desktop: 3, app: "Slack", at: start)
        XCTAssertEqual(queue.due(at: start, paused: true) { _ in true }, [])
        XCTAssertEqual(queue.due(at: start, paused: false) { _ in true }, [], "and it does not jump away when tiling resumes")
    }
}
