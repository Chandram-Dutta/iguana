import XCTest
@testable import IguanaCore

/// Several commands from one shortcut or one command line: `flip; balance`.
final class ChainTests: XCTestCase {
    private func error(_ text: String) -> String? {
        do {
            _ = try Command.parse(text)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func testAChainIsSplitAtEachSemicolon() throws {
        XCTAssertEqual(try Command.parse("flip; balance"), .sequence([.flip, .balance]))
        XCTAssertEqual(try Command.parse("  Focus LEFT ;move right;resize grow width  "),
                       .sequence([.focus(.left), .move(.right), .resize(axis: .horizontal, grow: 1)]))
        XCTAssertEqual(try Command.parse("flip;balance;flip"), .sequence([.flip, .balance, .flip]), "the same command twice is fine")
    }

    func testEmptyPartsAreLeftOutAndOnePartIsJustThatCommand() throws {
        XCTAssertEqual(try Command.parse("flip; balance;"), .sequence([.flip, .balance]), "a trailing ; does no harm")
        XCTAssertEqual(try Command.parse("; flip ;; balance ; "), .sequence([.flip, .balance]))
        XCTAssertEqual(try Command.parse("flip;"), .flip, "never a chain of one")
        XCTAssertEqual(try Command.parse(" ; zoom"), .zoom)
        for empty in [";", " ; ; ", ";;"] {
            XCTAssertEqual(error(empty), "empty command", empty)
        }
    }

    func testAMistakeInOnePartIsTheErrorOfTheWhole() {
        XCTAssertEqual(error("flip; focus north"), "'focus' needs one of: left, right, up, down, recent")
        XCTAssertEqual(error("explode; flip"), "unknown command 'explode'")
    }

    func testReportsQuitAndJSONCannotBeChained() {
        for name in ["list-windows", "list-spaces", "tree", "status", "quit", "subscribe"] {
            XCTAssertEqual(error("flip; \(name)"), "'\(name)' cannot be part of a chain")
            XCTAssertEqual(error("\(name.uppercased()); flip"), "'\(name)' cannot be part of a chain", "first or last")
        }
        XCTAssertEqual(error("flip; tree --json"), "'--json' cannot be used in a chain")
        // The command line takes --json off before parsing; a chain keeps it, and says no.
        XCTAssertThrowsError(try Command.parseRequest("flip; balance --json")) {
            XCTAssertEqual("\($0)", "'--json' cannot be used in a chain")
        }
        XCTAssertThrowsError(try Command.parseRequest("status --json; flip"))
        XCTAssertEqual(try Command.parseRequest("flip; balance").command, .sequence([.flip, .balance]))
        XCTAssertFalse(try Command.parseRequest("flip; balance").json)
        // The others can be part of one.
        XCTAssertEqual(try Command.parse("reload; pause; settings; tour; update; mode default").sequenceCount, 6)
    }

    func testSwitchingDesktopsComesLast() throws {
        XCTAssertEqual(try Command.parse("balance; space 2"), .sequence([.balance, .space(.index(2))]))
        XCTAssertEqual(try Command.parse("float; move-to-space next --stay"), .sequence([.float, .moveToSpace(.next, follow: false)]))
        XCTAssertEqual(error("space 2; balance"), "'space' must come last in a chain")
        XCTAssertEqual(error("move-to-space 3; focus left"), "'move-to-space' must come last in a chain")
        XCTAssertEqual(error("space next; space prev"), "'space' must come last in a chain")
        XCTAssertEqual(try Command.parse("space 2;"), .space(.index(2)), "alone, with a trailing ;")
    }

    func testAChainRunsInOrderAndStopsAtTheFirstError() {
        var ran: [Command] = []
        func run(_ replies: [(Command, String)]) -> (Command) -> String {
            { command in
                ran.append(command)
                return replies.first { $0.0 == command }?.1 ?? "ok"
            }
        }
        XCTAssertEqual(Command.runChain([.flip, .balance, .zoom], run([(.balance, "ok: nothing to do")])), "ok")
        XCTAssertEqual(ran, [.flip, .balance, .zoom], "every command, in order")

        ran = []
        XCTAssertEqual(Command.runChain([.flip, .balance, .zoom], run([(.zoom, "ok: nothing in that direction")])), "ok: nothing in that direction",
                       "the last command answers")
        ran = []
        XCTAssertEqual(Command.runChain([.flip, .balance, .zoom], run([(.balance, "error: the focused window is not tiled")])),
                       "error: the focused window is not tiled")
        XCTAssertEqual(ran, [.flip, .balance], "nothing runs after an error")
    }

    func testAShortcutCanRunAChain() throws {
        let (c, warnings) = try Config.load("[bindings]\noption-shift-r = \"flip; balance\"\noption-x = \"flip; status\"\n")
        let chain = try XCTUnwrap(c.bindings.first { $0.source == "option-shift-r" })
        XCTAssertEqual(chain.command, .sequence([.flip, .balance]))
        XCTAssertEqual(chain.commandText, "flip; balance")
        XCTAssertEqual(warnings, ["binding 'option-x': 'status' cannot be part of a chain"])
        XCTAssertTrue(Command.usage.contains("COMMAND; COMMAND"))
    }
}

private extension Command {
    var sequenceCount: Int {
        if case .sequence(let commands) = self { return commands.count }
        return 1
    }
}
