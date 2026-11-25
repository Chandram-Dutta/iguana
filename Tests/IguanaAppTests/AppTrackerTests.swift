import ApplicationServices
import XCTest
@testable import iguana

/// `AppTracker` on its own: which apps it watches, and how it keeps asking one that has only
/// just launched.
final class AppTrackerTests: XCTestCase {
    private var scheduler: FakeScheduler!
    private var system: FakeWindowSystem!
    private var tracker: AppTracker!
    /// What the apps said, oldest first: the window it was about, and the notification.
    private var heard: [String] = []
    private var retried: [pid_t] = []

    override func setUp() {
        super.setUp()
        scheduler = FakeScheduler()
        system = FakeWindowSystem(scheduler: scheduler)
        system.addDisplay()
        tracker = AppTracker(system: system, scheduler: scheduler)
        heard = []
        retried = []
        tracker.onNotification = { [weak self] element, notification in
            self?.heard.append("\(element.windowID.map { "\($0)" } ?? "app") \(notification)")
        }
        tracker.onRetry = { [weak self] pid in self?.retried.append(pid) }
    }

    override func tearDown() {
        tracker = nil
        system = nil
        scheduler = nil
        super.tearDown()
    }

    func testAnAppWithADockIconIsWatched() {
        let notes = system.launch("Notes")
        XCTAssertTrue(tracker.track(notes))
        XCTAssertEqual(Array(tracker.apps.keys), [notes.processIdentifier])
        XCTAssertTrue(tracker.apps[notes.processIdentifier]?.app === notes)
        XCTAssertFalse(tracker.track(notes), "watched already")
        XCTAssertEqual(tracker.apps.count, 1)

        let window = system.open(notes)
        system.minimise(window)
        scheduler.runUntilIdle()

        XCTAssertEqual(heard, ["\(window.id) \(kAXWindowCreatedNotification)", "\(window.id) \(kAXWindowMiniaturizedNotification)"])
        XCTAssertTrue(retried.isEmpty, "each thing it said was heard once, and it was ready the first time")
    }

    func testAnAppWithoutADockIconIsNotWatched() {
        let helper = system.launch("Helper", regular: false)
        XCTAssertFalse(tracker.track(helper))
        XCTAssertTrue(tracker.apps.isEmpty)

        system.open(helper)
        scheduler.runUntilIdle()
        XCTAssertTrue(heard.isEmpty)
    }

    func testIguanaItselfIsNotWatched() {
        let itself = FakeApp(pid: getpid(), name: "Iguana", bundleID: "com.example.iguana", system: system)
        XCTAssertFalse(tracker.track(itself))
        // An app that has gone has no process to ask.
        let gone = FakeApp(pid: -1, name: "Gone", bundleID: nil, system: system)
        XCTAssertFalse(tracker.track(gone))
        XCTAssertTrue(tracker.apps.isEmpty)
        XCTAssertEqual(scheduler.pending, 0)
    }

    func testAnAppThatIsNoLongerWatchedIsNotHeard() {
        let notes = system.launch("Notes")
        let safari = system.launch("Safari")
        tracker.track(notes)
        tracker.track(safari)

        XCTAssertTrue(tracker.untrack(notes.processIdentifier))
        XCTAssertFalse(tracker.untrack(notes.processIdentifier), "it was not watched any more")
        XCTAssertFalse(tracker.untrack(4), "nor was this one, ever")
        XCTAssertEqual(Array(tracker.apps.keys), [safari.processIdentifier])

        system.open(notes)
        let kept = system.open(safari)
        scheduler.runUntilIdle()
        XCTAssertEqual(heard, ["\(kept.id) \(kAXWindowCreatedNotification)"], "only the app still watched")
    }

    func testAnAppThatIsNotReadyIsAskedAgainEveryHalfSecondTenTimes() {
        let slow = system.launch("Slow")
        slow.readyToBeObserved = false
        XCTAssertTrue(tracker.track(slow), "watched all the same: its windows can be listed")

        scheduler.advance(by: 0.49)
        XCTAssertTrue(retried.isEmpty)
        scheduler.advance(by: 0.02)
        XCTAssertEqual(retried, [slow.processIdentifier])
        scheduler.advance(by: 2)
        XCTAssertEqual(retried.count, 5)

        scheduler.advance(by: 60)
        XCTAssertEqual(retried.count, 10, "then it is left alone")
        XCTAssertEqual(scheduler.pending, 0)

        // Too late: it is ready now, and nobody asks.
        slow.readyToBeObserved = true
        system.open(slow)
        scheduler.runUntilIdle()
        XCTAssertTrue(heard.isEmpty)
    }

    func testAnAppThatBecomesReadyIsHeardFromThen() {
        let slow = system.launch("Slow")
        slow.readyToBeObserved = false
        tracker.track(slow)
        let missed = system.open(slow)
        scheduler.advance(by: 1.2)
        XCTAssertEqual(retried.count, 2)
        XCTAssertTrue(heard.isEmpty, "the window that opened meanwhile was not announced")

        slow.readyToBeObserved = true
        scheduler.advance(by: 0.5)
        XCTAssertEqual(retried.count, 3, "the retry that worked is reported too, so that windows like that one are looked for")

        let window = system.open(slow)
        scheduler.advance(by: 60)
        XCTAssertEqual(heard, ["\(window.id) \(kAXWindowCreatedNotification)"])
        XCTAssertNotEqual(window.id, missed.id)
        XCTAssertEqual(retried.count, 3, "and it is not asked again")
    }

    func testAnAppThatQuitsIsNotAskedAgain() {
        let slow = system.launch("Slow")
        slow.readyToBeObserved = false
        tracker.track(slow)
        scheduler.advance(by: 0.6)
        XCTAssertEqual(retried.count, 1)

        tracker.untrack(slow.processIdentifier)
        scheduler.advance(by: 60)
        XCTAssertEqual(retried.count, 1)
        XCTAssertEqual(scheduler.pending, 0)

        // Watched again, it is asked from the start, and only by the new watch.
        tracker.track(slow)
        tracker.untrack(slow.processIdentifier)
        tracker.track(slow)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(retried.count, 2)
        scheduler.advance(by: 60)
        XCTAssertEqual(retried.count, 11)
    }
}
