import AppKit
import ApplicationServices
import IguanaCore

/// Keeps a tiling tree for every native Space and lays out the windows that are on screen.
///
/// The rule that makes it cooperate with macOS: Iguana only ever sets the frame of windows the
/// system is showing right now. It never hides, parks or moves a window to make a "workspace".
/// Spaces, Mission Control, Stage Manager, fullscreen and minimising stay the system's business.
final class WindowManager {
    /// The Mac, or what stands in for it in a test. Everything this class learns about the
    /// windows of other apps, and everything it does to them, goes through here.
    let system: WindowSystem
    let scheduler: Scheduler
    let mover: FrameMover
    let store: StateStore
    /// Where the config file is.
    let configURL: () -> URL
    let tracker: AppTracker
    let carrier: SpaceCarrier

    private(set) var config = Config.default
    private(set) var configWarnings: [String] = []
    var onChange: (() -> Void)?
    /// Iguana moved the pointer itself (`mouse-follows-focus`), and where to.
    var onPointerWarp: ((CGPoint) -> Void)?
    var onConfigChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenTour: (() -> Void)?
    /// Opens the window switcher and answers the command, supplied by the app shell.
    var onOpenSwitcher: (() -> String)?
    var onCheckForUpdate: (() -> Void)?
    /// The shortcuts in use: `default` for `[bindings]`, or the name of a `[mode.NAME]` table.
    private(set) var mode = Config.defaultMode
    /// The mode changed, so the app shell registers its shortcuts.
    var onModeChange: (() -> Void)?
    /// Extra lines for `status`, supplied by the app shell.
    var statusExtras: (() -> [String])?
    /// A window says it moved or changed size, for the focus ring. No refresh follows while
    /// the user drags a window, so `onChange` alone would not tell.
    var onFrameChange: ((UIElement) -> Void)?

    // What the window manager knows. These are not private, so that the extensions in the
    // other files of this folder can share them, but nothing outside this folder changes
    // them: the rest of the app reads through `facts()` and the other members of
    // `WindowManager+Shell.swift`.

    var windows: [CGWindowID: WindowState] = [:]
    var trees: [String: Tree] = [:]
    var zoomed: [String: CGWindowID] = [:]
    /// Set by `split`: how the next window that opens beside this one splits its tile. Used once.
    var splitHints: [CGWindowID: Orientation] = [:]
    /// Where each visible tiled window belongs according to its tree.
    var slots: [CGWindowID: CGRect] = [:]
    /// What was actually applied (differs from `slots` for a zoomed window).
    var lastFrames: [CGWindowID: CGRect] = [:]
    var lastVisible = Set<CGWindowID>()
    /// Every window the system had at the last refresh, on any Space.
    var lastExisting = Set<CGWindowID>()
    private(set) var displays: [DisplayInfo] = []
    var dirtyApps = Set<pid_t>()
    var allDirty = true
    private(set) var paused = false
    var refreshPending = false
    var focusedWindow: CGWindowID? {
        didSet { if let id = focusedWindow, id != oldValue { focusHistory.record(id) } }
    }
    /// The windows that had the focus, for `focus recent`, `focus-app` and the switcher.
    private(set) var focusHistory = FocusHistory()
    /// The desktops each display showed, for `space recent`.
    var desktopHistory = DesktopHistory()
    var focusIntent: CGWindowID?
    /// Counts the focus requests, so that the check of an earlier request cannot speak for a
    /// later one for the same window.
    var focusSerial = 0
    /// `carried` is set once the window has been seen somewhere else at its own size: it is
    /// being moved, not resized, and stays a move whatever happens to its size afterwards.
    var drag: (id: CGWindowID, start: CGRect, carried: Bool)?
    var started = false
    var restoredFloating = Set<CGWindowID>()
    /// Windows the last run had tiled by hand, until this run has seen them.
    var restoredTiled = Set<CGWindowID>()
    var restoredMinSizes: [CGWindowID: CGSize] = [:]
    /// After a restart of the Mac: the saved layouts, waiting for their windows to come back.
    var restore = RestoreSession()
    /// What the windows in the layouts were when last saved, for those that are not on screen.
    var savedWindows: [CGWindowID: WindowDescriptor] = [:]
    /// Windows whose minimum size comes from the last run and has not been checked in this one.
    var unverifiedMinimums = Set<CGWindowID>()
    /// How many times a save has been asked for. Only the last of a run is written.
    var saveRequests = 0
    var lastConfigLog = ""
    /// Windows that joined a layout in this refresh. They are placed at once; the rest glide.
    var justAdopted = Set<CGWindowID>()
    /// The next refresh places windows at once (arriving on a desktop, first layout).
    var instantNext = true
    /// How often a stack has been put in order since it last was in order or the user last did something.
    var stackOrderTries = 0
    let desktopRules: DesktopRules
    /// The user's changes to each layout, for `undo` and `redo`. Kept until Iguana quits.
    var history = LayoutHistory()
    var isRecording = false
    var placementRules = PlacementRuleQueue()
    /// Windows that are in no layout on their way to a place, and where each goes instead if it
    /// will not take the size it was given.
    var placing: [CGWindowID: (asked: CGRect, fit: (CGSize) -> CGRect)] = [:]
    let displayRules: DisplayRules

