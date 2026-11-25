import XCTest
@testable import IguanaCore

/// The window switcher: the order of its rows, and which windows what is typed finds.
final class SwitcherTests: XCTestCase {
    typealias Window = Switcher.Window

    let start = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func ids(_ matches: [Switcher.Match]) -> [WindowID] { matches.map(\.window.id) }
    func ids(_ windows: [Window]) -> [WindowID] { windows.map(\.id) }

    func testTheCommandAndItsShortcut() throws {
        XCTAssertEqual(try Command.parse("switcher"), .switcher)
        XCTAssertThrowsError(try Command.parse("switcher safari"), "what to look for is typed into it, not given")
        XCTAssertTrue(Config.default.bindings.contains { $0.source == "option-w" && $0.command == .switcher })
    }

    // MARK: Order

    func testMostRecentlyFocusedFirstAndTheFocusedWindowLast() {
        let windows = [
            Window(id: 1, app: "Terminal", title: "zsh", lastFocused: at(10)),
            Window(id: 2, app: "Safari", title: "Start Page", focused: true, lastFocused: at(30)),
            Window(id: 3, app: "Notes", title: "Shopping", lastFocused: at(20)),
            Window(id: 4, app: "Mail", title: "Inbox"),
            Window(id: 5, app: "Music", title: "Music"),
        ]
        // Open and pick the first row, and you are back on the window you were on before.
        XCTAssertEqual(ids(Switcher.ordered(windows)), [3, 1, 4, 5, 2],
                       "never focused windows keep the order they came in, after the others")
    }

    func testEqualTimesKeepTheOrderTheyCameIn() {
        let windows = [Window(id: 7, app: "A", title: "", lastFocused: at(5)), Window(id: 3, app: "B", title: "", lastFocused: at(5))]
        XCTAssertEqual(ids(Switcher.ordered(windows)), [7, 3])
    }

    func testAnEmptyQueryKeepsTheOrderOfRecency() {
        let windows = Switcher.ordered([
            Window(id: 1, app: "Terminal", title: "zsh", lastFocused: at(10)),
            Window(id: 2, app: "Safari", title: "Start Page", focused: true, lastFocused: at(30)),
            Window(id: 3, app: "Notes", title: "Shopping", lastFocused: at(20)),
        ])
        for query in ["", "  "] {
            let matches = Switcher.filter(windows, query: query)
            XCTAssertEqual(ids(matches), [3, 1, 2], "'\(query)'")
            XCTAssertTrue(matches.allSatisfy { $0.appHits.isEmpty && $0.titleHits.isEmpty }, "nothing to highlight")
        }
    }

    // MARK: Ranking

    func testAppNamePrefixBeatsWordStartsBeatsLettersAnywhere() {
        // In the order of recency the best match comes last, and the worst first.
        let windows = [
            Window(id: 1, app: "Preview", title: "Paradox Club"),   // d, o, c in order, the d inside a word
            Window(id: 2, app: "Pages", title: "Old docs"),         // a word starts with it
            Window(id: 3, app: "Xcode", title: "Ideas"),            // no o after the d
            Window(id: 4, app: "Docker", title: "Containers"),      // the app name starts with it
        ]
        let matches = Switcher.filter(windows, query: "doc")
        XCTAssertEqual(ids(matches), [4, 2, 1])
        XCTAssertEqual(matches.map(\.rank), [.appPrefix, .wordStarts, .subsequence])
    }

