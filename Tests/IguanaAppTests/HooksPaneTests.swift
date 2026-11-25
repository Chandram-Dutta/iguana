import XCTest
import IguanaCore
@testable import iguana

/// The Hooks pane of the settings window: each event's command, written into `[hooks]` one
/// value at a time.
final class HooksPaneTests: XCTestCase {
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

    func start(with text: String) throws {
        try ConfigFile.write(text, to: backend.configURL)
        backend.reloadConfig()
        model.refresh()
    }

    let handWritten = """
    # My setup.
    [gaps]
    inner = 4   # tight

    # For SketchyBar.
    [hooks]
    desktop-changed = "sketchybar --trigger iguana_desktop"   # one trigger per switch
    focus-changed = 'echo "$IGUANA_TITLE" >> "$HOME/focus.log"'

    [[rule]]
    app = "Calculator"

    """

    func testEditingAHookRewritesOnlyThatValue() throws {
        try start(with: handWritten)
        XCTAssertEqual(model.hookCommand(.desktopChanged), "sketchybar --trigger iguana_desktop")
        XCTAssertEqual(model.hookCommand(.layoutChanged), "", "a hook the file leaves out runs nothing")

        model.setHook(.desktopChanged, "sketchybar --trigger iguana_space")
        XCTAssertEqual(fileText, handWritten.replacingOccurrences(of: "iguana_desktop\"", with: "iguana_space\""),
                       "the comment after the value and everything around it stay")
        XCTAssertEqual(model.config.hooks[.desktopChanged], "sketchybar --trigger iguana_space")

        // A key the file does not have yet goes at the end of the section.
        model.setHook(.windowCreated, "  echo \"$IGUANA_APP\" >> ~/opened.log  ")
        XCTAssertTrue(fileText.contains("""
        focus-changed = 'echo "$IGUANA_TITLE" >> "$HOME/focus.log"'
        window-created = "echo \\"$IGUANA_APP\\" >> ~/opened.log"

        [[rule]]
        """), fileText)
        XCTAssertEqual(model.config.hooks[.windowCreated], "echo \"$IGUANA_APP\" >> ~/opened.log", "the spaces around it are not kept")
        XCTAssertEqual(model.config.hooks[.focusChanged], "echo \"$IGUANA_TITLE\" >> \"$HOME/focus.log\"", "the other hook is as it was")
        XCTAssertEqual(model.config.gapInner, 4)
        XCTAssertEqual(model.config.rules.map(\.app), ["Calculator"])
        XCTAssertEqual(model.problems, [])
    }

    func testClearingAHookWritesAnEmptyString() throws {
        try start(with: handWritten)
        model.setHook(.desktopChanged, "")
        XCTAssertTrue(fileText.contains("desktop-changed = \"\"   # one trigger per switch\n"), fileText)
        XCTAssertNil(model.config.hooks[.desktopChanged])
        XCTAssertEqual(model.hookCommand(.desktopChanged), "")

        model.setHook(.focusChanged, "   ")
        XCTAssertTrue(fileText.contains("focus-changed = \"\"\n"), "only spaces is no command:\n\(fileText)")
        XCTAssertEqual(model.config.hooks, [:])
        XCTAssertTrue(fileText.hasPrefix("# My setup.\n[gaps]\ninner = 4   # tight\n\n# For SketchyBar.\n[hooks]\n"))
    }

    func testCommittingWhatTheFileSaysWritesNothing() throws {
        try start(with: handWritten)
        model.setHook(.desktopChanged, "sketchybar --trigger iguana_desktop ")
        model.setHook(.pauseChanged, "")
        XCTAssertEqual(fileText, handWritten, "leaving a field without changing it leaves the file alone")

        let spaced = "[hooks]\nfocus-changed = \"  echo hi \"\n"
        try start(with: spaced)
        model.setHook(.focusChanged, model.hookCommand(.focusChanged))
        XCTAssertEqual(fileText, spaced, "a command written with spaces around it stays as it was")

        // With no file at all, an empty field creates none.
        try FileManager.default.removeItem(at: backend.configURL)
        backend.reloadConfig()
        model.refresh()
        model.setHook(.windowClosed, "")
        XCTAssertFalse(model.fileExists)
    }

    func testTheFirstHookCreatesTheDocumentedFile() {
        model.setHook(.pauseChanged, "say paused")
        XCTAssertTrue(model.fileExists)
        XCTAssertEqual(fileText, Config.defaultText.replacingOccurrences(of: "pause-changed = \"\"", with: "pause-changed = \"say paused\"") + "\n",
                       "the default file, with that one value filled in")
        XCTAssertEqual(model.config.hooks, [.pauseChanged: "say paused"])
    }

    func testThePaneHasEveryEvent() {
        XCTAssertTrue(Pane.allCases.contains(.hooks))
        XCTAssertEqual(Pane.hooks.title, "Hooks")
        for event in HookEvent.allCases {
            model.setHook(event, "true \(event.rawValue)")
            XCTAssertEqual(model.hookCommand(event), "true \(event.rawValue)")
        }
        XCTAssertEqual(model.config.hooks.count, HookEvent.allCases.count)
        XCTAssertEqual(model.problems, [])
    }
}
