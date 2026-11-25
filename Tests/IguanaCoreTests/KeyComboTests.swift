import XCTest
@testable import IguanaCore

/// Shortcuts as text: `option-shift-h`, the other spellings of Option, and what is refused.
final class KeyComboTests: XCTestCase {
    func testOptionIsTheNameOfTheKeyAndTheOldSpellingIsStillRead() throws {
        let option = try KeyCombo.parse("option-shift-h")
        XCTAssertEqual(option.modifiers, [.option, .shift])
        XCTAssertEqual(try KeyCombo.parse("opt-shift-h"), option)
        XCTAssertEqual(try KeyCombo.parse("alt-shift-h"), option, "configs written for other window managers keep working")
        // The built-in shortcuts are written with the name Iguana uses.
        XCTAssertFalse(Config.defaultText.contains("alt-"))
        XCTAssertTrue(Config.default.bindings.allSatisfy { $0.source.hasPrefix("option-") })
    }

    func testKeyCombos() throws {
        XCTAssertEqual(try KeyCombo.parse("option-shift-h"), KeyCombo(modifiers: [.option, .shift], key: "h"))
        XCTAssertEqual(try KeyCombo.parse("Cmd-Option-Left"), KeyCombo(modifiers: [.cmd, .option], key: "left"))
        XCTAssertEqual(try KeyCombo.parse("option--"), KeyCombo(modifiers: [.option], key: "minus"))
        XCTAssertThrowsError(try KeyCombo.parse("h"))
        XCTAssertThrowsError(try KeyCombo.parse("option-"))
        XCTAssertThrowsError(try KeyCombo.parse("meta-h"))
    }
}
