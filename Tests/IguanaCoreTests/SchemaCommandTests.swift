import XCTest
@testable import IguanaCore

/// The `[bindings]` schema that editors check a config file against must accept every command
/// a shortcut can hold: anything `Command.parse` takes. A command missing from the oneOf list
/// is flagged in the editor while working perfectly well.
final class SchemaCommandTests: XCTestCase {
    private func alternatives() throws -> [[String: Any]] {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let bindings = try XCTUnwrap((schema["properties"] as? [String: Any])?["bindings"] as? [String: Any])
        let entry = try XCTUnwrap((bindings["patternProperties"] as? [String: Any])?.values.first as? [String: Any])
        return try XCTUnwrap(entry["oneOf"] as? [[String: Any]])
    }

    /// How many of the oneOf alternatives the command satisfies.
    private func accepted(_ command: String, _ choices: [[String: Any]]) throws -> Int {
        try choices.filter { choice in
            if let constant = choice["const"] as? String { return constant == command }
            if let list = choice["enum"] as? [String] { return list.contains(command) }
            guard let pattern = choice["pattern"] as? String else { return false }
            return try NSRegularExpression(pattern: pattern).firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
        }.count
    }

    func testEveryCommandAShortcutCanHoldIsAccepted() throws {
        let choices = try alternatives()
        let commands = [
            "focus left", "focus right", "focus up", "focus down", "focus recent",
            "move left", "join down",
            "resize grow", "resize shrink width", "resize grow height",
            "flip", "stack", "balance",
            "split horizontal", "split vertical", "split auto",
            "arrange columns", "arrange rows", "arrange grid", "arrange main",
            "float", "zoom", "close",
            "focus-app safari", "focus-app visual studio code", "focus-app com.apple.safari",
            "undo", "redo",
            "place center", "place left", "place right", "place top", "place bottom",
            "place top-left", "place top-right", "place bottom-left", "place bottom-right", "place full",
            "space 1", "space 16", "space next", "space prev", "space recent",
            "move-to-space 3", "move-to-space next --stay", "move-to-space --follow prev",
            "focus-display next", "focus-display prev", "focus-display 2", "move-to-display 1",
            "apply-rules", "pause", "reload", "switcher", "settings", "tour", "update",
            "mode resize", "mode default",
            "flip; balance", "move-to-space 2 --stay; balance",
            "quit", "list-windows", "list-spaces", "tree", "status",
        ]
        for command in commands {
            XCTAssertNoThrow(try Command.parse(command), command)
            XCTAssertGreaterThanOrEqual(try accepted(command, choices), 1, command)
        }
    }

    /// A command-line-only command must not look valid inside a shortcut.
    func testSubscribeIsNotAccepted() throws {
        let choices = try alternatives()
        XCTAssertEqual(try accepted("subscribe", choices), 0)
        XCTAssertEqual(try accepted("subscribe desktop-changed", choices), 0)
    }
}
