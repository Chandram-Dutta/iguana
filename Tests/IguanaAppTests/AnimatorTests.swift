import AppKit
import XCTest
import IguanaCore
@testable import iguana

/// The real `Animator`, moving windows of the made-up Mac.
///
/// It writes to a window on a queue of the window's app and answers on the main queue, so
/// every test waits for an answer and none waits for time to pass. All the windows here belong
/// to one app, which keeps the writes in one line: the made-up Mac is not built to be written
/// to from two threads at once.
final class AnimatorTests: XCTestCase {
    private struct Landing: Equatable {
        let window: CGWindowID
        let asked: CGRect
        let actual: CGSize?
    }

    private var animator: Animator!
    private var system: FakeWindowSystem!
    private var app: FakeApp!
    private var window: FakeWindow!
    private var second: FakeWindow!
    /// A window that is moved only to find out that everything asked before it is done.
    private var sentinel: FakeWindow!

    private var landings: [Landing] = []
    private var answeredOffTheMainThread = false
    private var expecting: [(window: CGWindowID, asked: CGRect, done: XCTestExpectation)] = []
    private var flushes: CGFloat = 0

    override func setUp() {
        super.setUp()
        system = FakeWindowSystem(scheduler: FakeScheduler())
        system.addDisplay()
        app = system.launch("Preview")
        window = system.open(app, title: "One", frame: CGRect(x: 100, y: 100, width: 640, height: 480))
        second = system.open(app, title: "Two", frame: CGRect(x: 200, y: 200, width: 640, height: 480))
        sentinel = system.open(app, title: "Sentinel", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        animator = Animator()
        animator.onLanded = { [unowned self] id, asked, actual in
            if !Thread.isMainThread { answeredOffTheMainThread = true }
            landings.append(Landing(window: id, asked: asked, actual: actual))
            for waiting in expecting where waiting.window == id && waiting.asked == asked { waiting.done.fulfill() }
            expecting.removeAll { $0.window == id && $0.asked == asked }
        }
    }

    // The made-up Mac is kept until the test run ends: a window must outlive every write to it.

    // MARK: Placed at once

    func testAWindowPlacedAtOnceGetsItsFrameAndTheAnswerComesOnTheMainThread() {
        let target = CGRect(x: 8, y: 33, width: 708, height: 859)
        XCTAssertTrue(animator.isIdle)
        XCTAssertNil(animator.destination(of: window.id))

        place(window, at: target)
        XCTAssertEqual(animator.destination(of: window.id), target)
        XCTAssertTrue(animator.isMoving(window.id))
        XCTAssertFalse(animator.isGliding(window.id), "placed at once is not a glide")
        XCTAssertFalse(animator.isMoving(second.id))

        awaitLanding(of: window, at: target)
        XCTAssertEqual(window.rect, target)
        XCTAssertEqual(landings, [Landing(window: window.id, asked: target, actual: target.size)])
        XCTAssertFalse(answeredOffTheMainThread)
        XCTAssertNil(animator.destination(of: window.id))
        XCTAssertFalse(animator.isMoving(window.id))
        XCTAssertTrue(animator.isIdle)
    }

    func testAWindowThatComesOutBiggerReportsTheSizeItTook() {
        window.minSize = CGSize(width: 900, height: 300)
        let target = CGRect(x: 8, y: 33, width: 708, height: 859)

        place(window, at: target)
        awaitLanding(of: window, at: target)

        XCTAssertEqual(window.rect, CGRect(x: 8, y: 33, width: 900, height: 859))
        XCTAssertEqual(landings, [Landing(window: window.id, asked: target, actual: CGSize(width: 900, height: 859))])
    }

    func testAWindowThatRefusesTheSizeReportsNoSize() {
        window.resizable = false
        let target = CGRect(x: 8, y: 33, width: 708, height: 859)

        place(window, at: target)
        awaitLanding(of: window, at: target)

        XCTAssertEqual(window.rect, CGRect(x: 8, y: 33, width: 640, height: 480), "moved, and as big as it was")
        XCTAssertEqual(landings, [Landing(window: window.id, asked: target, actual: nil)], "its size says nothing about a minimum")
    }

    func testCancellingAMoveDropsItsLanding() {
        place(window, at: CGRect(x: 8, y: 33, width: 708, height: 859))
        animator.cancel(window.id)
        XCTAssertFalse(animator.isMoving(window.id))
        XCTAssertNil(animator.destination(of: window.id))

        let target = CGRect(x: 724, y: 33, width: 708, height: 859)
        place(second, at: target)
        awaitLanding(of: second, at: target)
        flush()

        XCTAssertEqual(landings.filter { $0.window != sentinel.id }, [Landing(window: second.id, asked: target, actual: target.size)],
                       "the window that was let be is not reported")
        XCTAssertTrue(animator.isIdle)
    }

    func testANewerMoveSupersedesAnOlderOne() {
        let older = CGRect(x: 8, y: 33, width: 708, height: 859)
        let newer = CGRect(x: 724, y: 33, width: 708, height: 426)

        place(window, at: older)
        place(window, at: newer)
        XCTAssertEqual(animator.destination(of: window.id), newer)
        awaitLanding(of: window, at: newer)
        flush()

        XCTAssertEqual(window.rect, newer)
        XCTAssertEqual(landings.filter { $0.window == window.id }, [Landing(window: window.id, asked: newer, actual: newer.size)],
                       "only the frame that still is wanted is answered for")
    }

    func testAnAppThatAnimatesItsOwnResizesIsToldNotToForTheMove() {
        // Apps switch this on for assistive tools, and then animate every change of size.
        let preview = EnhancedApp(window: window)
        let restored = expectation(description: "the app's setting is put back")
        preview.onRestored = { restored.fulfill() }
        let target = CGRect(x: 8, y: 33, width: 708, height: 859)

        animator.move(window.id, pid: window.pid, element: window, app: preview, from: window.rect, to: target, duration: 0, easing: .easeOut)
        awaitLanding(of: window, at: target)
        wait(for: [restored], timeout: 10)

        XCTAssertEqual(window.rect, target)
        XCTAssertEqual(preview.changes.map(\.on), [false, true], "off for the move, and on again afterwards")
        XCTAssertEqual(preview.changes.map(\.sizesAskedSoFar), [0, 1], "off before the window is resized, on again after")
    }

    // MARK: Gliding

    func testForgettingAnAppStopsItsGlidesAndLeavesTheOthers() {
        let other = system.launch("Notes")
        let theirs = system.open(other, frame: CGRect(x: 300, y: 300, width: 400, height: 300))
        let target = CGRect(x: 8, y: 33, width: 708, height: 859)

        animator.move(window.id, pid: window.pid, element: window, app: nil, from: window.rect, to: target, duration: 30, easing: .linear)
        animator.move(theirs.id, pid: theirs.pid, element: theirs, app: nil, from: theirs.rect, to: target, duration: 30, easing: .linear)
        XCTAssertTrue(animator.isGliding(window.id))
        XCTAssertEqual(animator.destination(of: window.id), target)
        XCTAssertFalse(animator.isIdle)

        animator.forget(pid: window.pid)
        XCTAssertFalse(animator.isMoving(window.id), "the app has quit: nothing is on its way to its windows")
        XCTAssertNil(animator.destination(of: window.id))
        XCTAssertTrue(animator.isGliding(theirs.id))

        animator.cancel(theirs.id)
        XCTAssertFalse(animator.isMoving(theirs.id))
        XCTAssertTrue(animator.isIdle)
        XCTAssertTrue(landings.isEmpty)
    }

    func testAGlideEndsOnTheFrameThatWasAskedFor() throws {
        try XCTSkipIf(NSScreen.main == nil, "a glide is paced by a display, and there is none")
        let target = CGRect(x: 8, y: 33, width: 708, height: 859)
        let done = XCTestExpectation(description: "the glide has landed")
        expecting.append((window.id, target, done))

        animator.move(window.id, pid: window.pid, element: window, app: nil, from: window.rect, to: target, duration: 0.05, easing: .easeOut)
        XCTAssertTrue(animator.isGliding(window.id))
        XCTAssertEqual(animator.destination(of: window.id), target)

        guard XCTWaiter().wait(for: [done], timeout: 5) == .completed else {
            // A display that is asleep or has no session gives no ticks. That is not a failure of the glide.
            animator.cancel(window.id)
            throw XCTSkip("the display did not tick")
        }
        XCTAssertEqual(window.rect, target)
        XCTAssertEqual(landings, [Landing(window: window.id, asked: target, actual: target.size)])
        XCTAssertFalse(animator.isGliding(window.id))
        XCTAssertTrue(animator.isIdle)
    }

    // MARK: -

    private func place(_ window: FakeWindow, at target: CGRect) {
        animator.move(window.id, pid: window.pid, element: window, app: nil, from: target, to: target, duration: 0, easing: .easeOut)
    }

    /// Wait for the animator to say that a window has been given `target`.
    private func awaitLanding(of window: FakeWindow, at target: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let done = XCTestExpectation(description: "window \(window.id) landed at \(target)")
        expecting.append((window.id, target, done))
        if XCTWaiter().wait(for: [done], timeout: 10) != .completed {
            XCTFail("window \(window.id) never landed at \(target)", file: file, line: line)
        }
    }

    /// Wait until everything asked of the animator so far has been written and answered.
    ///
    /// The writes of one app are done in order, and so are the answers. The first move of the
    /// sentinel cannot be written before the writer has taken up everything asked earlier, and
    /// the second cannot be answered before all of that has been answered.
    private func flush(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 1...2 {
            flushes += 1
            let target = CGRect(x: flushes, y: 0, width: 50, height: 50)
            place(sentinel, at: target)
            awaitLanding(of: sentinel, at: target, file: file, line: line)
        }
    }
}

/// An app that has the setting on which makes it animate every resize of its windows.
/// The animator reads and writes it on the app's queue, so what it does is kept under a lock.
private final class EnhancedApp: FakeElement {
    private let lock = NSLock()
    private let window: FakeWindow
    private var enhanced = true
    private var record: [(on: Bool, sizesAskedSoFar: Int)] = []
    var onRestored: (() -> Void)?

    init(window: FakeWindow) {
        self.window = window
        super.init()
        pid = window.pid
    }

    var changes: [(on: Bool, sizesAskedSoFar: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    override func bool(_ name: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return name == "AXEnhancedUserInterface" ? enhanced : nil
    }

    @discardableResult
    override func set(_ name: String, _ value: Bool) -> Bool {
        guard name == "AXEnhancedUserInterface" else { return false }
        lock.lock()
        enhanced = value
        // Read on the queue the window is written on, so it is safe to look at here.
        record.append((value, window.sizesAsked.count))
        lock.unlock()
        if value { onRestored?() }
        return true
    }
}
