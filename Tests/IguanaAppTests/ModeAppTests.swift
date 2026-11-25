import IguanaCore
import XCTest
@testable import iguana

/// Modes and chains where they meet the app: the settings window, the menu bar and the tour.
final class ModeAppTests: XCTestCase {
    static let modes = """
    [bindings]
    option-r = "mode resize"
    option-shift-r = "flip; balance"

    [mode.resize]
    h = "resize shrink width"   # narrower
    l = "resize grow width"
    return = "mode default"

    [mode.move]
    h = "move left"

    """

    func testTheShortcutsPaneLeavesModesAsTheyAre() throws {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        try ConfigFile.write(Self.modes, to: backend.configURL)
        backend.reloadConfig()
        let model = SettingsModel(backend: backend)
        let modes = model.config.modes
        XCTAssertEqual(modes.keys.sorted(), ["move", "resize"])
        func text() -> String { (try? String(contentsOf: backend.configURL, encoding: .utf8)) ?? "" }
        // Everything from the first mode on.
        func tables() -> String { text().components(separatedBy: "[mode.resize]").last ?? "" }
        let before = tables()

        // A shortcut changed, added, switched off, and every one restored.
        let h = try XCTUnwrap(model.config.bindings.first { $0.source == "option-h" })
        model.bind("cmd-option-left", to: "focus left", replacing: h)
        model.bind("option-h", to: "mode move", replacing: nil)
        model.unbind(try XCTUnwrap(model.config.bindings.first { $0.source == "option-shift-r" }))
        XCTAssertEqual(model.config.bindings.first { $0.source == "option-h" }?.command, .mode("move"))
        XCTAssertEqual(tables(), before, "[mode.*] is not touched")
        XCTAssertEqual(model.config.modes, modes)
        XCTAssertFalse(text().contains("option-shift-r"))
        XCTAssertEqual(model.problems, [])

        model.resetShortcuts()
        XCTAssertEqual(tables(), before)
        XCTAssertTrue(text().contains("[mode.resize]\nh = \"resize shrink width\"   # narrower\n"))
        XCTAssertEqual(model.config.modes, modes)
        XCTAssertEqual(model.config.bindings, Config.default.bindings)
    }

    func testTheMenuBarShowsTheModeBesideTheDesktop() {
        XCTAssertEqual(StatusIcon.label(desktop: "2", mode: "default"), "2")
        XCTAssertEqual(StatusIcon.label(desktop: "2", mode: "resize"), "2 · resize")
        XCTAssertEqual(StatusIcon.label(desktop: "", mode: "resize"), "resize", "on a fullscreen Space")
        XCTAssertEqual(StatusIcon.label(desktop: "", mode: "default"), "")
        let plain = StatusIcon.image(.paused, label: "2").size
        let moded = StatusIcon.image(.paused, label: StatusIcon.label(desktop: "2", mode: "resize")).size
        XCTAssertGreaterThan(moded.width, plain.width)
        XCTAssertEqual(moded.height, plain.height, "the drawing keeps its height")
    }

    func testTheTourNeverTeachesOrRunsAChain() throws {
        let (config, _) = try Config.load("""
        [bindings]
        option-h = "focus left; balance"
        option-s = "stack; mode resize"
        option-r = "mode resize"
        [mode.resize]
        h = "resize shrink width"
        """)
        let model = TourModel(config: config)
        model.after = { _, _ in }
        model.play = { _ in }
        for step in TourStep.allCases {
            for hint in model.keys(for: step)?.keys ?? [] {
                if case .sequence = hint.command { XCTFail("\(step) teaches a chain") }
                if case .mode = hint.command { XCTFail("\(step) teaches a mode") }
            }
        }
        XCTAssertNil(model.keys(for: .focus), "focus left has no shortcut of its own")
        XCTAssertNil(model.keys(for: .stack))

        let refusals = model.refusals
        XCTAssertEqual(model.handle(.sequence([.focus(.left), .balance])), "ok: in the welcome tour")
        XCTAssertEqual(model.handle(.mode("resize")), "ok: in the welcome tour")
        XCTAssertEqual(model.refusals, refusals + 2)
        XCTAssertNil(model.handle(.mode("default")), "the way out of a mode is left to the window manager")
    }
}
