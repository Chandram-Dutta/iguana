import Foundation

/// The window manager's sense of time: what the time is, and doing something a little later.
///
/// Much of what it does is waiting: for an app to answer, for a Space to change, for a window
/// to land. Going through this, a test can let that time pass at once and in a known order.
protocol Scheduler: AnyObject {
    var now: Date { get }
    /// Run `body` on the main thread after `delay` seconds.
    func after(_ delay: TimeInterval, _ body: @escaping () -> Void)
    /// Block for a moment. Only for waits of a few milliseconds.
    func sleep(_ seconds: TimeInterval)
}

final class MainQueueScheduler: Scheduler {
    var now: Date { Date() }

    func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    func sleep(_ seconds: TimeInterval) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}