    /// A drag of a tiled window by hand began (true) or ended (false). The outline that shows
    /// where the window will land is drawn for as long as it lasts.
    var onDrag: ((Bool) -> Void)?

    /// A window `sendWindow` moved that the window server has not caught up with yet.
    var inTransit: [CGWindowID: (display: Int, deadline: Date)] = [:]

    // MARK: Lifecycle

    init(system: WindowSystem = MacWindowSystem(), mover: FrameMover = Animator(), scheduler: Scheduler = MainQueueScheduler(),
         store: StateStore = .standard, configURL: @escaping () -> URL = { Iguana.configURL }) {
        self.system = system
        self.mover = mover
        self.scheduler = scheduler
        self.store = store
        self.configURL = configURL
        tracker = AppTracker(system: system, scheduler: scheduler)
        carrier = SpaceCarrier(system: system, scheduler: scheduler)
        desktopRules = DesktopRules(system: system, scheduler: scheduler)
        displayRules = DisplayRules(system: system, scheduler: scheduler)
        tracker.onNotification = { [weak self] element, notification in self?.handle(element: element, notification: notification) }
        tracker.onRetry = { [weak self] pid in
            self?.dirtyApps.insert(pid)
            self?.scheduleRefresh()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        loadState()
        mover.onLanded = { [weak self] id, asked, actual in self?.landed(id, asked: asked, actual: actual) }
        system.start { [weak self] event in self?.handle(event) }
        for a in system.runningApps() { track(a) }
        scheduleRefresh()
    }

    private func handle(_ event: SystemEvent) {
        switch event {
        case .launched(let app):
            if let app { track(app) }
            scheduleRefresh()
        case .terminated(let app):
            if let app { untrack(app.processIdentifier) }
            scheduleRefresh()
        case .activated(let app):
            // An app can turn into a regular app after launch, so look again when it comes forward.
            if let app {
                track(app)
                dirtyApps.insert(app.processIdentifier)
            }
            scheduleRefresh()
        case .visibilityChanged:
            scheduleRefresh()
        case .spaceChanged:
            spaceChanged()
        case .leftMouseUp:
            mouseUp()
        }
    }

    private func spaceChanged() {
        allDirty = true
        instantNext = true
        scheduleRefresh(after: 0.05)
        // Look once more when the switch animation has finished.
        scheduler.after(0.6) { [weak self] in
            self?.allDirty = true
            self?.instantNext = true
            self?.scheduleRefresh()
        }
    }

    // MARK: Apps and events

    var apps: [pid_t: AppState] { tracker.apps }

    private func track(_ app: RunningApp) {
        if tracker.track(app) { dirtyApps.insert(app.processIdentifier) }
    }

    private func untrack(_ pid: pid_t) {
        if tracker.untrack(pid) { mover.forget(pid: pid) }
    }

    private func handle(element: UIElement, notification: String) {
        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            frameChanged(element)
            onFrameChange?(element)
        case kAXUIElementDestroyedNotification:
            scheduleRefresh()
            // The window server drops a closing window a moment after its app says it is gone,
            // so the first refresh can still see it and keep its slot. Look again shortly after;
            // scheduleRefresh coalesces, so this only costs one or two extra passes.
            for delay in [0.3, 1.0] {
                scheduler.after(delay) { [weak self] in
                    self?.scheduleRefresh()
                }
            }
        default:
            dirtyApps.insert(element.pid)
            scheduleRefresh()
        }
    }

