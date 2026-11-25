import AppKit
import IguanaCore

/// A rule can name a display for the windows it matches. This is the app's side of it, as
/// `DesktopRules` is for desktops: it tells the queue which windows the system has and writes
/// to the log what was done. Which windows are new, and where one goes, is decided in
/// IguanaCore (`DisplayRuleQueue`, `DisplayRuleAction`).
final class DisplayRules {
    private let system: WindowSystem
    private let scheduler: Scheduler
    private var queue = DisplayRuleQueue()
    /// Rules whose display was not there, with that display. Each is reported once.
    private var saidMissing = Set<String>()

    init(system: WindowSystem, scheduler: Scheduler) {
        self.system = system
        self.scheduler = scheduler
    }

    /// Called when the config is read: the windows that are open now stay where they are.
    func markExisting() {
        queue.markExisting(system.snapshot().all)
    }

    /// A window Iguana sees for the first time, matched by rule number `rule`, which names a display.
    func note(_ id: CGWindowID, display: DisplayRef, rule: Int, app: String?) {
        queue.note(id, display: display, rule: rule, app: app ?? "an app", at: scheduler.now)
    }

    /// Deal with the windows that are waiting.
    /// - Parameters:
    ///   - standard: whether a window is a standard one, nil when it is gone or is not one to send at all.
    ///   - displays: the displays as they are now. Asked only when a window is due.
    ///   - location: the position in those displays of the one a window is on.
    ///   - send: moves a window to the display at a position, and answers as a command does.
    func settle(paused: Bool, standard: (CGWindowID) -> Bool?, displays: () -> [DisplayInfo],
                location: (CGWindowID) -> Int?, send: (CGWindowID, Int) -> String) {
        guard queue.hasLooked else { return queue.firstLook(existing: system.snapshot().all) }
        let due = queue.due(at: scheduler.now, paused: paused, standard: standard)
        guard !due.isEmpty else { return }

        let displays = displays()
        let numbers = DisplayOrder.numbers(displays.map(\.frame))
        for entry in due {
            let action = DisplayRuleAction.decide(wanted: entry.display, standardWindow: true, windowDisplay: location(entry.window),
                                                  names: displays.map(\.name), frames: displays.map(\.frame))
            let window = "window \(entry.window) of \(entry.app)"
            switch action {
            case .leave:
                break
            case .send(let i):
                let there = "display \(numbers[i]) (\(displays[i].name))"
                let reply = send(entry.window, i)
                if reply == "ok" {
                    Log.write("rule: sent \(window) to \(there)")
                } else if reply.hasPrefix("error: ") {
                    Log.write("rule: \(window) was not sent to \(there): \(reply.dropFirst(7))")
                }
            case .missing:
                // A display that is not connected stays so for a while: say it once.
                guard saidMissing.insert("\(entry.rule) \(entry.display)").inserted else { break }
                Log.write("rule \(entry.rule): \(window) was not sent to display \(entry.display): no such display is connected (said once for this rule)")
            }
        }
    }
}
