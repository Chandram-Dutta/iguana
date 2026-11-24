import AppKit
import XCTest
import IguanaCore
@testable import iguana

/// The overlay the focus ring is drawn with, and its group in the settings window. The overlay
/// is never put on screen here: these tests only look at how it is set up.
final class FocusRingAppTests: XCTestCase {
    func testTheOverlayStaysOutOfTheWayOfEveryOtherWindow() {
        let window = OutlineOverlay().window
        XCTAssertTrue(window.ignoresMouseEvents, "every click goes through it")
        XCTAssertFalse(window.canBecomeKey, "it never takes the keyboard")
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.isOpaque)
        XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.level, .normal, "among ordinary windows, so that it can go directly above one of them")
        XCTAssertFalse(window.hidesOnDeactivate, "Iguana is hardly ever the app in front")
        XCTAssertTrue(window.collectionBehavior.contains(.transient), "not a window to Mission Control")
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle), "not in the window cycle")
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces), "it belongs to the desktop of the window it surrounds")
        XCTAssertFalse(window.isVisible, "making one puts nothing on screen")
    }

    func testTheOverlayCoversTheLineAndNothingMore() throws {
        let primary = try XCTUnwrap(NSScreen.screens.first?.frame.height, "needs a display")
        let overlay = OutlineOverlay()
        let outline = Outline(rect: CGRect(x: 100, y: 200, width: 800, height: 600), lineWidth: 3, cornerRadius: 16)
        overlay.draw(outline, color: .controlAccentColor)
        XCTAssertEqual(overlay.window.frame, CGRect(x: 97, y: primary - 803, width: 806, height: 606))
        XCTAssertFalse(overlay.isShown, "drawing does not put it on screen")
        XCTAssertFalse(overlay.window.isVisible)
        // The line is the border of the window's one layer; its outer edge is rounder than the
        // window it surrounds by the width of the line.
        let layer = try XCTUnwrap(overlay.window.contentView?.layer)
        XCTAssertEqual(layer.borderWidth, 3)
        XCTAssertEqual(layer.cornerRadius, 19)
        overlay.window.displayIfNeeded()
        XCTAssertNotNil(layer.borderColor, "the colour is worked out when the window is drawn")
        XCTAssertNil(layer.backgroundColor, "an outline, not a filled shape")

        // The line may run past the edge of the screen, as a window may.
        let offScreen = Outline(rect: CGRect(x: -400, y: -300, width: 800, height: 600), lineWidth: 10, cornerRadius: 16)
        overlay.draw(offScreen, color: .red)
        XCTAssertEqual(overlay.window.frame, CGRect(x: -410, y: primary - 310, width: 820, height: 620))
    }

    func testAColourFromTheFileIsTheColourDrawn() throws {
        let colour = try XCTUnwrap(RingColor(text: "#8fd43f80")?.nsColor.usingColorSpace(.sRGB))
        XCTAssertEqual(colour.redComponent, 0x8f / 255.0, accuracy: 0.001)
        XCTAssertEqual(colour.greenComponent, 0xd4 / 255.0, accuracy: 0.001)
        XCTAssertEqual(colour.blueComponent, 0x3f / 255.0, accuracy: 0.001)
        XCTAssertEqual(colour.alphaComponent, 0x80 / 255.0, accuracy: 0.001)
        XCTAssertEqual(RingColor.accent.nsColor, NSColor.controlAccentColor, "the accent colour is followed, not copied")
    }

    func testTheSettingsWindowWritesTheRingIntoTheFile() throws {
        let backend = SettingsModelTests.FakeBackend()
        defer { try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent()) }
        // A file from before the ring existed, with a comment of the user's own.
        try ConfigFile.write("# mine\n[gaps]\ninner = 4   # tight\n", to: backend.configURL)
        backend.reloadConfig()
        let model = SettingsModel(backend: backend)
        XCTAssertFalse(model.config.focusRing.enabled)

        model.set(["focus-ring", "enabled"], .bool(true))
        model.setNumber(["focus-ring", "width"], 6)
        model.set(["focus-ring", "color"], .string("#8fd43f"))
        XCTAssertTrue(model.config.focusRing.enabled)
        XCTAssertEqual(model.config.focusRing.width, 6)
        XCTAssertEqual(model.config.focusRing.color, RingColor(text: "#8fd43f"))
        XCTAssertEqual(model.problems, [])
        let text = try String(contentsOf: backend.configURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# mine\n[gaps]\ninner = 4   # tight\n"), "what was there is kept:\n\(text)")
        XCTAssertTrue(text.contains("[focus-ring]"))

        model.set(["focus-ring", "color"], .string("accent"))
        XCTAssertEqual(model.config.focusRing.color, .accent)
    }
}
