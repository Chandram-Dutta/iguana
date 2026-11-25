import XCTest
@testable import IguanaCore

/// `window-created`, `window-closed`, `layout-changed` and `pause-changed`: when each is due,
/// and what its command is told.
final class HookEventTests: XCTestCase {
    typealias Look = HookTracker.Look
    typealias Window = HookTracker.Window

    let laptop = HookTracker.Showing(display: "laptop", space: "space-a", desktop: 1)

    /// Every window is described the same way, with a title that says how often it was asked.
    var asked: [WindowID: Int] = [:]
    func describe(_ id: WindowID) -> Window {
        asked[id, default: 0] += 1
        return Window(id: id, app: "App \(id)", title: "Title \(id)", desktop: 1, display: "Built-in Retina Display")
    }

    func look(standard: Set<WindowID>, existing: Set<WindowID>? = nil, paused: Bool = false,
              arrangement: HookTracker.Arrangement? = nil, showing: HookTracker.Showing? = nil) -> Look {
        let showing = showing ?? laptop
        return Look(showing: [showing], focused: nil, paused: paused, existing: existing ?? standard, standard: standard,
                    arrangements: arrangement.map { [showing.display: $0] } ?? [:])
    }

    func arrangement(_ windows: [WindowID], visible: Set<WindowID>? = nil, zoomed: WindowID? = nil, _ change: (Tree) -> Void = { _ in }) -> HookTracker.Arrangement {
        let tree = Tree()
        for id in windows { tree.insert(id, after: tree.windows.last, split: .horizontal) }
        change(tree)
        return HookTracker.Arrangement(layout: tree.snapshot, visible: visible ?? Set(windows), zoomed: zoomed)
    }

    // MARK: Windows

    func testAWindowThatOpensIsCreatedOnce() {
        var tracker = HookTracker()
        XCTAssertEqual(tracker.observe(look(standard: [1, 2]), describe: describe), [], "the windows at the first look are where Iguana starts from")

        let changes = tracker.observe(look(standard: [1, 2, 7]), describe: describe)
        XCTAssertEqual(changes, [.created(Window(id: 7, app: "App 7", title: "Title 7", desktop: 1, display: "Built-in Retina Display"))])
        for _ in 0..<5 { XCTAssertEqual(tracker.observe(look(standard: [1, 2, 7]), describe: describe), []) }
        XCTAssertEqual(asked, [1: 1, 2: 1, 7: 1], "each window is described once, however often Iguana looks")

        // Two at once, in the order the system numbered them.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 7, 9, 8]), describe: describe).created, [8, 9])
    }

    func testTheWindowsThatWereThereFirstAreNeverNew() {
        var tracker = HookTracker()
        // Window 3 is on another desktop: the system has it, Iguana does not know it yet.
        _ = tracker.observe(look(standard: [1], existing: [1, 3]), describe: describe)
        XCTAssertEqual(tracker.observe(look(standard: [1, 3]), describe: describe), [], "its desktop is shown, and it was open all along")
        XCTAssertEqual(asked[3], 1, "it is described, so that it can be told about when it closes")

        // Window 4 opened as something else, and only later settled into a standard window.
        XCTAssertEqual(tracker.observe(look(standard: [1, 3], existing: [1, 3, 4]), describe: describe), [])
        XCTAssertEqual(tracker.observe(look(standard: [1, 3, 4]), describe: describe).created, [4])
        XCTAssertEqual(tracker.observe(look(standard: [1, 3, 4]), describe: describe), [])
    }

    func testAWindowThatClosesIsToldAsItWasLastSeen() {
        var tracker = HookTracker()
        _ = tracker.observe(look(standard: [1, 2, 3]), describe: describe)

        // Minimised, hidden, or on another desktop: the system still has it.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3]), describe: describe), [])
        XCTAssertEqual(tracker.observe(look(standard: [1, 2], existing: [1, 2, 3]), describe: describe), [],
                       "a window Iguana stops counting is not closed while it exists")

        tracker.remember(Window(id: 2, app: "Safari", title: "Later title", desktop: 3, display: "Studio Display"))
        XCTAssertEqual(tracker.observe(look(standard: [1]), describe: describe),
                       [.closed(Window(id: 2, app: "Safari", title: "Later title", desktop: 3, display: "Studio Display")),
                        .closed(Window(id: 3, app: "App 3", title: "Title 3", desktop: 1, display: "Built-in Retina Display"))])
        XCTAssertEqual(tracker.observe(look(standard: [1]), describe: describe), [], "once")

        // A window that opens and closes is told about both times.
        XCTAssertEqual(tracker.observe(look(standard: [1, 5]), describe: describe).created, [5])
        XCTAssertEqual(tracker.observe(look(standard: [1]), describe: describe).closed, [5])

        // One that was never a standard window is neither.
        XCTAssertEqual(tracker.observe(look(standard: [1], existing: [1, 6]), describe: describe), [])
        XCTAssertEqual(tracker.observe(look(standard: [1]), describe: describe), [])
    }

