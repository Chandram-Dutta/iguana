import AppKit
import ApplicationServices
import IguanaCore

/// Runs the commands of `[hooks]` when the desktop being shown or the focused window changes,
/// and tells the clients of `iguana subscribe`.
///
/// `changed` is the one place events come from. It is called after every refresh of the
/// window manager, by the same `onChange` that redraws the menu bar item, so it hears about a
/// change however it came about: a shortcut, a gesture, Mission Control, a click. Whether
/// anything really changed is decided by `HookTracker` in IguanaCore.
final class Hooks {
    private var tracker = HookTracker()
    private let runner = HookRunner()
    /// Set at the first look, once tiling has started. A subscriber that came before that is
    /// sent the current state then.
    private var started = false

    func changed(_ wm: WindowManager) {
        let showing = wm.displays.map { HookTracker.Showing(display: $0.uuid, space: $0.spaceKey, desktop: $0.desktopNumber) }
        // The tracker is kept up to date even while no hook is set, so that one added later
        // starts from what is on screen and not from what was there when Iguana started.
        let changes = tracker.observe(showing: showing, focused: wm.focusedWindow)
        if !started {
            started = true
            for subscriber in IPC.subscribers { greet(subscriber, wm) }
        }
        for change in changes {
            switch change {
            case .desktop(let uuid):
                announce(.desktopChanged, wm) { wm.displays.first { $0.uuid == uuid }.map(desktopVariables) }
            case .focus(let id):
                announce(.focusChanged, wm) { focusVariables(id, wm) }
            }
        }
    }

    /// Every event passes here: its hook runs, if one is set, and the subscribers that asked
    /// for it are told. The variables are worked out only when someone is there to hear them,
    /// since a window's title is a question to its app.
    private func announce(_ event: HookEvent, _ wm: WindowManager, _ variables: () -> [String: String]?) {
        let command = wm.config.hooks[event]
        guard command != nil || IPC.wants(event), let variables = variables() else { return }
        if let command { runner.fire(event, command: command, variables: variables) }
        IPC.broadcast(event, variables)
    }

    /// A new subscriber is first told what is true now, as if it had just happened, so that a
    /// status bar can draw at once: what each display shows, then the focus.
    func greet(_ subscriber: IPC.Subscriber, _ wm: WindowManager) {
        guard started else { return }
        for display in wm.displays { subscriber.send(.desktopChanged, desktopVariables(display)) }
        if subscriber.events.contains(.focusChanged) { subscriber.send(.focusChanged, focusVariables(wm.focusedWindow, wm)) }
    }

    private func desktopVariables(_ display: DisplayInfo) -> [String: String] {
        HookEnvironment.variables(event: .desktopChanged, desktop: display.desktopNumber, display: display.name)
    }

    private func focusVariables(_ id: CGWindowID?, _ wm: WindowManager) -> [String: String] {
        let facts = wm.facts()
        guard let id else {
            // No window has the focus: say where the user is.
            return HookEnvironment.variables(event: .focusChanged, desktop: facts.activeDisplay?.desktopNumber,
                                             display: facts.activeDisplay?.name)
        }
        let app: String, title: String
        if let w = facts.windows[id] {
            app = facts.apps[w.pid]?.app.localizedName ?? ""
            title = w.element.string(kAXTitleAttribute) ?? ""
        } else {
            // A window Iguana has not looked at yet. It belongs to the app in front.
            app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            title = ""
        }
        let place = wm.place(of: id, frame: ScreenSnapshot.take().onScreen[id])
        return HookEnvironment.variables(event: .focusChanged, desktop: place.desktop, display: place.display ?? facts.activeDisplay?.name,
                                         window: (id, app, title))
    }
}

/// Starts the command of a hook with `/bin/sh -c` and never waits for it: the command is
/// started off the main thread, and its end is reported back by the system.
///
/// The facts go to the command as environment variables. They are never put into the command
/// text, because a window title can be any text at all.
///
/// One run of each hook at a time. An event that fires while its hook is still running does not
/// start a second copy: the newest one waits for the run to end and the ones in between are
/// dropped, so a slow command cannot pile up and a status bar still ends on the latest state.
final class HookRunner {
    private struct Run {
        let command: String
        let token: Int
        /// Kept until it ends, so that its end is always reported.
        let process: Process
        /// The variables of the newest event that fired during this run.
        var next: [String: String]?
    }

    private var runs: [HookEvent: Run] = [:]
    private var lastCommand: [HookEvent: String] = [:]
    /// What has been written to the log already. Each kind of trouble is logged once for a command.
    private var logged = Set<String>()
    private var tokens = 0
    private let launcher = DispatchQueue(label: "xyz.onlychan.iguana.hooks", qos: .utility)
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = Log.write) {
        self.log = log
    }

    /// No command that this runner still waits to hear the end of.
    var isIdle: Bool { runs.isEmpty }

    /// Call on the main thread. Returns at once.
    func fire(_ event: HookEvent, command: String, variables: [String: String]) {
        if lastCommand[event] != command {
            // The config changed. A run of the old command is left to finish by itself and no
            // longer holds up the new one, and trouble with the new one is news again.
            lastCommand[event] = command
            runs[event] = nil
            logged = logged.filter { !$0.hasPrefix(event.rawValue + " ") }
        }
        if runs[event] != nil {
            runs[event]?.next = variables
            logOnce(event, "busy", "its last run has not ended, so the newest change waits for it and the changes in between are skipped")
            return
        }
        start(event, command, variables)
    }

    private func start(_ event: HookEvent, _ command: String, _ variables: [String: String]) {
        tokens += 1
        let token = tokens
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = HookEnvironment.merged(inherited: ProcessInfo.processInfo.environment, variables: variables)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // A hook has no terminal: it reads nothing, and what it prints goes nowhere.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus, killed = ended.terminationReason == .uncaughtSignal
            DispatchQueue.main.async { self?.ended(event, token, status: status, killed: killed) }
        }
        runs[event] = Run(command: command, token: token, process: process, next: nil)
        launcher.async { [weak self] in
            do {
                try process.run()
            } catch {
                let reason = error.localizedDescription
                DispatchQueue.main.async { self?.couldNotStart(event, token, reason) }
            }
        }
    }

    private func ended(_ event: HookEvent, _ token: Int, status: Int32, killed: Bool) {
        // A run of a command that the config has since replaced is nobody's business any more.
        guard let run = runs[event], run.token == token else { return }
        runs[event] = nil
        if killed {
            logOnce(event, "failed", "the command was stopped by signal \(status)")
        } else if status != 0 {
            let hint = status == 127 ? " (the shell could not find the command: give its full path)" : ""
            logOnce(event, "failed", "the command ended with status \(status)\(hint)")
        }
        if let next = run.next { start(event, run.command, next) }
    }

    private func couldNotStart(_ event: HookEvent, _ token: Int, _ reason: String) {
        guard let run = runs[event], run.token == token else { return }
        // What was waiting would not start either. The next event tries again.
        runs[event] = nil
        logOnce(event, "start", "the command could not be started: \(reason)")
    }

    private func logOnce(_ event: HookEvent, _ kind: String, _ message: String) {
        guard logged.insert("\(event.rawValue) \(kind)").inserted else { return }
        log("hook \(event.rawValue): \(message) (logged once)")
    }
}