    /// Ask the system which displays there are and what each is showing.
    func lookAtDisplays() {
        displays = system.displays()
    }

    // MARK: Refresh

    func scheduleRefresh(after delay: TimeInterval = 0.03) {
        guard started, !refreshPending else { return }
        refreshPending = true
        scheduler.after(delay) { [weak self] in self?.refresh() }
    }

    /// Bring the trees in line with what is on screen, then put every visible tiled window in its slot.
    func refresh() {
        refreshPending = false
        guard started, system.isTrusted else { return }

        let pids = allDirty ? Array(apps.keys) : Array(dirtyApps)
        allDirty = false
        dirtyApps.removeAll()
        for pid in pids { if let state = apps[pid] { enumerate(state) } }
        // On the display it opened on, before a rule can send it to another desktop.
        applyPlacementRules()
        // Before the layout, so a window that a rule sends away never takes a tile here first.
        applyDesktopRules()
        applyDisplayRules()

        let snap = system.snapshot()
        prune(existing: snap.all)
        lastExisting = snap.all
        lookAtDisplays()
        noteDesktops()
        updateFocus(snap)

        guard !paused else {
            onChange?()
            return
        }

        let (frames, newSlots) = layoutAll(snap)
        // A desktop whose windows have all gone has nothing left to undo.
        for (key, tree) in trees where tree.isEmpty { history.forget(key: key) }
        apply(frames, snap, animated: !instantNext)
        instantNext = false
        slots = newSlots
        lastFrames = frames
        lastVisible = Set(frames.keys)
        orderStack(snap)
        scheduleSave()
        onChange?()
    }

    func prune(existing: Set<CGWindowID>) {
        for id in windows.keys where !existing.contains(id) {
            mover.cancel(id)
            placing[id] = nil
            inTransit[id] = nil
            windows[id] = nil
            lastFrames[id] = nil
            slots[id] = nil
        }
        for tree in trees.values { tree.prune { existing.contains($0) } }
        for (key, id) in zoomed where !existing.contains(id) { zoomed[key] = nil }
        // A window that closed or left the layout takes its hint with it.
        splitHints = splitHints.filter { id, _ in trees.values.contains { $0.contains(id) } }
        if let waiting = focusIntent, !existing.contains(waiting) { focusIntent = nil }
        if let f = focusedWindow, !existing.contains(f) { focusedWindow = nil }
        for id in focusHistory.windows where !existing.contains(id) { focusHistory.forget(id) }
    }

    /// Put the shortcuts of another mode in place of the current ones.
    @discardableResult
    func switchMode(_ name: String) -> String {
        guard config.bindings(inMode: name) != nil else { return "error: no mode '\(name)'" }
        guard name != mode else { return "ok" }
        mode = name
        onModeChange?()
        return "ok"
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        instantNext = false
        refresh()
    }

    @discardableResult
    func reloadConfig() -> String {
        let url = configURL()
        let modes = config.modes
        var reply: String
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            do {
                (config, configWarnings) = try Config.load(text)
                reply = configWarnings.isEmpty ? "ok: loaded \(url.path)" : "ok: loaded \(url.path) with warnings:\n" + configWarnings.map { "  - \($0)" }.joined(separator: "\n")
            } catch {
                configWarnings = ["\(error)"]
                reply = "error: \(url.path): \(error)\n(keeping the previous settings)"
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            // There is a file, but not one that can be read: say so, and do not treat it as absent.
            configWarnings = ["the config file cannot be read as UTF-8 text"]
            reply = "error: \(url.path) cannot be read as UTF-8 text\n(keeping the previous settings)"
        } else {
            config = .default
            configWarnings = []
            reply = "ok: no config file at \(url.path), using the built-in defaults (`iguana config init` writes one)"
        }
        // Dragging a slider in the settings window reloads many times a second; log what is new.
        if reply != lastConfigLog {
            lastConfigLog = reply
            Log.write("config: \(reply)")
        }
        // A rule sends a window to its desktop when the window appears. Those that are open now stay.
        desktopRules.markExisting()
        placementRules.markExisting(system.snapshot().all)
        displayRules.markExisting()
        applyFloatRules()
        // A mode that is gone, or whose keys changed, is left rather than half kept.
        if config.modes[mode] != modes[mode] { switchMode(Config.defaultMode) }
        onConfigChange?()
        if started { refresh() }
        return reply
    }
}
