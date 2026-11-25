import CoreGraphics
import Foundation
import IguanaCore
@testable import iguana

/// Time that passes only when a test says so.
///
/// Work the window manager puts off (`after`) waits in a queue. `advance(by:)` and
/// `runUntilIdle()` run it in the order it falls due, moving the clock as they go, so a test
/// sees exactly what the window manager would do over the next half second without waiting
/// for it.
final class FakeScheduler: Scheduler {
    private struct Job {
        let due: Date
        let order: Int
        let body: () -> Void
    }

    private(set) var now = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private var jobs: [Job] = []
    private var count = 0
    /// `after` can be called from another thread: the real `Animator` writes to a window on
    /// a queue of its own, and the made-up window then says that it moved.
    private let lock = NSLock()

    /// How much work is waiting.
    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        jobs.append(Job(due: now.addingTimeInterval(max(0, delay)), order: count, body: body))
    }

    /// A blocking wait moves the clock and runs nothing, as the real one does.
    func sleep(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    /// Let `seconds` pass, running everything that falls due in that time, in order.
    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = nextJob(before: end) {
            if next.due > now { now = next.due }
            next.body()
        }
        if end > now { now = end }
    }

    /// Run until nothing is waiting. Work that keeps putting off more work stops after
    /// `limit` seconds on this clock, and the test is told through the return value.
    @discardableResult
    func runUntilIdle(limit: TimeInterval = 60) -> Bool {
        let end = now.addingTimeInterval(limit)
        while let next = nextJob(before: end) {
            if next.due > now { now = next.due }
            next.body()
        }
        return pending == 0
    }

    private func nextJob(before end: Date) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = jobs.indices.min(by: { (jobs[$0].due, jobs[$0].order) < (jobs[$1].due, jobs[$1].order) }),
              jobs[index].due <= end else { return nil }
        return jobs.remove(at: index)
    }
}

/// Puts every window in its place at once, the way `Animator` does at the end of a glide, and
/// keeps a record of what was asked.
final class ImmediateMover: FrameMover {
    struct Move: Equatable {
        let window: CGWindowID
        let from: CGRect
        let to: CGRect
        /// More than zero for a move that would have been a glide.
        let duration: Double
    }

    private let scheduler: FakeScheduler
    private var landing: [CGWindowID: CGRect] = [:]
    private var owners: [CGWindowID: pid_t] = [:]

    var onLanded: ((CGWindowID, CGRect, CGSize?) -> Void)?
    /// Every move asked for, oldest first.
    private(set) var moves: [Move] = []
    private(set) var cancelled: [CGWindowID] = []
    private(set) var forgotten: [pid_t] = []

    init(scheduler: FakeScheduler) {
        self.scheduler = scheduler
    }

    func destination(of id: CGWindowID) -> CGRect? { landing[id] }
    func isMoving(_ id: CGWindowID) -> Bool { landing[id] != nil }
    func isGliding(_ id: CGWindowID) -> Bool { false }

    func move(_ id: CGWindowID, pid: pid_t, element: UIElement, app: UIElement?, from: CGRect, to: CGRect, duration: Double, easing: Easing) {
        moves.append(Move(window: id, from: from, to: to, duration: duration))
        owners[id] = pid
        landing[id] = to
        element.setPosition(to.origin)
        let sized = element.setSize(to.size)
        element.setPosition(to.origin)
        // The app answers a moment later, on the main thread.
        scheduler.after(0) { [weak self] in
            guard let self, self.landing[id] == to else { return }
            self.landing[id] = nil
            self.onLanded?(id, to, sized ? element.size : nil)
        }
    }

    func cancel(_ id: CGWindowID) {
        cancelled.append(id)
        landing[id] = nil
    }

    func forget(pid: pid_t) {
        forgotten.append(pid)
        for (id, owner) in owners where owner == pid { landing[id] = nil }
    }

    /// Forget the record, to look only at what a later step asks for.
    func clearRecord() {
        moves.removeAll()
        cancelled.removeAll()
    }
}
