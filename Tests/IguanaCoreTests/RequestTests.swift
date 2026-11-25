import XCTest
@testable import IguanaCore

/// `--window ID` on the command line: where it can go, what it names, and which commands take it.
final class RequestTests: XCTestCase {
    func testTheFlagCanGoAnywhereInTheLine() throws {
        let expected = Request(command: .move(.left), window: 1187)
        for line in ["move left --window 1187", "--window 1187 move left", "move --window 1187 left", "MOVE LEFT --WINDOW 1187",
                     "  move\tleft   --Window  1187 "] {
            XCTAssertEqual(try Command.parseRequest(line), expected, line)
        }
        XCTAssertEqual(try Command.parseRequest("move-to-space 2 --stay --window 40"),
                       Request(command: .moveToSpace(.index(2), follow: false), window: 40))
        XCTAssertEqual(try Command.parseRequest("move-to-space --window 40 next"), Request(command: .moveToSpace(.next, follow: true), window: 40))
        XCTAssertEqual(try Command.parseRequest("resize --window 7 grow width"), Request(command: .resize(axis: .horizontal, grow: 1), window: 7))
    }

    func testWithoutTheFlagTheFocusedWindowIsMeant() throws {
        XCTAssertEqual(try Command.parseRequest("close"), Request(command: .close))
        XCTAssertNil(try Command.parseRequest("move left").window)
        XCTAssertEqual(try Command.parseRequest("tree --json"), Request(command: .tree, json: true))
    }

    func testTheIdIsADecimalNumber() {
        let message = "--window needs a window id (see iguana list-windows)"
        for bad in ["close --window", "--window close", "close --window abc", "close --window 12abc", "close --window -3",
                    "close --window +3", "close --window 0x1f", "close --window 1.5", "close --window 99999999999", "zoom --window --json"] {
            XCTAssertThrowsError(try Command.parseRequest(bad), bad) { error in
                XCTAssertEqual((error as? CommandError)?.description, message, bad)
            }
        }
        XCTAssertThrowsError(try Command.parseRequest("close --window 1 --window 2"), "one window at a time")
        XCTAssertThrowsError(try Command.parseRequest("--window 5"), "a window and no command")
    }

    func testItDoesNotGoWithJSON() {
        for line in ["list-windows --json --window 5", "close --window 5 --json", "--json --window 5 tree"] {
            XCTAssertThrowsError(try Command.parseRequest(line), line) { error in
                XCTAssertEqual((error as? CommandError)?.description, "use --json or --window, not both", line)
            }
        }
    }

    func testTheCommandsThatActOnAWindowTakeIt() throws {
        for line in ["move up", "join down", "resize shrink", "flip", "stack", "balance", "float", "zoom", "close",
                     "move-to-space 3", "move-to-space prev --stay"] {
            let request = try Command.parseRequest("\(line) --window 12")
            XCTAssertEqual(request.window, 12, line)
            XCTAssertEqual(request.command, try Command.parse(line), line)
            XCTAssertTrue(request.command.acceptsWindow, line)
        }
    }

    func testEveryOtherCommandRefusesIt() {
        for line in ["space 2", "pause", "reload", "list-windows", "list-spaces", "tree", "status", "settings", "tour", "update", "quit"] {
            let name = String(line.split(separator: " ")[0])
            XCTAssertThrowsError(try Command.parseRequest("\(line) --window 12"), line) { error in
                XCTAssertEqual((error as? CommandError)?.description, "'\(name)' does not take --window", line)
            }
            XCTAssertFalse(try Command.parse(line).acceptsWindow, line)
        }
        // A command that is wrong on its own stays wrong, and says why.
        XCTAssertThrowsError(try Command.parseRequest("flip now --window 12")) { error in
            XCTAssertEqual((error as? CommandError)?.description, "'flip' takes no arguments")
        }
    }

    func testFocusWithAWindowFocusesThatWindow() throws {
        XCTAssertEqual(try Command.parseRequest("focus --window 1203"), Request(command: .focusWindow, window: 1203))
        XCTAssertEqual(try Command.parseRequest("--window 1203 Focus"), Request(command: .focusWindow, window: 1203))
        XCTAssertTrue(Command.focusWindow.acceptsWindow)
        // A direction and a window cannot both say where the focus goes.
        for line in ["focus left --window 1203", "focus --window 1203 up"] {
            XCTAssertThrowsError(try Command.parseRequest(line), line) { error in
                XCTAssertEqual((error as? CommandError)?.description, "'focus --window ID' takes no direction: it focuses that window", line)
            }
        }
        XCTAssertFalse(Command.focus(.left).acceptsWindow)
        // Without a window, `focus` still needs a direction.
        XCTAssertThrowsError(try Command.parseRequest("focus"))
        XCTAssertEqual(try Command.parseRequest("focus right"), Request(command: .focus(.right)))
        XCTAssertTrue(Command.usage.contains("\nfocus --window ID "))
    }

    func testAShortcutNeverNamesAWindow() throws {
        XCTAssertThrowsError(try Command.parse("close --window 12"))
        XCTAssertThrowsError(try Command.parse("focus --window 12"))
        XCTAssertThrowsError(try Command.parse("focus"))
        let (config, warnings) = try Config.load("[bindings]\noption-x = \"close --window 12\"\n")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(config.bindings.contains { $0.commandText.contains("--window") })
    }
}
