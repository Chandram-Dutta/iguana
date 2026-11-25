import XCTest
import IguanaCore
@testable import iguana

/// `[[display]]` has no pane in the settings window. What the window must do is leave it alone.
final class DisplaySettingsFileTests: XCTestCase {
    func testTheSettingsWindowKeepsDisplaySections() throws {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        let displays = """
        # The monitor on the desk.
        [[display]]
        name = "LG ULTRAWIDE"   # part of the name
        inner = 12
        outer = { top = 4, left = 16 }
        max-width = 2560

        [[display]]
        number = 2
        inner = 0
        """
        try ConfigFile.write("[gaps]\ninner = 4\n\n\(displays)\n\n[[rule]]\napp = \"Calculator\"\n", to: backend.configURL)
        backend.reloadConfig()
        let model = SettingsModel(backend: backend)
        var text: String { (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? "" }
        let before = model.config.displays
        XCTAssertEqual(before.count, 2)

        // One of everything the window can write, [gaps] above all, whose keys a [[display]] shares.
        model.setNumber(["gaps", "inner"], 14)
        model.setOuterGap(Edges(all: 20))
        var sides = Edges(all: 20)
        sides.top = 6
        model.setOuterGap(sides)
        model.set(["animation", "enabled"], .bool(false))
        model.set(["menu-bar", "desktops"], .string("all"))
        model.bind("cmd-option-left", to: "focus left", replacing: model.config.bindings.first { $0.source == "option-h" })
        model.unbind(try XCTUnwrap(model.config.bindings.first { $0.source == "option-slash" }))
        model.setRules([Rule(app: "Preview", title: nil), Rule(app: nil, title: "^Inspector")])
        model.setRules([])
        model.setRules([Rule(app: "Notes", title: nil)])
        model.resetShortcuts()

        XCTAssertTrue(text.contains(displays), "the sections are in the file exactly as they were written:\n\(text)")
        var after = before
        after[0].outer?.bottom = 20
        after[0].outer?.right = 20
        XCTAssertEqual(model.config.displays, after, "the sides the display leaves out follow [gaps]")
        XCTAssertEqual(model.problems, [])
        // And the changes themselves took.
        XCTAssertEqual(model.config.gapInner, 14)
        XCTAssertEqual(model.config.gapOuter, sides)
        XCTAssertEqual(model.config.rules, [Rule(app: "Notes", title: nil)])
    }

    /// A file with no [gaps] of its own gets one, and the displays keep theirs.
    func testAGapWrittenToAFileWithOnlyDisplays() throws {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        let displays = "[[display]]\nnumber = 1\ninner = 2\nouter = 3\n"
        try ConfigFile.write(displays, to: backend.configURL)
        backend.reloadConfig()
        let model = SettingsModel(backend: backend)
        model.setNumber(["gaps", "inner"], 14)
        model.setOuterGap(Edges(all: 20))
        let text = (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.hasPrefix(displays), text)
        XCTAssertEqual(model.config.displays, [DisplaySettings(number: 1, inner: 2, outer: Edges(all: 3))])
        XCTAssertEqual(model.config.gapInner, 14)
        XCTAssertEqual(model.config.gapOuter, Edges(all: 20))
        XCTAssertEqual(model.problems, [])
    }

    /// The settings window creates the file from the default one, where `[[display]]` is a
    /// commented-out example. Writing to `[gaps]` keeps it as it was.
    func testTheExampleInANewFileStaysAComment() {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        let model = SettingsModel(backend: backend)
        model.setOuterGap(Edges(all: 12))
        model.setNumber(["gaps", "inner"], 14)
        let text = (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("right = 8 }\n\n# Settings for one display. Name it"), text)
        XCTAssertTrue(text.contains("# [[display]]\n# name = \"LG ULTRAWIDE\"\n"))
        XCTAssertEqual(model.config.displays, [])
        XCTAssertEqual(model.problems, [])
    }
}
