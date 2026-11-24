import XCTest
@testable import IguanaCore

/// `[focus-ring]`: its colour, its shape, when it is drawn, and how the config file carries it.
final class FocusRingTests: XCTestCase {
    // MARK: Colour

    func testAColourIsTheAccentOrWrittenAsTheWebWritesIt() {
        XCTAssertEqual(RingColor(text: "accent"), .accent)
        XCTAssertEqual(RingColor(text: " Accent "), .accent)
        XCTAssertEqual(RingColor(text: "#ff8000"), .custom(red: 1, green: 128 / 255.0, blue: 0, alpha: 1))
        XCTAssertEqual(RingColor(text: "#FF8000"), RingColor(text: "#ff8000"), "capitals do not matter")
        XCTAssertEqual(RingColor(text: "#8d3"), RingColor(text: "#88dd33"), "the short form doubles each digit")
        XCTAssertEqual(RingColor(text: "#00000080"), .custom(red: 0, green: 0, blue: 0, alpha: 128 / 255.0), "a fourth pair is the opacity")
    }

    func testWhatIsNotAColourIsRefused() {
        for text in ["", "#", "green", "8fd43f", "#8fd4", "#8fd43", "#8fd43f0", "#8fd43f000", "#8fd43g", "# 8fd43f", "#٣٣٣", "#ＦＦＦ"] {
            XCTAssertNil(RingColor(text: text), text)
        }
    }

    func testAColourIsWrittenBackAsItWasRead() {
        for text in ["accent", "#8fd43f", "#000000", "#ffffff", "#8fd43f80"] {
            XCTAssertEqual(RingColor(text: text)?.text, text)
        }
        XCTAssertEqual(RingColor(text: "#8D3")?.text, "#88dd33")
        XCTAssertEqual(RingColor(text: "#8fd43fff")?.text, "#8fd43f", "a solid colour needs no opacity")
        XCTAssertEqual(RingColor.custom(red: 2, green: -1, blue: 0.5, alpha: 1).text, "#ff0080", "values outside 0 to 1 are held to it")
    }

    // MARK: Shape