    func testRememberingAWindowNeverMakesItKnown() {
        var tracker = HookTracker()
        _ = tracker.observe(look(standard: [1]), describe: describe)
        tracker.remember(Window(id: 4, app: "Notes", title: "", desktop: nil, display: nil))
        XCTAssertEqual(tracker.observe(look(standard: [1, 4]), describe: describe).created, [4], "still new, and described then")
        XCTAssertEqual(asked[4], 1)
    }

    // MARK: Layouts

    func testALayoutChangeIsDueOnlyWhenTheArrangementIsDifferent() {
        var tracker = HookTracker()
        let three = arrangement([1, 2, 3])
        _ = tracker.observe(look(standard: [1, 2, 3], arrangement: three), describe: describe)
        for _ in 0..<5 {
            XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], arrangement: three), describe: describe), [],
                           "windows gliding to their tiles and the focus moving are not in the arrangement")
        }

        let changed: [(String, HookTracker.Arrangement)] = [
            ("a window minimised", arrangement([1, 2, 3], visible: [1, 2])),
            ("a window left the layout", arrangement([1, 2])),
            ("a window joined it", arrangement([1, 2, 4])),
            ("a new shape", arrangement([1, 2, 4]) { $0.flip(2) }),
            ("other proportions", arrangement([1, 2, 4]) { $0.flip(2); $0.changeShare(of: 1, along: .vertical, .delta(0.1)) }),
            ("a stack", arrangement([1, 2, 4]) { $0.flip(2); $0.changeShare(of: 1, along: .vertical, .delta(0.1)); $0.toggleStack(1) }),
        ]
        var last = three
        for (why, next) in changed {
            XCTAssertNotEqual(next, last, why)
            XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3, 4], arrangement: next), describe: describe).filter { $0 == .layout(display: "laptop") },
                           [.layout(display: "laptop")], why)
            XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3, 4], arrangement: next), describe: describe), [], "\(why), once")
            last = next
        }

        var zoomed = last
        zoomed.zoomed = 4
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3, 4], arrangement: zoomed), describe: describe), [.layout(display: "laptop")])
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3, 4], arrangement: last), describe: describe), [.layout(display: "laptop")], "zoomed back")
    }

    func testEachDesktopIsComparedWithItself() {
        var tracker = HookTracker()
        let first = arrangement([1, 2])
        _ = tracker.observe(look(standard: [1, 2], existing: [1, 2, 3], arrangement: first), describe: describe)

        // Another desktop, seen for the first time: the desktop changed, its layout did not.
        let second = HookTracker.Showing(display: "laptop", space: "space-b", desktop: 2)
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], arrangement: arrangement([3]), showing: second), describe: describe),
                       [.desktop(display: "laptop")])
        // Back to the first, as it was left.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], arrangement: first), describe: describe), [.desktop(display: "laptop")])
        // The second again, and it changed while it was not on screen.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], arrangement: arrangement([3, 4]), showing: second), describe: describe),
                       [.desktop(display: "laptop"), .layout(display: "laptop")])

        // A display on a fullscreen Space has no arrangement, and nothing to compare.
        let fullscreen = HookTracker.Showing(display: "laptop", space: "space-f", desktop: nil)
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], showing: fullscreen), describe: describe), [.desktop(display: "laptop")])
    }

    // MARK: Pause

    func testPausingAndResuming() {
        var tracker = HookTracker()
        let three = arrangement([1, 2, 3])
        _ = tracker.observe(look(standard: [1, 2, 3], arrangement: three), describe: describe)

        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], paused: true, arrangement: three), describe: describe), [.paused(true)])
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], paused: true, arrangement: three), describe: describe), [])
        // While tiling is paused nothing is arranged, whatever the remembered layout says.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], paused: true, arrangement: arrangement([1, 2, 3], visible: [1])), describe: describe), [])

        // Resuming puts the desktop in order again, even into the arrangement it had before.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], arrangement: three), describe: describe), [.paused(false), .layout(display: "laptop")])
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], arrangement: three), describe: describe), [])

        // Windows still come and go while tiling is paused.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 3], paused: true), describe: describe), [.paused(true)])
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 4], paused: true), describe: describe).count, 2)

        // Paused twice between two looks is no change.
        XCTAssertEqual(tracker.observe(look(standard: [1, 2, 4], paused: true), describe: describe), [])
    }

    func testTheFirstLookIsNoChangeEvenWhilePaused() {
        var tracker = HookTracker()
        XCTAssertEqual(tracker.observe(look(standard: [1], paused: true, arrangement: arrangement([1])), describe: describe), [])
        XCTAssertEqual(tracker.observe(look(standard: [1], arrangement: arrangement([1])), describe: describe), [.paused(false), .layout(display: "laptop")])
    }

    // MARK: Everything at once

    func testTheOrderOfOneLook() {
        var tracker = HookTracker()
        _ = tracker.observe(Look(showing: [laptop], focused: 1, existing: [1, 2], standard: [1, 2], arrangements: ["laptop": arrangement([1, 2])]),
                            describe: describe)
        let renumbered = HookTracker.Showing(display: "laptop", space: "space-a", desktop: 2)
        let changes = tracker.observe(Look(showing: [renumbered], focused: 3, paused: false, existing: [1, 3], standard: [1, 3],
                                           arrangements: ["laptop": arrangement([1, 3])]), describe: describe)
        XCTAssertEqual(changes, [
            .desktop(display: "laptop"),
            .created(describe(3)),
            .closed(describe(2)),
            .layout(display: "laptop"),
            .focus(3),
        ], "the desktop first and the focus last")
    }

    // MARK: Variables

    func testWhatEachEventIsTold() {
        let window = Window(id: 1187, app: "Safari", title: "Iguana", desktop: 2, display: "Studio Display")
        for event in [HookEvent.windowCreated, .windowClosed] {
            XCTAssertEqual(HookEnvironment.variables(event: event, window: window), [
                "IGUANA_EVENT": event.rawValue, "IGUANA_DESKTOP": "2", "IGUANA_DISPLAY": "Studio Display",
                "IGUANA_WINDOW_ID": "1187", "IGUANA_APP": "Safari", "IGUANA_TITLE": "Iguana",
            ])
        }
        let nowhere = Window(id: 5, app: "Notes", title: "", desktop: nil, display: nil)
        XCTAssertEqual(HookEnvironment.variables(event: .windowClosed, window: nowhere)["IGUANA_DESKTOP"], "", "where it was is not known")
        XCTAssertEqual(HookEnvironment.variables(event: .windowClosed, window: nowhere)["IGUANA_DISPLAY"], "")

        XCTAssertEqual(HookEnvironment.variables(event: .layoutChanged, desktop: 3, display: "Studio Display"),
                       ["IGUANA_EVENT": "layout-changed", "IGUANA_DESKTOP": "3", "IGUANA_DISPLAY": "Studio Display"])
        XCTAssertEqual(HookEnvironment.variables(event: .layoutChanged, desktop: 3, display: "D", window: (1, "A", "T")).count, 3,
                       "no window variables for an event that is not about a window")

        XCTAssertEqual(HookEnvironment.variables(event: .pauseChanged, paused: true), ["IGUANA_EVENT": "pause-changed", "IGUANA_PAUSED": "true"])
        XCTAssertEqual(HookEnvironment.variables(event: .pauseChanged, desktop: 1, display: "D", paused: false),
                       ["IGUANA_EVENT": "pause-changed", "IGUANA_PAUSED": "false"], "about all of Iguana, so no desktop or display")
        XCTAssertNil(HookEnvironment.variables(event: .focusChanged, desktop: 1, display: "D")["IGUANA_PAUSED"])

        // Every variable is set by some event, and the environment starts clean of all of them.
        let used = HookEvent.allCases.reduce(into: Set<String>()) { set, event in
            set.formUnion(HookEnvironment.variables(event: event, window: window).keys)
        }
        XCTAssertEqual(used, Set(HookEnvironment.allVariables))
        let env = HookEnvironment.merged(inherited: ["IGUANA_PAUSED": "left over"], variables: HookEnvironment.variables(event: .windowCreated, window: window))
        XCTAssertNil(env["IGUANA_PAUSED"])
    }

    func testEveryEventHasAKeyALineInTheDefaultFileAndASummary() throws {
        for event in HookEvent.allCases {
            let (c, warnings) = try Config.load("[hooks]\n\(event.rawValue) = \"echo hi\"\n")
            XCTAssertEqual(warnings, [], event.rawValue)
            XCTAssertEqual(c.hooks, [event: "echo hi"])
            XCTAssertTrue(Config.defaultText.contains("\n\(event.rawValue) = \"\""), event.rawValue)
            XCTAssertTrue(event.summary.hasSuffix("."), event.rawValue)
        }
        XCTAssertEqual(Set(HookEvent.allCases.map(\.summary)).count, HookEvent.allCases.count)
        XCTAssertEqual(try Config.load("[hooks]\nwindow-opened = \"x\"\n").warnings, ["unknown key 'window-opened' in [hooks]"])
    }
}

private extension HookTracker.Change {
    var created: WindowID? { if case .created(let w) = self { return w.id }; return nil }
    var closed: WindowID? { if case .closed(let w) = self { return w.id }; return nil }
}

private extension Array where Element == HookTracker.Change {
    var created: [WindowID] { compactMap(\.created) }
    var closed: [WindowID] { compactMap(\.closed) }
}
