import AppKit
import XCTest
import IguanaCore
@testable import iguana

/// `focus-follows-mouse` in the app: when it listens to the pointer, and its switch in the
/// settings window. The window manager here has not started, so it watches and moves nothing.
final class FocusFollowsMouseTests: XCTestCase {
    func testNothingListensWhileTheSettingIsOff() {
        let wm = WindowManager()
        let follower = FocusFollowsMouse()
        XCTAssertFalse(wm.config.focusFollowsMouse)
        follower.changed(wm)
        XCTAssertFalse(follower.isListening, "off costs nothing: no event monitor is installed")
        XCTAssertNil(wm.onPointerWarp)

        follower.listen(true, wm)
        XCTAssertTrue(follower.isListening)
        XCTAssertNotNil(wm.onPointerWarp, "it is told when mouse-follows-focus moves the pointer")
        follower.listen(true, wm)
        XCTAssertTrue(follower.isListening)

        // The next refresh finds the setting off again.
        follower.changed(wm)
        XCTAssertFalse(follower.isListening)
        XCTAssertNil(wm.onPointerWarp)
    }

    func testTheSettingsWindowSwitchesItOnBesideItsOpposite() throws {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        let model = SettingsModel(backend: backend)
        model.set(["layout", "focus-follows-mouse"], .bool(true))
        XCTAssertTrue(model.config.focusFollowsMouse)
        XCTAssertFalse(model.config.mouseFollowsFocus)
        XCTAssertEqual(model.problems, [])
        let text = try String(contentsOf: backend.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("mouse-follows-focus = false\nfocus-follows-mouse = true"), "the two lines sit together in [layout]")

        // A file from before the setting existed gets the key added to its [layout].
        try ConfigFile.write("[layout]\nauto-split = false   # rows\n\n[gaps]\ninner = 4\n", to: backend.configURL)
        backend.reloadConfig()
        model.refresh()
        model.set(["layout", "focus-follows-mouse"], .bool(true))
        XCTAssertTrue(model.config.focusFollowsMouse)
        XCTAssertFalse(model.config.autoSplit)
        XCTAssertEqual(model.config.gapInner, 4)
    }
}
