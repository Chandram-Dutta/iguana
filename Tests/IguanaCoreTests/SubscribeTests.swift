import XCTest
@testable import IguanaCore

/// `iguana subscribe`: what it asks for, and the line of JSON each event becomes.
final class SubscribeTests: XCTestCase {
    func object(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) as? [String: Any])
    }

    func testAFocusEventIsOneLineWithTheKeysSorted() {
        let variables = HookEnvironment.variables(event: .focusChanged, desktop: 2, display: "Built-in Retina Display",
                                                  window: (1234, "Safari", "Apple"))
        XCTAssertEqual(EventStream.line(variables),
                       #"{"app":"Safari","desktop":2,"display":"Built-in Retina Display","event":"focus-changed","title":"Apple","window-id":1234}"#)
    }

    func testWhatIsNotKnownIsNull() throws {
        // No window has the focus, on a fullscreen Space.
        let focus = EventStream.line(HookEnvironment.variables(event: .focusChanged, desktop: nil, display: "Studio Display"))
        XCTAssertEqual(focus, #"{"app":null,"desktop":null,"display":"Studio Display","event":"focus-changed","title":null,"window-id":null}"#)
        XCTAssertTrue(try object(focus)["window-id"] is NSNull)

        let desktop = EventStream.line(HookEnvironment.variables(event: .desktopChanged, desktop: 3, display: "Studio Display"))
        XCTAssertEqual(desktop, #"{"desktop":3,"display":"Studio Display","event":"desktop-changed"}"#, "no window keys for a desktop")
    }

    func testEveryVariableBecomesAKeyWithoutBeingNamedHere() {
        // A variable the hooks gain later reaches the stream as it is.
        XCTAssertEqual(EventStream.key("IGUANA_WINDOW_ID"), "window-id")
        XCTAssertEqual(EventStream.key("IGUANA_PAUSED"), "paused")
        XCTAssertEqual(EventStream.key("IGUANA_EVENT"), "event")
        XCTAssertEqual(EventStream.line(["IGUANA_PAUSED": "true", "IGUANA_EVENT": "pause-changed", "IGUANA_SOME_COUNT": "0"]),
                       #"{"event":"pause-changed","paused":true,"some-count":0}"#)
        XCTAssertEqual(EventStream.line([:]), "{}")
    }

    func testTheTypeIsReadOffTheText() {
        XCTAssertEqual(EventStream.value("2"), "2")
        XCTAssertEqual(EventStream.value("0"), "0")
        XCTAssertEqual(EventStream.value("4294967295"), "4294967295")
        XCTAssertEqual(EventStream.value("true"), "true")
        XCTAssertEqual(EventStream.value("false"), "false")
        XCTAssertEqual(EventStream.value(""), "null")
        // Not numbers JSON can carry as they are, and not booleans.
        XCTAssertEqual(EventStream.value("007"), #""007""#, "JSON has no leading zeros")
        XCTAssertEqual(EventStream.value("12345678901234567890"), #""12345678901234567890""#, "more than a double holds exactly")
        XCTAssertEqual(EventStream.value("-1"), #""-1""#)
        XCTAssertEqual(EventStream.value("1.5"), #""1.5""#)
        XCTAssertEqual(EventStream.value("2 "), #""2 ""#)
        XCTAssertEqual(EventStream.value("١٢"), #""١٢""#, "only the digits 0 to 9")
        XCTAssertEqual(EventStream.value("True"), #""True""#)
        XCTAssertEqual(EventStream.value("null"), #""null""#)
    }

    func testAnyTitleStaysOneLineAndReadsBackAsItWas() throws {
        let titles = [
            #"He said "hi" \ left"#,
            "two\nlines\r\nand a\ttab",
            "bell \u{7} escape \u{1B} nul \u{0} unit \u{1F} delete \u{7F}",
            "separators \u{2028} and \u{2029}",
            "🦎 Iguana — café, 日本語, 👩🏽‍💻",
            "</script><b>",
        ]
        for title in titles {
            let line = EventStream.line(["IGUANA_TITLE": title])
            XCTAssertFalse(line.contains("\n") || line.contains("\r") || line.contains("\u{2028}"), line)
            XCTAssertFalse(line.unicodeScalars.contains { $0.value < 0x20 }, "no control character left as it is: \(line)")
            XCTAssertEqual(try object(line)["title"] as? String, title)
        }
        XCTAssertEqual(EventStream.quoted("a\"b\\c\nd\u{1}"), #""a\"b\\c\nd\u0001""#)
        XCTAssertEqual(EventStream.quoted("🦎"), "\"🦎\"", "emoji are written as they are")
    }

    func testNoEventsNamedMeansEveryEvent() throws {
        XCTAssertEqual(try Command.parse("subscribe"), .subscribe(Set(HookEvent.allCases)))
        XCTAssertEqual(try Command.parse("subscribe focus-changed"), .subscribe([.focusChanged]))
        XCTAssertEqual(try Command.parse(" Subscribe  DESKTOP-CHANGED focus-changed desktop-changed "), .subscribe([.desktopChanged, .focusChanged]))
        XCTAssertEqual(try Command.parseRequest("subscribe desktop-changed").command, .subscribe([.desktopChanged]))
        XCTAssertTrue(Command.usage.contains("subscribe [event ...]"))
    }

    func testAnUnknownEventNamesTheOnesThereAre() {
        XCTAssertThrowsError(try Command.parse("subscribe window-moved")) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("'window-moved'"), message)
            for event in HookEvent.allCases { XCTAssertTrue(message.contains(event.rawValue), message) }
        }
        // It is always JSON, so there is no --json to ask for.
        XCTAssertThrowsError(try Command.parseRequest("subscribe --json"))
        XCTAssertThrowsError(try Command.parse("subscribe focus-changed, desktop-changed"))
    }
}
