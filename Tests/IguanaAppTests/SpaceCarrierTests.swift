import ApplicationServices
import XCTest
@testable import iguana

/// `SpaceCarrier` on its own: where it takes hold of a window, how long it holds on, and what
/// it says when the window does not go.
final class SpaceCarrierTests: XCTestCase {
    private var scheduler: FakeScheduler!
    private var system: FakeWindowSystem!
    private var carrier: SpaceCarrier!
    private var display: FakeDisplay!
    private var window: FakeWindow!
    private var log: [String] = []
    /// How often a carry said it was over.
    private var finished = 0

    private var one: FakeSpace { display.spaces[0] }
    private var two: FakeSpace { display.spaces[1] }
    private var mouseDowns: [CGPoint] { system.posted.filter { $0.type == .leftMouseDown }.map(\.point) }

    // The spots of a window at 100, 100 that is 600 wide, in the order they are tried.
    private let betweenCloseAndMinimise = CGPoint(x: 126, y: 114)
    private let betweenMinimiseAndZoom = CGPoint(x: 146, y: 114)
    private let topMiddle = CGPoint(x: 400, y: 106)
    private let rightOfZoom = CGPoint(x: 173, y: 114)
    private let furtherAlong = CGPoint(x: 200, y: 114)

    override func setUp() {
        super.setUp()
        scheduler = FakeScheduler()
        system = FakeWindowSystem(scheduler: scheduler)
        display = system.addDisplay(desktops: 2)
        window = system.open(system.launch("Notes"), frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        // Let the app finish saying that its window opened.
        scheduler.runUntilIdle()
        carrier = SpaceCarrier(system: system, scheduler: scheduler)
        log = []
        finished = 0
        Log.sink = { [weak self] line in self?.log.append(line) }
    }

    override func tearDown() {
        Log.sink = nil
        carrier = nil
        system = nil
        scheduler = nil
        super.tearDown()
    }

    /// Carry the window from desktop 1 with the shortcut of another desktop.
    private func carry(toDesktop number: Int = 2) {
        carrier.carry(window.id, window, window.rect, shortcutID: Private.SystemShortcut.desktop(number), from: one.id) { [weak self] in
            self?.finished += 1
        }
    }

    // MARK: Taking hold

    func testTheWindowIsHeldBetweenTheCloseAndMinimiseButtonsFirst() {
        system.pointerLocation = CGPoint(x: 900, y: 700)
        carry()
        scheduler.advance(by: 0.1)

        XCTAssertEqual(system.posted.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseDragged, .leftMouseDragged])
        XCTAssertEqual(system.posted[0].point, betweenCloseAndMinimise)
        XCTAssertEqual(system.posted[1].point, betweenCloseAndMinimise)
        XCTAssertEqual(window.rect.origin, CGPoint(x: 108, y: 108), "pulled a little, to see that it follows")
        XCTAssertTrue(system.pressed.isEmpty, "the shortcut waits until it does")

        scheduler.advance(by: 0.1)
        XCTAssertEqual(system.pressed, [Private.SystemShortcut.desktop(2)])
    }

    func testTheSpotsAreTriedInOrderUntilOneHolds() {
        // An app that draws its own title bar: only the part right of its buttons drags the window.
        window.canBeDraggedAt = { $0.y > 110 && $0.x > 160 }
        carry()
        scheduler.runUntilIdle()

        XCTAssertEqual(mouseDowns, [betweenCloseAndMinimise, betweenMinimiseAndZoom, topMiddle, rightOfZoom])
        // A spot that did not hold is let go of well away from it, so that nothing is clicked.
        let away = CGPoint(x: betweenCloseAndMinimise.x + 60, y: betweenCloseAndMinimise.y + 60)
        let firstUp = system.posted.first { $0.type == .leftMouseUp }
        XCTAssertEqual(firstUp?.point, away)
        XCTAssertEqual(window.spaces, [two.id], "held at the fourth spot, it went")
        XCTAssertEqual(finished, 1)
        XCTAssertTrue(log.isEmpty)
    }

    func testAWindowNoSpotHoldsIsLeftAndThePointerPutBack() {
        system.pointerLocation = CGPoint(x: 900, y: 700)
        window.canBeDraggedAt = { _ in false }
        carry()
        XCTAssertTrue(carrier.isCarrying)
        scheduler.runUntilIdle()

        XCTAssertEqual(mouseDowns, [betweenCloseAndMinimise, betweenMinimiseAndZoom, topMiddle, rightOfZoom, furtherAlong])
        XCTAssertEqual(log, ["move-to-space: could not take hold of window \(window.id) by its title bar, so it stays where it is"])
        XCTAssertTrue(system.pressed.isEmpty)
        XCTAssertEqual(window.rect.origin, CGPoint(x: 100, y: 100))
        XCTAssertFalse(system.leftMouseIsDown)
        XCTAssertEqual(system.pointerLocation, CGPoint(x: 900, y: 700))
        XCTAssertFalse(carrier.isCarrying)
        XCTAssertEqual(finished, 1)

        // A window that has closed is not reached for: whatever is there instead is not clicked.
        system.close(window)
        let events = system.posted.count
        carry()
        XCTAssertEqual(system.posted.count, events)
        XCTAssertEqual(log.count, 2)
        XCTAssertFalse(carrier.isCarrying)
        XCTAssertEqual(finished, 2)
    }

    // MARK: Holding on and letting go