    func testRanks() {
        func rank(_ app: String, _ title: String, _ query: String) -> Switcher.Rank? {
            Switcher.match(Window(id: 1, app: app, title: title), query: query)?.rank
        }
        XCTAssertEqual(rank("Safari", "GitHub", "saf"), .appPrefix)
        XCTAssertEqual(rank("Safari", "GitHub", "SAF"), .appPrefix, "case does not matter")
        XCTAssertEqual(rank("Google Chrome", "Docs", "google chr"), .appPrefix, "spaces in the app name and the query")
        XCTAssertEqual(rank("Google Chrome", "Docs", "googlechr"), .appPrefix)
        XCTAssertEqual(rank("Safari", "GitHub", "safari git"), .wordStarts, "beyond the app name, into the title")
        XCTAssertEqual(rank("Visual Studio Code", "main.swift", "vsc"), .wordStarts, "initials")
        XCTAssertEqual(rank("Visual Studio Code", "main.swift", "visco"), .wordStarts, "the starts of words")
        XCTAssertEqual(rank("Safari", "GitHub", "hub"), .wordStarts, "a capital inside a word starts one")
        XCTAssertEqual(rank("Mail", "Inbox – iCloud", "cloud"), .wordStarts)
        XCTAssertEqual(rank("Mail", "Inbox – iCloud", "loud"), .subsequence)
        XCTAssertEqual(rank("Mail", "Inbox – iCloud", "inbox"), .wordStarts)
        XCTAssertEqual(rank("Terminal", "zsh", "sh"), .subsequence)
        XCTAssertEqual(rank("Notes", "Café", "cafe"), .wordStarts, "accents do not matter")
        XCTAssertNil(rank("Terminal", "zsh", "hz"), "letters out of order")
        XCTAssertNil(rank("Terminal", "zsh", "terminalx"))
    }

    func testTiesGoToTheMostRecent() {
        let windows = Switcher.ordered([
            Window(id: 1, app: "Terminal", title: "build", lastFocused: at(10)),
            Window(id: 2, app: "Terminal", title: "logs", lastFocused: at(40)),
            Window(id: 3, app: "TextEdit", title: "notes", lastFocused: at(20)),
            Window(id: 4, app: "Terminal", title: "zsh", focused: true, lastFocused: at(50)),
        ])
        XCTAssertEqual(ids(Switcher.filter(windows, query: "te")), [2, 3, 1, 4], "all four start with it")
        XCTAssertEqual(ids(Switcher.filter(windows, query: "term")), [2, 1, 4])
    }

    func testNoMatches() {
        let windows = [Window(id: 1, app: "Terminal", title: "zsh"), Window(id: 2, app: "Safari", title: "Start Page")]
        XCTAssertEqual(Switcher.filter(windows, query: "qqq"), [])
        XCTAssertEqual(Switcher.filter([], query: "a"), [])
        XCTAssertEqual(Switcher.filter([], query: ""), [])
    }

    // MARK: What is highlighted

    func testTheMatchedCharacters() throws {
        let safari = Window(id: 1, app: "Safari", title: "GitHub Home")
        let prefix = try XCTUnwrap(Switcher.match(safari, query: "saf"))
        XCTAssertEqual(prefix.appHits, [0, 1, 2])
        XCTAssertEqual(prefix.titleHits, [])

        let words = try XCTUnwrap(Switcher.match(safari, query: "sa gh"))
        XCTAssertEqual(words.appHits, [0, 1])
        XCTAssertEqual(words.titleHits, [0, 3], "the G of Git and the H of Hub")

        let whole = try XCTUnwrap(Switcher.match(safari, query: "home"))
        XCTAssertEqual(whole.titleHits, [7, 8, 9, 10], "a word typed out is highlighted whole")

        let anywhere = try XCTUnwrap(Switcher.match(Window(id: 2, app: "Terminal", title: "zsh"), query: "lsh"))
        XCTAssertEqual(anywhere.rank, .subsequence)
        XCTAssertEqual(anywhere.appHits, [7])
        XCTAssertEqual(anywhere.titleHits, [1, 2])
    }

    func testAnUntitledWindow() throws {
        let m = try XCTUnwrap(Switcher.match(Window(id: 1, app: "Finder", title: ""), query: "fin"))
        XCTAssertEqual(m.rank, .appPrefix)
        XCTAssertEqual(m.titleHits, [])
    }
}
