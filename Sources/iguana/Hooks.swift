import AppKit
import ApplicationServices
import IguanaCore

/// Runs the commands of `[hooks]` when something changes: the desktop being shown, the focused
/// window, a window opening or closing, the arrangement of a desktop, or the pause.
///
/// `changed` is the one place hooks are fired from. It is called after every refresh of the
/// window manager, by the same `onChange` that redraws the menu bar item, so it hears about a
/// change however it came about: a shortcut, a gesture, Mission Control, a click. Whether
/// anything really changed is decided by `HookTracker` in IguanaCore, and every event goes out
/// through `emit`.
final class Hooks {
    private var tracker = HookTracker()
    private let runner = HookRunner()

    func changed(_ wm: WindowManager) {
        let facts = wm.facts()
        var places: (desktops: [Desktop], onScreen: [CGWindowID: CGRect])?
        /// What a hook is told about a window. Asked once for each window, when it is first seen.
        func describe(_ id: CGWindowID) -> HookTracker.Window {
            if places == nil { places = (Desktop.all(), ScreenSnapshot.take().onScreen) }
            let w = facts.windows[id]
            let place = wm.place(of: id, frame: places?.onScreen[id], desktops: places?.desktops ?? [])
            return HookTracker.Window(id: id, app: w.flatMap { facts.apps[$0.pid]?.app.localizedName } ?? "",
                                      title: w?.element.string(kAXTitleAttribute) ?? "", desktop: place.desktop, display: place.display)
        }
        // A title changes while the window is in use. The window in front is looked at again,
        // so that one that closes is described as the user last saw it.
        if wants(.windowClosed, wm), let id = wm.focusedWindow, facts.windows[id]?.tileable == true {
            tracker.remember(describe(id))
        }
        var arrangements: [String: HookTracker.Arrangement] = [:]
        for d in wm.displays where d.isDesktop {
            guard let tree = facts.trees[d.treeKey] else { continue }
            arrangements[d.uuid] = HookTracker.Arrangement(layout: tree.snapshot, visible: facts.visible.intersection(tree.windows),
                                                           zoomed: facts.zoomed[d.treeKey])
        }
        let look = HookTracker.Look(
            showing: wm.displays.map { HookTracker.Showing(display: $0.uuid, space: $0.spaceKey, desktop: $0.desktopNumber) },
            focused: wm.focusedWindow, paused: wm.paused, existing: facts.existing,
            standard: Set(facts.windows.values.filter(\.tileable).map(\.id)), arrangements: arrangements)
        // The tracker is kept up to date even while no hook is set, so that one added later
        // starts from what is on screen and not from what was there when Iguana started.
        for change in tracker.observe(look, describe: describe) {
            switch change {
            case .desktop(let uuid):
                shown(.desktopChanged, on: uuid, wm)
            case .layout(let uuid):
                shown(.layoutChanged, on: uuid, wm)
            case .paused(let paused):
                emit(.pauseChanged, wm) { HookEnvironment.variables(event: .pauseChanged, paused: paused) }
            case .created(let window):
                emit(.windowCreated, wm) { HookEnvironment.variables(event: .windowCreated, window: window) }
            case .closed(let window):
                emit(.windowClosed, wm) { HookEnvironment.variables(event: .windowClosed, window: window) }
            case .focus(let id):
                // The title is only asked for when there is a command to hand it to.
                emit(.focusChanged, wm) { focusVariables(id, wm) }
            }
        }
    }

    /// Whether anything listens for this event. What only such a listener needs is not worked out otherwise.
    private func wants(_ event: HookEvent, _ wm: WindowManager) -> Bool {
        wm.config.hooks[event] != nil
    }

    /// The one place an event goes out: it happened, and these are its variables. They are
    /// only worked out when something listens.
    private func emit(_ event: HookEvent, _ wm: WindowManager, _ variables: () -> [String: String]) {
        guard wants(event, wm) else { return }
        let variables = variables()
        if let command = wm.config.hooks[event] { runner.fire(event, command: command, variables: variables) }
    }

    /// An event about what one display is showing.
    private func shown(_ event: HookEvent, on uuid: String, _ wm: WindowManager) {
        guard let display = wm.displays.first(where: { $0.uuid == uuid }) else { return }
        emit(event, wm) { HookEnvironment.variables(event: event, desktop: display.desktopNumber, display: display.name) }
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