    func testCarryingLastsFromTheGrabUntilTheButtonIsUp() {
        system.pointerLocation = CGPoint(x: 900, y: 700)
        XCTAssertFalse(carrier.isCarrying)
        carry()
        XCTAssertTrue(carrier.isCarrying)

        // 0.2 s to take hold, then the shortcut: this Mac changes desktop at once.
        scheduler.advance(by: 0.25)
        XCTAssertEqual(display.currentSpace.id, two.id)
        // The Space changes part-way through the slide, so the button stays down a while yet.
        scheduler.advance(by: 0.5)
        XCTAssertTrue(carrier.isCarrying)
        XCTAssertTrue(system.leftMouseIsDown)
        XCTAssertEqual(finished, 0)

        scheduler.advance(by: 0.1)
        XCTAssertFalse(system.leftMouseIsDown)
        XCTAssertEqual(system.posted.last?.type, .leftMouseUp)
        XCTAssertEqual(system.posted.last?.point, CGPoint(x: betweenCloseAndMinimise.x + 8, y: betweenCloseAndMinimise.y + 8), "let go where it was held")
        XCTAssertFalse(carrier.isCarrying)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(system.pointerLocation, CGPoint(x: 900, y: 700), "the pointer is back where the user had it")
        XCTAssertEqual(window.spaces, [two.id])

        scheduler.runUntilIdle()
        XCTAssertTrue(log.isEmpty, "nothing to report")
        XCTAssertEqual(finished, 1)
    }

    func testASlowSwitchIsHeldOnToForLonger() {
        // A shortcut that fires and changes nothing here, so that the test can change the
        // desktop when it likes: one for a desktop this Mac has not got.
        carry(toDesktop: 9)
        scheduler.advance(by: 0.2)
        XCTAssertEqual(system.pressed, [Private.SystemShortcut.desktop(9)])

        // macOS plays the slide in slow motion: the Space changes a second after the shortcut.
        scheduler.advance(by: 1)
        system.show(two, on: display)

        // Three times as long again for the rest of it.
        scheduler.advance(by: 2.8)
        XCTAssertTrue(system.leftMouseIsDown)
        XCTAssertEqual(finished, 0)
        scheduler.advance(by: 0.6)
        XCTAssertFalse(system.leftMouseIsDown)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(window.spaces, [two.id])
    }

    func testAShortcutThatDoesNotFireLetsGoAtOnce() {
        system.shortcutsWork = false
        carry()
        scheduler.advance(by: 0.2)

        XCTAssertFalse(system.leftMouseIsDown)
        XCTAssertEqual(log, ["move-to-space: could not trigger the system shortcut, so window \(window.id) stays where it is"])
        XCTAssertFalse(carrier.isCarrying)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(window.spaces, [one.id])
    }

    func testADesktopThatNeverChangesIsGivenUpOnAfterEightSeconds() {
        carry(toDesktop: 9)
        scheduler.advance(by: 0.2)
        XCTAssertEqual(system.pressed.count, 1)

        scheduler.advance(by: 7.9)
        XCTAssertTrue(system.leftMouseIsDown)
        XCTAssertTrue(carrier.isCarrying)

        scheduler.advance(by: 0.3)
        XCTAssertFalse(system.leftMouseIsDown)
        XCTAssertEqual(log, ["move-to-space: the desktop did not change, so window \(window.id) stays where it is"])
        XCTAssertFalse(carrier.isCarrying)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(window.spaces, [one.id])
        XCTAssertEqual(scheduler.pending, 0, "and nothing more is waited for")
    }

    func testAWindowThatDidNotComeAlongIsReported() {
        carry()
        scheduler.advance(by: 0.9)
        XCTAssertEqual(finished, 1)
        // macOS changed desktop and left the window behind.
        system.put(window, on: one)
        scheduler.runUntilIdle()

        XCTAssertEqual(log, ["move-to-space: window \(window.id) did not come along to the new Space"])
    }

    // MARK: Waiting for the Space to change

    func testWhenSpaceChangesSaysYesAsSoonAsTheSpaceIsLeft() {
        var answers: [Bool] = []
        carrier.whenSpaceChanges(from: two.id, timeout: 3) { answers.append($0) }
        XCTAssertEqual(answers, [true], "at once for a Space that is not being shown")

        carrier.whenSpaceChanges(from: one.id, timeout: 3) { answers.append($0) }
        scheduler.advance(by: 1)
        XCTAssertEqual(answers, [true], "not while it is still being shown")

        system.show(two, on: display)
        scheduler.advance(by: 0.06)
        XCTAssertEqual(answers, [true, true])
        scheduler.runUntilIdle()
        XCTAssertEqual(answers, [true, true], "and only once")
    }

    func testWhenSpaceChangesSaysNoWhenTheTimeIsUp() {
        var answers: [Bool] = []
        carrier.whenSpaceChanges(from: nil, timeout: 3) { answers.append($0) }
        XCTAssertEqual(answers, [false], "at once when there is no Space to leave")
        carrier.whenSpaceChanges(from: one.id, timeout: 0) { answers.append($0) }
        XCTAssertEqual(answers, [false, false], "and when there is no time to wait")

        carrier.whenSpaceChanges(from: one.id, timeout: 1) { answers.append($0) }
        scheduler.advance(by: 0.9)
        XCTAssertEqual(answers.count, 2)
        scheduler.advance(by: 0.2)
        XCTAssertEqual(answers, [false, false, false])
        XCTAssertEqual(scheduler.pending, 0)
    }
}
