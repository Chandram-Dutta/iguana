import AppKit
import XCTest
import IguanaCore
@testable import iguana

/// The outline of a dragged tile's landing place, in the app: when the pointer is listened to,
/// and how the overlay is drawn. The window manager here has not started, so nothing is being
/// dragged and nothing is ever put on screen.
final class DragPreviewTests: XCTestCase {
    func testThePointerIsListenedToOnlyDuringADrag() {
        let wm = WindowManager()
        let preview = DragPreview()
        XCTAssertFalse(preview.isTracking, "no drag costs nothing: no event monitor is installed")
        XCTAssertFalse(preview.hasMonitor)
        // A window moved and the screen was looked at again, with no drag going on.
        preview.moved()
        preview.changed(wm)
        XCTAssertFalse(preview.isTracking)

        preview.drag(true, wm)
        XCTAssertTrue(preview.isTracking)
        XCTAssertTrue(preview.hasMonitor)
        preview.drag(true, wm)
        XCTAssertTrue(preview.isTracking)
        // The window manager is not dragging anything, so a look finds nothing to draw.
        preview.changed(wm)

        preview.drag(false, wm)
        XCTAssertFalse(preview.isTracking)
        XCTAssertFalse(preview.hasMonitor, "the monitor is removed when the drag ends")
        preview.drag(false, wm)
        XCTAssertFalse(preview.isTracking)
    }

    func testNothingIsPlannedWhenNothingIsTiled() {
        let wm = WindowManager()
        XCTAssertNil(wm.dragging)
        XCTAssertNil(wm.onDrag)
        XCTAssertTrue(wm.tileFrames.isEmpty)
        let start = CGRect(x: 0, y: 40, width: 500, height: 600)
        XCTAssertNil(wm.dropPlan(dragging: 1, from: start, now: start.offsetBy(dx: 400, dy: 100), at: CGPoint(x: 700, y: 150)),
                     "a window without a tile is not dropped on anything")
        XCTAssertNil(wm.dropPlan(dragging: 1, from: start, now: CGRect(x: 0, y: 40, width: 700, height: 600), at: CGPoint(x: 700, y: 150)),
                     "an edge being dragged is a resize")
    }

    func testTheLandingPlaceIsDrawnAsALineWithAFaintFill() throws {
        let primary = try XCTUnwrap(NSScreen.screens.first?.frame.height, "needs a display")
        let overlay = OutlineOverlay()
        let place = CGRect(x: 500, y: 38, width: 500, height: 300)
        let accent = NSColor.controlAccentColor
        overlay.draw(DragDrop.outline(for: place, lineWidth: 2, cornerRadius: 16), color: accent, fill: accent.withAlphaComponent(0.14))
        XCTAssertEqual(overlay.window.frame, CGRect(x: 500, y: primary - 338, width: 500, height: 300), "exactly the frame the window will have")
        XCTAssertFalse(overlay.isShown, "drawing does not put it on screen")
        let layer = try XCTUnwrap(overlay.window.contentView?.layer)
        XCTAssertEqual(layer.borderWidth, 2)
        XCTAssertEqual(layer.cornerRadius, 16, "as round as a window")
        // A window that is not on screen is not drawn by asking the window, so the view is asked.
        overlay.window.contentView?.displayIfNeeded()
        XCTAssertEqual(layer.borderColor?.alpha, 1, "the line is solid")
        XCTAssertNotEqual(layer.borderColor?.components?.prefix(3).reduce(0, +), 0, "and in the accent colour, not the black a layer starts with")
        let fill = try XCTUnwrap(layer.backgroundColor)
        XCTAssertEqual(fill.alpha, 0.14, accuracy: 0.01, "the windows under it stay in view")
    }
}
