import AppKit
import IguanaCore

/// A rule can name a desktop for the windows it matches. This is the app's side of it: it
/// tells the queue which windows the system has, asks where a new window is, and writes to
/// the log what was done. Which windows are new, and what to do with one, is decided in
/// IguanaCore (`DesktopRuleQueue`, `DesktopRuleAction`).
final class DesktopRules {
    private let system: WindowSystem
    private let scheduler: Scheduler
    private var queue = DesktopRuleQueue()
    private var saidCannotStay = false

    init(system: WindowSystem, scheduler: Scheduler) {
        self.system = system
        self.scheduler = scheduler
    }

    /// Every window the system has, on any desktop.
    private func everyWindow() -> Set<CGWindowID> {
        Set(system.windowOwners().keys)
    }

    /// Called when the config is read: the windows that are open now stay where they are.
    func markExisting() {
        queue.markExisting(everyWindow())
    }

    /// A window Iguana sees for the first time, matched by a rule that names a desktop.
    func note(_ id: CGWindowID, desktop: Int, app: String?) {
        queue.note(id, desktop: desktop, app: app ?? "an app", at: scheduler.now)
    }

    /// Deal with the windows that are waiting. `standard` says whether a window is a standard
    /// one, and nil when it is gone or is not one to send at all; `send` moves it and answers
    /// as the `move-to-space` command does.
    func settle(paused: Bool, standard: (CGWindowID) -> Bool?, send: (CGWindowID, Int) -> String) {
        guard queue.hasLooked else { return queue.firstLook(existing: everyWindow()) }
        let due = queue.due(at: scheduler.now, paused: paused, standard: standard)
        guard !due.isEmpty else { return }

        let desktops = system.desktops()
        for entry in due {
            let on = system.spaces(of: entry.window)
            let action = DesktopRuleAction.decide(wanted: entry.desktop, standardWindow: true,
                                                  windowDesktops: desktops.filter { on.contains($0.id) }.map(\.number),
                                                  desktopCount: desktops.count, canStay: system.hasMoveBridge)
            let window = "window \(entry.window) of \(entry.app)"
            switch action {
            case .leave:
                break
            case .send(let n):
                let reply = send(entry.window, n)
                if reply == "ok" {
                    Log.write("rule: sent \(window) to desktop \(n)")
                } else if reply.hasPrefix("error: ") {
                    Log.write("rule: \(window) was not sent to desktop \(n): \(reply.dropFirst(7))")
                }
            case .missing:
                Log.write("rule: \(window) was not sent to desktop \(entry.desktop): there are only \(desktops.count) desktops")
            case .cannotStay:
                // This is the same for every window, so it is said once.
                guard !saidCannotStay else { break }
                saidCannotStay = true
                Log.write("rule: this macOS can only take a window to another desktop by going there with it, so rules with a desktop are not applied")
            }
        }
    }
}