    func testTheLineLiesOutsideTheWindowAndFollowsItsCorners() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let outline = Outline(rect: window, lineWidth: 3, cornerRadius: 16)
        XCTAssertEqual(outline.bounds, CGRect(x: 97, y: 197, width: 806, height: 606))
        XCTAssertTrue(outline.bounds.contains(window), "the window is wholly inside what the line surrounds")
        XCTAssertEqual(outline.outerRadius, 19, "the outer edge shares its centre with the window's corner")
        // On a display 1000 points tall, AppKit measures the same place from the bottom.
        XCTAssertEqual(outline.appKitFrame(primaryHeight: 1000), CGRect(x: 97, y: 197, width: 806, height: 606))
        XCTAssertEqual(outline.appKitFrame(primaryHeight: 1200), CGRect(x: 97, y: 397, width: 806, height: 606))
        // A window on a display above the primary one has a negative y from the top.
        let above = Outline(rect: CGRect(x: 0, y: -900, width: 400, height: 300), lineWidth: 2, cornerRadius: 10)
        XCTAssertEqual(above.appKitFrame(primaryHeight: 1000), CGRect(x: -2, y: 1598, width: 404, height: 304))
    }

    func testCornersGoByTheVersionOfMacOS() {
        XCTAssertEqual(WindowCorners.radius(macOSMajor: 14), 10)
        XCTAssertEqual(WindowCorners.radius(macOSMajor: 15), 10)
        XCTAssertEqual(WindowCorners.radius(macOSMajor: 26), 16)
        XCTAssertEqual(WindowCorners.radius(macOSMajor: 27), 16)
        XCTAssertEqual(WindowCorners.radius(macOSMajor: 16), 16, "macOS 26 as a program built with an older SDK sees it")
    }

    func testTheRingIsOnlyForAStandardWindowOnADesktop() {
        var settings = FocusRingSettings()
        let frame = CGRect(x: 8, y: 46, width: 600, height: 400)
        func outline(frame: CGRect? = frame, standard: Bool = true, onDesktop: Bool = true) -> Outline? {
            FocusRingPlan.outline(settings: settings, frame: frame, standard: standard, onDesktop: onDesktop, cornerRadius: 16)
        }
        XCTAssertNil(outline(), "off until it is switched on")
        settings.enabled = true
        settings.width = 5
        XCTAssertEqual(outline(), Outline(rect: frame, lineWidth: 5, cornerRadius: 16))
        XCTAssertNil(outline(frame: nil), "a window that is not on screen")
        XCTAssertNil(outline(standard: false), "a dialog or a sheet")
        XCTAssertNil(outline(onDesktop: false), "a window in native fullscreen")
        XCTAssertNil(outline(frame: .zero))
        // A corner cannot be rounder than half of the shorter side.
        XCTAssertEqual(outline(frame: CGRect(x: 0, y: 0, width: 300, height: 20))?.cornerRadius, 10)
    }

    func testAWindowIsOnTheDisplayThatHoldsItsCentre() {
        let laptop = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let monitor = CGRect(x: 1500, y: -200, width: 2500, height: 1400)
        XCTAssertEqual(FocusRingPlan.screen(for: CGRect(x: 100, y: 100, width: 600, height: 400), among: [laptop, monitor]), 0)
        XCTAssertEqual(FocusRingPlan.screen(for: CGRect(x: 1400, y: 100, width: 600, height: 400), among: [laptop, monitor]), 1, "across the edge: where its centre is")
        // The centre is on no display (dragged half below the screen): the display that shows most of it.
        XCTAssertEqual(FocusRingPlan.screen(for: CGRect(x: 1300, y: 900, width: 240, height: 300), among: [laptop, monitor]), 0)
        XCTAssertNil(FocusRingPlan.screen(for: CGRect(x: 9000, y: 9000, width: 300, height: 300), among: [laptop, monitor]))
        XCTAssertNil(FocusRingPlan.screen(for: laptop, among: []))
    }

    // MARK: When it is drawn

    typealias Look = FocusRingTracker.Look
    typealias Verdict = FocusRingTracker.Verdict

    let here = CGRect(x: 8, y: 46, width: 600, height: 400)
    let there = CGRect(x: 616, y: 46, width: 600, height: 400)

    func testAWindowAtRestHasItsRingAtOnce() {
        var tracker = FocusRingTracker()
        XCTAssertEqual(tracker.look(Look(window: 1, frame: here, time: 0)), Verdict(frame: here, lookAgain: false), "no waiting when the focus arrives")
        XCTAssertEqual(tracker.look(Look(window: 1, frame: here, time: 5)), Verdict(frame: here, lookAgain: false))
        XCTAssertEqual(tracker.look(Look(window: 2, frame: there, time: 5.01)), Verdict(frame: there, lookAgain: false), "the focus went to another window")
        XCTAssertEqual(tracker.look(nil), Verdict(frame: nil, lookAgain: false), "no window has the focus")
    }

    func testTheRingStepsAsideForAGlideAndComesBackWhereItLands() {
        var tracker = FocusRingTracker()
        _ = tracker.look(Look(window: 1, frame: here, time: 0))
        // The layout changed: Iguana glides the window to its new slot.
        XCTAssertEqual(tracker.look(Look(window: 1, frame: here, gliding: true, heading: there, time: 1)), Verdict(frame: nil, lookAgain: true),
                       "never left behind at the old place")
        let midway = CGRect(x: 300, y: 46, width: 600, height: 400)
        XCTAssertEqual(tracker.look(Look(window: 1, frame: midway, gliding: true, heading: there, time: 1.03)), Verdict(frame: nil, lookAgain: true))
        // The glide is over and the window is where it was sent: no need to wait and see.
        XCTAssertEqual(tracker.look(Look(window: 1, frame: there, time: 1.17)), Verdict(frame: there, lookAgain: false))
    }

    func testAWindowPlacedAtOnceTakesItsRingAlong() {
        var tracker = FocusRingTracker()
        _ = tracker.look(Look(window: 1, frame: here, time: 0))
        // Not yet moved by its app, but on its way without a glide: the ring goes ahead.
        XCTAssertEqual(tracker.look(Look(window: 1, frame: here, heading: there, time: 1)), Verdict(frame: there, lookAgain: true))
        XCTAssertEqual(tracker.look(Look(window: 1, frame: there, time: 1.03)), Verdict(frame: there, lookAgain: false))
    }

    func testAWindowThatStopsShortOfWhereItWasSentIsRingedWhereItStopped() {
        // A terminal takes sizes in whole rows only, and a window may have a minimum size.
        let taken = CGRect(x: 616, y: 46, width: 620, height: 392)
        var tracker = FocusRingTracker()
        _ = tracker.look(Look(window: 1, frame: here, time: 0))
        XCTAssertEqual(tracker.look(Look(window: 1, frame: here, heading: there, time: 1)).frame, there)
        XCTAssertEqual(tracker.look(Look(window: 1, frame: taken, time: 1.03)), Verdict(frame: nil, lookAgain: true), "not where the ring is: wait until it is still")
        XCTAssertEqual(tracker.look(Look(window: 1, frame: taken, time: 1.06)), Verdict(frame: nil, lookAgain: true))
        XCTAssertEqual(tracker.look(Look(window: 1, frame: taken, time: 1.09)), Verdict(frame: taken, lookAgain: false))
    }

    func testTheRingStepsAsideWhileTheUserDragsTheWindow() {
        var tracker = FocusRingTracker()
        _ = tracker.look(Look(window: 1, frame: here, time: 0))
        // The button goes down in the window without moving it (selecting text): nothing changes.
        XCTAssertEqual(tracker.look(Look(window: 1, frame: here, mouseDown: true, time: 1)), Verdict(frame: here, lookAgain: false))
        var frame = here
        for step in 1...5 {
            frame.origin.x += 40
            XCTAssertEqual(tracker.look(Look(window: 1, frame: frame, mouseDown: true, time: 1 + Double(step) * 0.016)), Verdict(frame: nil, lookAgain: true))
        }
        // Holding it still with the button down is a pause in the drag, not the end of it.
        XCTAssertEqual(tracker.look(Look(window: 1, frame: frame, mouseDown: true, time: 3)), Verdict(frame: nil, lookAgain: true))
        // Let go: the window has been still for long enough already.
        XCTAssertEqual(tracker.look(Look(window: 1, frame: frame, time: 3.03)), Verdict(frame: frame, lookAgain: false))
    }

    func testAWindowMovedBySomethingElseIsRingedOnceItIsStill() {
        // The app moved its own window, or the system played one of its own window animations.
        var tracker = FocusRingTracker()
        _ = tracker.look(Look(window: 1, frame: here, time: 0))
        var frame = here
        for step in 1...6 {
            frame.origin.y += 30
            XCTAssertEqual(tracker.look(Look(window: 1, frame: frame, time: 1 + Double(step) * 0.016)), Verdict(frame: nil, lookAgain: true))
        }
        // Two notifications about the same frame in the same instant do not make it still.
        XCTAssertEqual(tracker.look(Look(window: 1, frame: frame, time: 1.097)), Verdict(frame: nil, lookAgain: true))
        XCTAssertEqual(tracker.look(Look(window: 1, frame: frame, time: 1.1 + FocusRingTracker.settle)), Verdict(frame: frame, lookAgain: false))
    }

    func testClickingAWindowToFocusItRingsItWithTheButtonStillDown() {
        var tracker = FocusRingTracker()
        _ = tracker.look(Look(window: 1, frame: here, time: 0))
        XCTAssertEqual(tracker.look(Look(window: 2, frame: there, mouseDown: true, time: 1)), Verdict(frame: there, lookAgain: false))
    }

    func testAHalfPointOfRoundingIsNotAMove() {
        var tracker = FocusRingTracker()
        _ = tracker.look(Look(window: 1, frame: here, time: 0))
        let rounded = here.offsetBy(dx: 0.5, dy: -0.5)
        XCTAssertEqual(tracker.look(Look(window: 1, frame: rounded, time: 1)), Verdict(frame: rounded, lookAgain: false))
    }

    // MARK: Config

    func testTheRingIsOffUntilAskedFor() throws {
        XCTAssertEqual(Config.default.focusRing, FocusRingSettings())
        XCTAssertFalse(Config.default.focusRing.enabled)
        XCTAssertEqual(Config.default.focusRing.width, 3)
        XCTAssertEqual(Config.default.focusRing.color, .accent)

        let (c, warnings) = try Config.load("[focus-ring]\nenabled = true\nwidth = 5\ncolor = \"#8fd43f\"\n")
        XCTAssertEqual(warnings, [])
        XCTAssertTrue(c.focusRing.enabled)
        XCTAssertEqual(c.focusRing.width, 5)
        XCTAssertEqual(c.focusRing.color, RingColor(text: "#8fd43f"))
        XCTAssertEqual(try Config.load("[focus-ring]\nenabled = true\n").config.focusRing.color, .accent, "what is left out keeps its built-in value")
    }

    func testAWrongValueKeepsItsDefaultAndSaysSo() throws {
        let (c, warnings) = try Config.load("[focus-ring]\nenabled = \"yes\"\nwidth = 40\ncolor = \"greenish\"\nglow = true\n")
        XCTAssertEqual(c.focusRing, FocusRingSettings())
        XCTAssertEqual(warnings.count, 4, "one for each wrong value, one for the unknown key: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("focus-ring.width") && $0.contains("1 to 10") })
        XCTAssertTrue(warnings.contains { $0.contains("focus-ring.color") && $0.contains("accent") })
        XCTAssertEqual(try Config.load("[focus-ring]\ncolor = 7\n").warnings.count, 1, "a colour is a string")
        XCTAssertEqual(try Config.load("[focus-ring]\nwidth = 0\n").warnings.count, 1)
        XCTAssertEqual(try Config.load("[focus-ring]\nwidth = 1.5\n").config.focusRing.width, 1.5)
    }

    func testTheSchemaTakesTheColoursTheLoaderTakes() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let ring = try XCTUnwrap(((schema["properties"] as? [String: Any])?["focus-ring"] as? [String: Any])?["properties"] as? [String: Any])
        let pattern = try XCTUnwrap((ring["color"] as? [String: Any])?["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        for text in ["accent", "#8fd43f", "#8D3", "#8fd43f80", "green", "#8fd4", "8fd43f", ""] {
            let matches = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            XCTAssertEqual(matches, RingColor(text: text) != nil, text)
        }
    }

    func testTurningTheRingOnInAFileKeepsTheRestOfIt() throws {
        // What the settings window does: it rewrites the one value.
        var editor = TOMLEditor(Config.defaultText)
        editor.set(["focus-ring", "enabled"], to: .bool(true))
        editor.set(["focus-ring", "color"], to: .string("#8fd43f"))
        XCTAssertEqual(editor.text.components(separatedBy: "\n").count, Config.defaultText.components(separatedBy: "\n").count, "no lines added or lost")
        XCTAssertTrue(editor.text.contains("width = 3            # points, 1 to 10"), "the comments stay")
        let (c, warnings) = try Config.load(editor.text)
        XCTAssertEqual(warnings, [])
        XCTAssertTrue(c.focusRing.enabled)
        XCTAssertEqual(c.focusRing.color.text, "#8fd43f")

        // A file written before the ring existed gets the section added.
        var old = TOMLEditor("[gaps]\ninner = 4   # tight\n")
        old.set(["focus-ring", "enabled"], to: .bool(true))
        XCTAssertTrue(old.text.hasPrefix("[gaps]\ninner = 4   # tight\n"))
        XCTAssertTrue(try Config.load(old.text).config.focusRing.enabled)
    }
}
