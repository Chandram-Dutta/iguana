import AppKit
import ApplicationServices
import IguanaCore

final class WindowState {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    /// A standard window that can be moved and resized. Dialogs, sheets and fixed-size windows are left alone.
    var tileable: Bool
    var ruleFloat = false
    var userFloat: Bool?
    /// The frame Iguana last asked for, used to tell its own changes from the user's.
    var lastSetFrame: CGRect?
    /// Learned when a window refuses to get as small as its slot.
    var minSize: CGSize?

    var floating: Bool { userFloat ?? ruleFloat }

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, tileable: Bool) {
        self.id = id
        self.pid = pid
        self.element = element
        self.tileable = tileable
    }
}

final class AppState {
    let app: NSRunningApplication
    let element: AXUIElement
    var observer: AXObserver?
    var attempts = 0

    init(app: NSRunningApplication) {
        self.app = app
        element = AXUIElementCreateApplication(app.processIdentifier)
        // An app that is busy must never be able to stall the window manager.
        AXUIElementSetMessagingTimeout(element, 0.4)
    }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
        .handle(element: element, notification: notification as String)
}

/// Keeps a tiling tree for every native Space and lays out the windows that are on screen.
///
/// The rule that makes it cooperate with macOS: Iguana only ever sets the frame of windows the
/// system is showing right now. It never hides, parks or moves a window to make a "workspace".
/// Spaces, Mission Control, Stage Manager, fullscreen and minimising stay the system's business.
final class WindowManager {
    static let version = "0.2.1"

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
    var onFrameChange: ((AXUIElement) -> Void)?

    private var apps: [pid_t: AppState] = [:]
    private var windows: [CGWindowID: WindowState] = [:]
    private var trees: [String: Tree] = [:]
    private var zoomed: [String: CGWindowID] = [:]
    /// Set by `split`: how the next window that opens beside this one splits its tile. Used once.
    private var splitHints: [CGWindowID: Orientation] = [:]
    /// Where each visible tiled window belongs according to its tree.
    private var slots: [CGWindowID: CGRect] = [:]
    /// What was actually applied (differs from `slots` for a zoomed window).
    private var lastFrames: [CGWindowID: CGRect] = [:]
    private var lastVisible = Set<CGWindowID>()
    /// Every window the system had at the last refresh, on any Space.
    private var lastExisting = Set<CGWindowID>()
    private(set) var displays: [DisplayInfo] = []
    private var dirtyApps = Set<pid_t>()
    private var allDirty = true
    private(set) var paused = false
    private var refreshPending = false
    private(set) var focusedWindow: CGWindowID? {
        didSet { if let id = focusedWindow, id != oldValue { focusHistory.record(id) } }
    }
    /// The windows that had the focus, for `focus recent`, `focus-app` and the switcher.
    private(set) var focusHistory = FocusHistory()
    /// The desktops each display showed, for `space recent`.
    private var desktopHistory = DesktopHistory()
    private var focusIntent: CGWindowID?
    /// `carried` is set once the window has been seen somewhere else at its own size: it is
    /// being moved, not resized, and stays a move whatever happens to its size afterwards.
    private var drag: (id: CGWindowID, start: CGRect, carried: Bool)?
    private var syntheticDrag = false
    private var started = false
    private var restoredFloating = Set<CGWindowID>()
    private var restoredMinSizes: [CGWindowID: CGSize] = [:]
    /// After a restart of the Mac: the saved layouts, waiting for their windows to come back.
    private var restore = RestoreSession()
    /// What the windows in the layouts were when last saved, for those that are not on screen.
    private var savedWindows: [CGWindowID: WindowDescriptor] = [:]
    /// Windows whose minimum size comes from the last run and has not been checked in this one.
    private var unverifiedMinimums = Set<CGWindowID>()
    private var saveWork: DispatchWorkItem?
    private var lastConfigLog = ""
    private let animator = Animator()
    /// Windows that joined a layout in this refresh. They are placed at once; the rest glide.
    private var justAdopted = Set<CGWindowID>()
    /// The next refresh places windows at once (arriving on a desktop, first layout).
    private var instantNext = true
    /// How often a stack has been put in order since it last was in order or the user last did something.
    private var stackOrderTries = 0
    private let desktopRules = DesktopRules()
    /// The user's changes to each layout, for `undo` and `redo`. Kept until Iguana quits.
    private var history = LayoutHistory()
    private var isRecording = false
    private var placementRules = PlacementRuleQueue()
    /// Floating windows on their way to a place, and where each goes instead if it will not take
    /// the size it was given.
    private var placing: [CGWindowID: (asked: CGRect, fit: (CGSize) -> CGRect)] = [:]
    private let displayRules = DisplayRules()

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        // An app that is busy must never be able to stall the window manager. Set on the
        // system-wide element, this is the limit for every accessibility call this process makes;
        // set on an app's element it would cover that element only, and not its windows.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)
        loadState()
        animator.onLanded = { [weak self] id, asked, actual in self?.landed(id, asked: asked, actual: actual) }

        let workspace = NSWorkspace.shared.notificationCenter
        func app(_ n: Notification) -> NSRunningApplication? {
            n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n) { self?.track(a) }
            self?.scheduleRefresh()
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n) { self?.untrack(a.processIdentifier) }
            self?.scheduleRefresh()
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            // An app can turn into a regular app after launch, so look again when it comes forward.
            if let a = app(n) {
                self?.track(a)
                self?.dirtyApps.insert(a.processIdentifier)
            }
            self?.scheduleRefresh()
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() }
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }

        for a in NSWorkspace.shared.runningApplications { track(a) }
        scheduleRefresh()
    }

    private func spaceChanged() {
        allDirty = true
        instantNext = true
        scheduleRefresh(after: 0.05)
        // Look once more when the switch animation has finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.allDirty = true
            self?.instantNext = true
            self?.scheduleRefresh()
        }
    }

    // MARK: Apps and events

    private func track(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, pid != getpid(), app.activationPolicy == .regular, apps[pid] == nil else { return }
        let state = AppState(app: app)
        apps[pid] = state
        observe(state)
        dirtyApps.insert(pid)
    }

    private func untrack(_ pid: pid_t) {
        guard let state = apps.removeValue(forKey: pid) else { return }
        animator.forget(pid: pid)
        if let o = state.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        }
    }

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]

    private func observe(_ state: AppState) {
        let pid = state.app.processIdentifier
        if state.observer == nil {
            var o: AXObserver?
            if AXObserverCreate(pid, axCallback, &o) == .success, let o {
                state.observer = o
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            }
        }
        var complete = state.observer != nil
        if let o = state.observer {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for n in Self.appNotifications {
                let e = AXObserverAddNotification(o, state.element, n as CFString, refcon)
                if e != .success && e != .notificationAlreadyRegistered && e != .notificationUnsupported { complete = false }
            }
        }
        // A freshly launched app often is not ready to be observed yet.
        if !complete, state.attempts < 10 {
            state.attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak state] in
                guard let self, let state, self.apps[pid] === state else { return }
                self.observe(state)
                self.dirtyApps.insert(pid)
                self.scheduleRefresh()
            }
        }
    }

    fileprivate func handle(element: AXUIElement, notification: String) {
        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            frameChanged(element)
            onFrameChange?(element)
        case kAXUIElementDestroyedNotification:
            scheduleRefresh()
        default:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            dirtyApps.insert(pid)
            scheduleRefresh()
        }
    }

    private var mouseIsDown: Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }

    private func frameChanged(_ element: AXUIElement) {
        guard !syntheticDrag, !paused, let id = Private.windowID(of: element), let w = windows[id],
              let slot = lastFrames[id] else { return }
        // Frames reported while Iguana itself is moving the window are its own.
        if animator.isMoving(id), !mouseIsDown { return }
        guard let now = element.frame else { return }
        if let asked = w.lastSetFrame, nearlyEqual(now, asked) { return }
        if mouseIsDown, !animator.isMoving(id) {
            // The user is dragging or resizing. Leave the window alone until they let go.
            if drag == nil {
                // What the window started from is its tile, at the size it really had there: a
                // window that will not get as small as its tile is bigger than it, and that
                // difference is not the user resizing it.
                var start = slot
                if let least = w.minSize {
                    start.size.width = max(start.width, least.width)
                    start.size.height = max(start.height, least.height)
                }
                drag = (id, start, false)
                onDrag?(true)
            }
            if drag?.id == id, drag?.carried == false, let start = drag?.start, DragDrop.isMove(from: start, to: now) { drag?.carried = true }
            return
        }
        if mouseIsDown { return }
        scheduleRefresh(after: 0.1)
    }

    private func mouseUp() {
        stackOrderTries = 0
        guard let d = drag else { return }
        drag = nil
        onDrag?(false)
        var wait = 0.0
        defer { scheduleRefresh(after: wait) }
        guard let w = windows[d.id], let now = w.element.frame, let (key, tree) = treeEntry(containing: d.id) else { return }
        w.lastSetFrame = nil
        let dw = now.width - d.start.width, dh = now.height - d.start.height
        // A window that was carried somewhere can come back from the drag with another size:
        // macOS's own tiling resizes a window let go at a screen edge. That is not the user
        // resizing it, so it must not change the proportions of the layout.
        if !d.carried, abs(dw) > 3 || abs(dh) > 3 {
            // Resized by hand: keep the new proportions.
            recording {
                if abs(dw) > 3 { tree.changeShare(of: d.id, along: .horizontal, .ratio(Double(now.width / d.start.width)), visible: lastVisible) }
                if abs(dh) > 3 { tree.changeShare(of: d.id, along: .vertical, .ratio(Double(now.height / d.start.height)), visible: lastVisible) }
            }
            restore.stop(key)
        } else if let cursor = CGEvent(source: nil)?.location,
                  // The same question the outline asked all through the drag (DragPreview.swift),
                  // so what it showed is what is done: trade places, take half of a tile, join a stack.
                  let plan = dropPlan(dragging: d.id, from: d.start, now: d.carried ? CGRect(origin: now.origin, size: d.start.size) : now, at: cursor) {
            recording { DragDrop.carryOut(plan.drop, of: d.id, in: displays.compactMap { trees[$0.treeKey] }, visible: lastVisible) }
            restore.stop(key)
            if let there = treeEntry(containing: d.id)?.0 { restore.stop(there) }
            if displayIndex(for: now) != displayIndex(for: plan.rect) {
                // Let go with most of itself on another display than the one it lands on. A
                // layout is made of the windows on its display, so the window is put there first.
                w.element.setSize(plan.rect.size)
                w.element.setPosition(plan.rect.origin)
                wait = 0.05
            }
        }
    }

    /// A drag of a tiled window by hand began (true) or ended (false). The outline that shows
    /// where the window will land is drawn for as long as it lasts.
    var onDrag: ((Bool) -> Void)?

    /// The window the user is dragging or resizing by hand, and the tile it started from.
    var dragging: (id: CGWindowID, start: CGRect)? { drag.map { ($0.id, $0.start) } }

    /// The tile of every tiled window on screen. A zoomed window is not on its tile, and has none here.
    var tileFrames: [CGWindowID: CGRect] { lastFrames.filter { !zoomed.values.contains($0.key) } }

    // MARK: Refresh

    func scheduleRefresh(after delay: TimeInterval = 0.03) {
        guard started, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    /// Bring the trees in line with what is on screen, then put every visible tiled window in its slot.
    func refresh() {
        refreshPending = false
        guard started, AXIsProcessTrusted() else { return }

        let pids = allDirty ? Array(apps.keys) : Array(dirtyApps)
        allDirty = false
        dirtyApps.removeAll()
        for pid in pids { if let state = apps[pid] { enumerate(state) } }
        // On the display it opened on, before a rule can send it to another desktop.
        applyPlacementRules()
        // Before the layout, so a window that a rule sends away never takes a tile here first.
        applyDesktopRules()
        applyDisplayRules()

        let snap = ScreenSnapshot.take()
        prune(existing: snap.all)
        lastExisting = snap.all
        displays = DisplayInfo.current()
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

    /// The windows of a stack overlap, and which of them is above which decides whether each one
    /// still shows its strip. Raise the ones that are out of order, the focused window last.
    /// Nothing is hidden or moved for this; the windows only change places front to back.
    private func orderStack(_ snap: ScreenSnapshot) {
        guard drag == nil, let id = focusedWindow, lastFrames[id] != nil, let (_, tree) = treeEntry(containing: id) else { return }
        let raise = tree.stackRaiseOrder(focused: id, frontToBack: snap.order, visible: lastVisible)
        guard !raise.isEmpty else {
            stackOrderTries = 0
            return
        }
        // Raising a window can itself cause a refresh, and an app can answer a raise in ways of
        // its own. Three tries without the stack coming right, and it is left alone until the
        // user does something, so that this can never go round in circles.
        guard stackOrderTries < 3 else { return }
        stackOrderTries += 1
        if stackOrderTries == 3 { Log.write("stack: raising \(raise) twice did not put the stack around window \(id) in order; trying once more, then leaving it") }
        for other in raise { if let w = windows[other] { AXUIElementPerformAction(w.element, kAXRaiseAction as CFString) } }
        // Raising another window of the same app can make that one the app's main window.
        windows[id]?.element.set(kAXMainAttribute, true)
    }

    private func enumerate(_ state: AppState) {
        guard let list = state.element.elements(kAXWindowsAttribute) else { return }
        let pid = state.app.processIdentifier
        var fresh: [WindowState] = []
        for el in list {
            guard let id = Private.windowID(of: el) else { continue }
            if let known = windows[id] {
                // A window can be reported before it has settled into its final role.
                if !known.tileable { known.tileable = Self.isTileable(el) }
                continue
            }
            // A window in native fullscreen cannot be resized. Pick it up when it comes back.
            if el.bool("AXFullScreen") == true { continue }
            let w = WindowState(id: id, pid: pid, element: el, tileable: Self.isTileable(el))
            let decides = rule(for: w, app: state.app)
            w.ruleFloat = decides?.floats ?? false
            if let n = decides?.desktop { desktopRules.note(id, desktop: n, app: state.app.localizedName) }
            if let decides {
                placementRules.note(id, rule: decides, app: state.app.localizedName ?? "an app", at: Date())
                if let d = decides.display {
                    displayRules.note(id, display: d, rule: (config.rules.firstIndex(of: decides) ?? 0) + 1, app: state.app.localizedName)
                }
            }
            if restoredFloating.remove(id) != nil { w.userFloat = true }
            if let size = restoredMinSizes.removeValue(forKey: id) {
                w.minSize = size
                unverifiedMinimums.insert(id)
            }
            windows[id] = w
            fresh.append(w)
            if let o = state.observer {
                AXObserverAddNotification(o, el, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        refloat(fresh, app: state.app)
    }

    private static func isTileable(_ el: AXUIElement) -> Bool {
        el.string(kAXRoleAttribute) == kAXWindowRole
            && el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && el.isSettable(kAXSizeAttribute) && el.isSettable(kAXPositionAttribute)
    }

    private func matchesFloatRule(_ w: WindowState, app: NSRunningApplication) -> Bool {
        rule(for: w, app: app)?.floats ?? false
    }

    private func rule(for w: WindowState, app: NSRunningApplication) -> Rule? {
        guard !config.rules.isEmpty else { return nil }
        let title = config.rules.contains { $0.title != nil } ? w.element.string(kAXTitleAttribute) : nil
        // The first rule that matches decides, so `float = false` can carve an exception out of a later rule.
        return config.rule(bundleID: app.bundleIdentifier, appName: app.localizedName, title: title)
    }

    /// A rule can name a desktop. A new window it matches is sent there once, exactly as
    /// `move-to-space N --stay` sends the focused window, and the user stays where they are.
    private func applyDesktopRules() {
        desktopRules.settle(paused: paused, standard: ruleStandard) { id, n in
            guard let w = windows[id] else { return "error: the window is gone" }
            let front = systemFocusedWindow()
            let hadKeyboard = front == id || (front == nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid)
            let before = focusedWindow
            let position = w.element.position
            let reply = moveToSpace(.index(n), follow: false, ruled: id)
            if reply == "ok", hadKeyboard {
                // The keyboard goes back to the window that had it before this one opened.
                let snap = ScreenSnapshot.take()
                let candidates = [before].compactMap { $0 } + snap.order
                if let next = candidates.first(where: { $0 != id && windows[$0] != nil && isShowing($0, snap) }) { focus(window: next) }
            } else if reply.hasPrefix("error"), let position {
                // Aiming at a desktop on another display moves the window there first. It did not go, so put it back.
                w.element.setPosition(position)
            }
            return reply
        }
    }

    /// A rule can name a display. A new window it matches is moved there once, onto the desktop
    /// that display is showing, and the user stays on the desktop they are using.
    private func applyDisplayRules() {
        displayRules.settle(paused: paused, standard: ruleStandard, displays: {
            displays = DisplayInfo.current()
            return displays
        }, location: { id in windows[id]?.element.frame.flatMap(displayIndex(for:)) }) { id, index in
            sendWindow(id, toDisplay: index)
        }
    }

    /// Whether a new window a rule waits for is a standard one yet. Nil when it is gone, or is a
    /// tab, which stays with its window.
    private func ruleStandard(_ id: CGWindowID) -> Bool? {
        guard let w = windows[id] else { return nil }
        guard w.tileable, let frame = w.element.frame else { return false }
        return isTab(w, frame) ? nil : true
    }

    /// A new native tab is a window of its own, with the frame of the window it is a tab of and
    /// on the same desktop. It stays with that window, wherever the user has it.
    private func isTab(_ w: WindowState, _ frame: CGRect) -> Bool {
        let spaces = Private.spaces(of: w.id)
        return windows.values.contains { other in
            other.pid == w.pid && other.id != w.id
                && (spaces.isEmpty || Private.spaces(of: other.id).contains(where: spaces.contains))
                && other.element.frame.map { nearlyEqual($0, frame) } == true
        }
    }

    private func display(holding w: WindowState) -> DisplayInfo? {
        w.element.frame.flatMap { displayIndex(for: $0) }.map { displays[$0] }
    }

    private func prune(existing: Set<CGWindowID>) {
        for id in windows.keys where !existing.contains(id) {
            animator.cancel(id)
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

    private func isShowing(_ id: CGWindowID, _ snap: ScreenSnapshot) -> Bool {
        guard snap.onScreen[id] != nil else { return false }
        let spaces = Private.spaces(of: id)
        return spaces.isEmpty || spaces.contains { s in displays.contains { $0.spaceID == s } }
    }

    private func updateFocus(_ snap: ScreenSnapshot) {
        // While a focus request is still being confirmed, the request is the truth.
        guard focusIntent == nil else { return }
        var id = systemFocusedWindow()
        // An app whose key window lives on another Space still reports that window as focused.
        // What the user can act on is its frontmost window on the Space being shown.
        if let reported = id, !isShowing(reported, snap) {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            id = snap.order.first { windows[$0]?.pid == pid && isShowing($0, snap) }
        }
        // Nothing focused at all (the desktop was clicked, or the front app has no window here):
        // act on the window that is in front.
        if id == nil { id = snap.order.first { windows[$0] != nil && isShowing($0, snap) } }
        guard let id else {
            if let old = focusedWindow, !isShowing(old, snap) { focusedWindow = nil }
            return
        }
        focusedWindow = id
        for tree in trees.values where tree.contains(id) { tree.focused = id }
    }

    private func displayIndex(for rect: CGRect) -> Int? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let i = displays.firstIndex(where: { $0.frame.contains(center) }) { return i }
        var best: (Int, CGFloat)?
        for (i, d) in displays.enumerated() {
            let overlap = d.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.1 ?? 0) { best = (i, area) }
        }
        return best?.0
    }

    private func treeEntry(containing id: CGWindowID) -> (String, Tree)? {
        // Prefer the tree of a Space that is showing.
        for d in displays { if let t = trees[d.treeKey], t.contains(id) { return (d.treeKey, t) } }
        for (key, t) in trees where t.contains(id) { return (key, t) }
        return nil
    }

    private var minSizes: [CGWindowID: CGSize] {
        var m: [CGWindowID: CGSize] = [:]
        for (id, w) in windows { if let s = w.minSize { m[id] = s } }
        return m
    }

    private func layoutAll(_ snap: ScreenSnapshot) -> (frames: [CGWindowID: CGRect], slots: [CGWindowID: CGRect]) {
        var frames: [CGWindowID: CGRect] = [:]
        var allSlots: [CGWindowID: CGRect] = [:]
        var byDisplay: [Int: [WindowState]] = [:]
        for w in windows.values where w.tileable && !w.floating {
            // A window a rule just sent to another display is still where it was, briefly:
            // it is not adopted anywhere until the move shows.
            guard inTransit[w.id] == nil else { continue }
            guard let rect = snap.onScreen[w.id], let i = displayIndex(for: rect) else { continue }
            // While macOS slides from one Space to the next, the windows of both are on screen.
            // Only the ones that really live on the Space being shown belong in its layout.
            let spaces = Private.spaces(of: w.id)
            guard spaces.isEmpty || spaces.contains(displays[i].spaceID) else { continue }
            byDisplay[i, default: []].append(w)
        }
        for (i, d) in displays.enumerated() where d.isDesktop {
            let here = (byDisplay[i] ?? []).sorted { $0.id < $1.id }
            let ids = Set(here.map(\.id))
            let usable = d.usableFrame(config), gap = d.settings(config).inner
            let key = d.treeKey
            // After a restart of the Mac, the desktop takes its saved shape again as its windows come back.
            restoreLayout(d, here, snap, usable: usable, gap: gap)
            let tree: Tree
            if let t = trees[key] {
                tree = t
            } else {
                tree = Tree(orientation: usable.width >= usable.height ? .horizontal : .vertical)
                trees[key] = tree
            }
            for w in here where !tree.contains(w.id) {
                adopt(w, into: tree, key: key, visible: ids, usable: usable, gap: gap)
            }
            if let z = zoomed[key], !ids.contains(z) { zoomed[key] = nil }
            // A minimum remembered from the last run is checked the first time it would shape a layout.
            let doubtful = ids.intersection(unverifiedMinimums)
            if !doubtful.isEmpty {
                unverifiedMinimums.subtract(doubtful)
                recheckMinimums(in: tree, key: key, visible: ids, usable: usable, gap: gap, only: doubtful)
            }
            let computed = computeLayout(tree, in: usable, gap: gap, visible: ids, minSizes: minSizes, peek: config.stackPeek)
            allSlots.merge(computed) { a, _ in a }
            var applied = computed
            if let z = zoomed[key] { applied[z] = usable }
            frames.merge(applied) { a, _ in a }
        }
        return (frames, allSlots)
    }

    private func adopt(_ w: WindowState, into tree: Tree, key: String, visible: Set<CGWindowID>, usable: CGRect, gap: Double) {
        for (k, other) in trees where k != key { other.remove(w.id) }
        justAdopted.insert(w.id)
        splitHints[w.id] = nil

        // A window that takes the place of another window of the same app (a native tab coming
        // forward) inherits its slot instead of opening a new one.
        if let twin = tree.windows.first(where: { lastVisible.contains($0) && !visible.contains($0) && windows[$0]?.pid == w.pid }) {
            tree.insert(w.id, after: twin, sameSlot: true)
            return
        }

        let preferred = [tree.focused, focusedWindow].compactMap { $0 }
        let anchor = preferred.first { $0 != w.id && visible.contains($0) && tree.contains($0) }
            ?? tree.windows.last { visible.contains($0) }
        var split: Orientation?
        if let anchor, let hint = splitHints.removeValue(forKey: anchor) {
            split = hint
        } else if config.autoSplit, let anchor,
                  let f = computeLayout(tree, in: usable, gap: gap, visible: visible)[anchor] {
            split = f.width >= f.height ? .horizontal : .vertical
        }
        tree.insert(w.id, after: anchor, split: split)
        tree.focused = w.id
    }

    /// Send every window to its frame. Windows glide there unless the change is tiny, the window
    /// has only just joined the layout, or motion is switched off.
    private func apply(_ frames: [CGWindowID: CGRect], _ snap: ScreenSnapshot, animated: Bool) {
        let glide = animated && config.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (id, target) in frames {
            guard let w = windows[id], drag?.id != id else { continue }
            w.lastSetFrame = target
            if let heading = animator.destination(of: id), nearlyEqual(heading, target, tolerance: 0.5) { continue }
            let current = snap.onScreen[id]
            if let current, nearlyEqual(current, target), !animator.isMoving(id) { continue }
            var duration = 0.0
            if glide, let current, !justAdopted.contains(id) {
                let change = max(abs(current.minX - target.minX), abs(current.minY - target.minY),
                                 abs(current.width - target.width), abs(current.height - target.height))
                if change > 12 { duration = config.animationDuration }
            }
            animator.move(id, pid: w.pid, element: w.element, app: apps[w.pid]?.element,
                          from: current ?? target, to: target, duration: duration, easing: config.animationEasing)
        }
        justAdopted.removeAll()
    }

    /// A window has been given its final frame. If it came out bigger than asked, it may have a
    /// minimum size. A busy window can also answer with the size it had before, so ask once
    /// more and believe only what it still says a moment later.
    private func landed(_ id: CGWindowID, asked: CGRect, actual: CGSize?) {
        if let placed = placing.removeValue(forKey: id), placed.asked == asked {
            return placedLanded(id, asked: asked, actual: actual, fit: placed.fit)
        }
        guard let w = windows[id], let actual, !zoomed.values.contains(id) else { return }
        let known = w.minSize ?? .zero
        guard (actual.width > asked.width + 2 && actual.width > known.width)
            || (actual.height > asked.height + 2 && actual.height > known.height) else { return }
        w.element.setSize(asked.size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.confirmMinimum(id, asked: asked) }
    }

    /// The window still is bigger than it was asked to be: remember that and lay out again around it.
    private func confirmMinimum(_ id: CGWindowID, asked: CGRect) {
        guard let w = windows[id], !zoomed.values.contains(id), !animator.isMoving(id), drag?.id != id,
              let wanted = w.lastSetFrame, nearlyEqual(wanted, asked), let actual = w.element.size else { return }
        var m = w.minSize ?? .zero
        var changed = false
        if actual.width > asked.width + 2, actual.width > m.width {
            m.width = actual.width
            changed = true
        }
        if actual.height > asked.height + 2, actual.height > m.height {
            m.height = actual.height
            changed = true
        }
        if changed {
            w.minSize = m
            scheduleRefresh(after: 0)
        }
    }

    /// A minimum size is something Iguana once saw, and what it saw can be wrong or out of date.
    /// When the user asks for a change of sizes, every window that the layout holds at its minimum
    /// is asked for the size it would have without one. One that takes it had no such minimum.
    private func recheckMinimums(in tree: Tree, key: String) {
        guard let display = displays.first(where: { $0.isDesktop && $0.treeKey == key }) else { return }
        recheckMinimums(in: tree, key: key, visible: lastVisible.filter { tree.contains($0) },
                        usable: display.usableFrame(config), gap: display.settings(config).inner)
    }

    private func recheckMinimums(in tree: Tree, key: String, visible ids: Set<CGWindowID>, usable: CGRect, gap: Double, only: Set<CGWindowID>? = nil) {
        let free = computeLayout(tree, in: usable, gap: gap, visible: ids, peek: config.stackPeek)
        for (id, slot) in free where only?.contains(id) != false {
            guard let w = windows[id], var m = w.minSize, zoomed[key] != id else { continue }
            let wide = m.width > slot.width + 2, tall = m.height > slot.height + 2
            guard wide || tall, let now = w.element.size else { continue }
            let ask = CGSize(width: wide ? slot.width : now.width, height: tall ? slot.height : now.height)
            guard w.element.setSize(ask), let got = w.element.size else { continue }
            if wide { m.width = got.width > ask.width + 2 ? got.width : 0 }
            if tall { m.height = got.height > ask.height + 2 ? got.height : 0 }
            w.minSize = m.width > 0 || m.height > 0 ? m : nil
        }
    }

    // MARK: Commands

    /// `window` is the one a request named with `--window`. The command acts on it as it would
    /// on the focused window, and the focus stays where it is. Nil means the focused window.
    func run(_ command: Command, window: CGWindowID? = nil) -> String {
        stackOrderTries = 0
        if started, AXIsProcessTrusted() {
            displays = DisplayInfo.current()
            updateFocus(ScreenSnapshot.take())
        }
        // These work before the permission is granted, so the app can always be inspected and stopped.
        switch command {
        case .status: return status()
        case .reload: return reloadConfig()
        case .settings:
            onOpenSettings?()
            return "ok"
        case .tour:
            onOpenTour?()
            return "ok"
        case .update:
            // From the command line the app shell answers this one itself, once GitHub has
            // answered. A shortcut has nowhere to print an answer: it starts the check, and
            // what is found appears in the menu.
            onCheckForUpdate?()
            return "ok: checking"
        case .quit:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return "ok"
        // Without the permission there must still be a way out of a mode.
        case .mode(let name): return switchMode(name)
        // Each command of a chain asks for the permission itself.
        case .sequence(let commands): return Command.runChain(commands) { self.run($0) }
        default: break
        }
        guard AXIsProcessTrusted() else {
            return "error: Iguana needs Accessibility permission (System Settings > Privacy & Security > Accessibility)"
        }
        if let window, windows[window] == nil { return "error: no window \(window)" }
        switch command {
        case .focus(let dir): return focus(dir)
        case .focusWindow:
            guard let window else { return "error: 'focus' needs one of: left, right, up, down" }
            focusWindow(window)
            return "ok"
        case .focusRecent: return focusRecent()
        case .move(let dir): return recording { move(dir, window) }
        case .join(let dir):
            return recording { withTile(window) { id, tree, _ in
                tree.join(id, with: dir, visible: lastVisible) ? "ok" : "ok: no neighbour in that direction"
            } }
        case .resize(let axis, let grow):
            return recording { withTile(window) { id, tree, key in
                // Start from the sizes on screen, which differ from the weights where a window is
                // held at its minimum size.
                tree.matchWeights(to: slots, visible: lastVisible)
                guard tree.changeShare(of: id, along: axis, .delta(Double(grow) * config.resizeStep), visible: lastVisible) else {
                    return "ok: nothing to resize against"
                }
                recheckMinimums(in: tree, key: key)
                return "ok"
            } }
        case .flip:
            return recording { withTile(window) { id, tree, _ in tree.flip(id) ? "ok" : "error: cannot flip" } }
        case .stack:
            return recording { withTile(window) { id, tree, _ in
                guard let stacked = tree.toggleStack(id) else { return "ok: no other window to stack with" }
                return stacked ? "ok: stacked" : "ok: unstacked"
            } }
        case .balance:
            return recording { withTile(window) { _, tree, key in
                tree.balance()
                recheckMinimums(in: tree, key: key)
                return "ok"
            } }
        case .split(let hint):
            return withTile(window) { id, tree, _ in
                if hint != nil, tree.newWindowJoinsStack(beside: id) {
                    splitHints[id] = nil
                    return "ok: new windows join the stack this window is in"
                }
                splitHints[id] = hint
                switch hint {
                case .horizontal: return "ok: the next window opens beside it"
                case .vertical: return "ok: the next window opens below it"
                case nil: return "ok: automatic"
                }
            }
        case .arrange(let arrangement):
            return recording { withTile(window) { id, tree, key in
                let shown = tree.windows.filter { lastVisible.contains($0) }
                guard shown.count > 1 || arrangement == .main else { return "ok: nothing to arrange" }
                tree.arrange(arrangement, order: readingOrder(slots.filter { shown.contains($0.key) }), main: id,
                             hidden: tree.windows.filter { !lastVisible.contains($0) })
                zoomed[key] = nil
                recheckMinimums(in: tree, key: key)
                return "ok"
            } }
        case .zoom:
            return withTile(window) { id, _, key in
                zoomed[key] = zoomed[key] == id ? nil : id
                if let w = windows[id] { AXUIElementPerformAction(w.element, kAXRaiseAction as CFString) }
                return "ok"
            }
        case .float:
            guard let w = targetWindow(window) else { return "error: no focused window" }
            guard w.tileable else { return "error: this window cannot be tiled" }
            if let key = treeEntry(containing: w.id)?.0 ?? display(holding: w)?.treeKey { restore.stop(key) }
            w.userFloat = !w.floating
            if w.floating { for tree in trees.values { tree.remove(w.id) } }
            refresh()
            return w.floating ? "ok: floating" : "ok: tiled"
        case .place(let placement): return place(placement, window)
        case .switcher: return onOpenSwitcher?() ?? "ok"
        case .close:
            guard let w = targetWindow(window) else { return "error: no focused window" }
            guard let button = w.element.element(kAXCloseButtonAttribute) else { return "error: this window has no close button" }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return "ok"
        case .undo: return undo(redoing: false)
        case .redo: return undo(redoing: true)
        case .focusApp(let text): return focusApp(text)
        case .space(let target): return switchSpace(target)
        case .moveToSpace(let target, let follow): return moveToSpace(target, follow: follow, window: window)
        case .focusDisplay(let target): return focusDisplay(target)
        case .moveToDisplay(let target): return recording { moveToDisplay(target, window) }
        case .pause:
            setPaused(!paused)
            return paused ? "ok: paused" : "ok: tiling"
        case .reload: return reloadConfig()
        case .applyRules: return applyRules()
        case .settings, .tour, .update: return "ok"
        case .subscribe: return "error: subscribe only works from the command line"
        case .listWindows: return listWindows()
        case .listSpaces: return listSpaces()
        case .tree: return describeTrees()
        case .status: return status()
        case .quit:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return "ok"
        case .mode(let name): return switchMode(name)
        case .sequence(let commands): return Command.runChain(commands) { self.run($0) }
        }
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

    /// The window a command acts on: the one a request named with `--window`, or else the
    /// focused window. Every command that acts on a window finds it here.
    private func targetWindow(_ named: CGWindowID?) -> WindowState? {
        (named ?? focusedWindow).flatMap { windows[$0] }
    }

    /// What a command that needs a tile answers when the window it acts on has none on screen.
    private func notTiled(_ named: CGWindowID?) -> String {
        named.map { "error: window \($0) is not tiled on a desktop being shown" } ?? "error: the focused window is not tiled"
    }

    /// Runs a command on the tile of the window it acts on (`targetWindow`), then lays out again.
    private func withTile(_ named: CGWindowID?, _ body: (CGWindowID, Tree, String) -> String) -> String {
        guard let id = targetWindow(named)?.id, lastFrames[id] != nil, let (key, tree) = treeEntry(containing: id) else {
            return notTiled(named)
        }
        let result = body(id, tree, key)
        restore.stop(key)
        refresh()
        return result
    }

    /// Run a change of layout the user asked for, and remember it as one step on every desktop
    /// it changed, for `undo`. Wrapping a change that is already being recorded adds nothing.
    @discardableResult
    private func recording<T>(_ body: () -> T) -> T {
        guard !isRecording else { return body() }
        let before = trees.mapValues(\.snapshot)
        isRecording = true
        let result = body()
        isRecording = false
        for (key, tree) in trees { if let b = before[key] { history.record(key: key, before: b, after: tree.snapshot) } }
        return result
    }

    /// The layout of the active desktop: the one the focused window is tiled in, or else the
    /// one the active display is showing.
    private var activeTreeKey: String? {
        if let id = focusedWindow, lastFrames[id] != nil, let (key, _) = treeEntry(containing: id) { return key }
        return activeDisplay.flatMap { $0.isDesktop ? $0.treeKey : nil }
    }

    private func undo(redoing: Bool) -> String {
        let nothing = redoing ? "ok: nothing to redo" : "ok: nothing to undo"
        guard let key = activeTreeKey, let tree = trees[key] else { return nothing }
        let current = tree.snapshot
        guard let snapshot = redoing ? history.redo(key: key, current: current) : history.undo(key: key, current: current) else { return nothing }
        let here = Set(tree.windows)
        tree.restore(snapshot)
        restore.stop(key)
        // A window that has closed, floated or gone to another desktop since stays gone. One that
        // has arrived since is not in the snapshot, and the refresh places it as a new window.
        tree.prune { here.contains($0) }
        recheckMinimums(in: tree, key: key)
        refresh()
        return redoing ? "ok: redone" : "ok: undone"
    }

    // MARK: Placing floating windows

    /// `place`: put the window it acts on in a part of its display's area.
    private func place(_ placement: Placement, _ named: CGWindowID? = nil) -> String {
        guard let w = targetWindow(named) else { return "error: no focused window" }
        let id = w.id
        guard w.element.isSettable(kAXPositionAttribute) else { return "error: this window cannot be moved" }
        guard let display = display(holding: w) ?? activeDisplay else { return "error: no display" }
        guard display.isDesktop else { return "error: a fullscreen window cannot be placed" }
        // A tiled window is floated first, as `float` does.
        let floated = w.tileable && !w.floating
        if floated {
            if let key = treeEntry(containing: id)?.0 { restore.stop(key) }
            w.userFloat = true
            for tree in trees.values { tree.remove(id) }
            refresh()
        }
        guard let frame = animator.destination(of: id) ?? w.element.frame else { return "error: cannot read the window's position" }
        let area = display.usableFrame(config)
        let target = placement.frame(in: area, gap: display.settings(config).inner, size: frame.size)
        place(w, at: target, glide: true) { placement.fit($0, to: target, in: area) }
        return floated ? "ok: floating" : "ok"
    }

    /// Take a floating window to `target`. It glides there as tiled windows do, unless `glide` is
    /// false or the move is tiny. `fit` says where the window goes if it will not take the size.
    private func place(_ w: WindowState, at target: CGRect, glide: Bool, fit: @escaping (CGSize) -> CGRect) {
        let current = w.element.frame ?? target
        let change = max(abs(current.minX - target.minX), abs(current.minY - target.minY),
                         abs(current.width - target.width), abs(current.height - target.height))
        let glides = glide && config.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && change > 12
        placing[w.id] = (target, fit)
        animator.move(w.id, pid: w.pid, element: w.element, app: apps[w.pid]?.element,
                      from: current, to: target, duration: glides ? config.animationDuration : 0, easing: config.animationEasing)
    }

    /// A placed window has been given its frame. One that did not take the size (a minimum, a
    /// fixed size) is moved to where `fit` puts it at the size it has. A busy window can answer
    /// with the size it had before, so it is asked once more and looked at again a moment later.
    private func placedLanded(_ id: CGWindowID, asked: CGRect, actual: CGSize?, fit: @escaping (CGSize) -> CGRect) {
        func refused(_ size: CGSize) -> Bool { abs(size.width - asked.width) > 2 || abs(size.height - asked.height) > 2 }
        guard let w = windows[id], w.floating, actual.map(refused) != false else { return }
        w.element.setSize(asked.size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // Unless something has moved the window since: the user, or another placement.
            guard let self, self.placing[id] == nil, !self.animator.isMoving(id), self.windows[id]?.floating == true,
                  let now = w.element.frame, abs(now.minX - asked.minX) <= 2, abs(now.minY - asked.minY) <= 2, refused(now.size) else { return }
            w.element.setPosition(fit(now.size).origin)
        }
    }

    /// A rule can give the windows it floats a size and a position. A new window it matches is
    /// placed once, when it opens, at once rather than gliding: like a window that joins a layout.
    private func applyPlacementRules() {
        guard placementRules.hasLooked else { return placementRules.firstLook(existing: ScreenSnapshot.take().all) }
        let due = placementRules.due(at: Date(), paused: paused) { id in
            guard let w = windows[id], w.floating else { return nil }
            // A window that cannot be resized is still placed; one that cannot be moved is not.
            guard w.tileable || Self.isMovableStandardWindow(w.element), let frame = w.element.frame else { return false }
            return isTab(w, frame) ? nil : true
        }
        guard !due.isEmpty else { return }
        displays = DisplayInfo.current()
        for entry in due {
            guard let w = windows[entry.window], let frame = w.element.frame, let display = display(holding: w), display.isDesktop else { continue }
            let area = display.usableFrame(config)
            guard let target = entry.rule.frame(for: frame, in: area, gap: display.settings(config).inner) else { continue }
            place(w, at: target, glide: false) { entry.rule.fit($0, to: target, in: area) }
            Log.write("rule: placed window \(entry.window) of \(entry.app)")
        }
    }

    private static func isMovableStandardWindow(_ el: AXUIElement) -> Bool {
        el.string(kAXRoleAttribute) == kAXWindowRole && el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && el.isSettable(kAXPositionAttribute)
    }

    private func focus(_ dir: Direction) -> String {
        let snap = ScreenSnapshot.take()
        var frames: [CGWindowID: CGRect] = [:]
        for id in windows.keys { if let f = snap.onScreen[id] { frames[id] = slots[id] ?? f } }
        guard !frames.isEmpty else { return "ok: no windows here" }
        guard let current = focusedWindow, let origin = frames[current] else {
            if let front = snap.order.first(where: { frames[$0] != nil }) { focus(window: front) }
            return "ok"
        }
        // Windows in a stack overlap, so there the layout decides what is next, not the picture.
        guard let target = focusTarget(from: current, at: origin, direction: dir, among: frames,
                                       trees: displays.compactMap { trees[$0.treeKey] }, visible: lastVisible, frontToBack: snap.order) else {
            return "ok: nothing in that direction"
        }
        focus(window: target)
        return "ok"
    }

    /// Back to the window that had the focus before this one. Only a standard window on a
    /// desktop being shown counts, so this never switches desktop.
    private func focusRecent() -> String {
        let snap = ScreenSnapshot.take()
        guard let id = focusHistory.previous(current: focusedWindow, eligible: { id in
            // Dialogs and sheets do not count. A window that can be tiled is a standard one; one
            // that cannot may be a standard window of a fixed size, so it is asked what it is.
            guard let w = windows[id], isShowing(id, snap) else { return false }
            return w.tileable || w.element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
        }) else { return "ok: no other recent window" }
        focus(window: id)
        return "ok"
    }

    private func focus(window id: CGWindowID, attempt: Int = 0, warp: Bool = true) {
        guard let w = windows[id] else {
            // The window closed while its focus was being confirmed: stop waiting for it.
            if focusIntent == id { focusIntent = nil }
            return
        }
        // The direct route can lose a race with the app. A retry goes through the app instead.
        if attempt > 0 || !Private.focus(pid: w.pid, windowID: id) { apps[w.pid]?.app.activate() }
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        w.element.set(kAXMainAttribute, true)
        focusedWindow = id
        focusIntent = id
        for tree in trees.values where tree.contains(id) { tree.focused = id }
        if config.mouseFollowsFocus, warp, attempt == 0, let f = lastFrames[id] ?? w.element.frame {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
            onPointerWarp?(CGPoint(x: f.midX, y: f.midY))
        }
        // macOS sometimes reports success and leaves the focus where it was. Check, and try again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.focusIntent == id else { return }
            if self.systemFocusedWindow() == id || attempt >= 2 {
                self.focusIntent = nil
            } else {
                self.focus(window: id, attempt: attempt + 1)
            }
        }
    }

    private func focusApp(_ text: String) -> String {
        // An app's window that had the focus last is the earliest in the focus history, and
        // its recency there stands in for when it was last active.
        func lastFocused(_ pid: pid_t) -> (window: CGWindowID, at: Double)? {
            for (i, id) in focusHistory.windows.enumerated() where windows[id]?.pid == pid {
                return (id, Double(FocusHistory.limit - i))
            }
            return nil
        }
        let running = apps.keys.sorted().compactMap { pid -> FocusApp.App? in
            guard let a = apps[pid]?.app, !a.isTerminated else { return nil }
            let names = [a.localizedName, a.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0 }
            return FocusApp.App(pid: pid, bundleID: a.bundleIdentifier, names: names, lastActive: lastFocused(pid)?.at ?? 0)
        }
        guard let chosen = FocusApp.choose(text, among: running), let app = apps[chosen.pid]?.app else { return openApp(text) }
        let snap = ScreenSnapshot.take()
        let showing = snap.order.filter { windows[$0]?.pid == chosen.pid && isShowing($0, snap) }
        switch FocusApp.pick(showing: showing, remembered: lastFocused(chosen.pid)?.window, focused: focusedWindow) {
        case .window(let id):
            focus(window: id)
            scheduleRefresh()
            return "ok"
        case .stay:
            return "ok"
        case .activate:
            // Every window minimised: bring the one used most recently back out of the Dock,
            // which activating alone would not do.
            let minimised = Set(windows.filter { $0.value.pid == chosen.pid && $0.value.element.bool(kAXMinimizedAttribute) == true }.keys)
            if let id = FocusApp.minimisedToBringBack(minimised, history: focusHistory.windows) {
                bringForward(id)
                scheduleRefresh()
                return "ok: brought back a minimised window"
            }
            // On another desktop or hidden: macOS knows best which window to show.
            if app.isHidden { app.unhide() }
            app.activate()
            return "ok: activated \(app.localizedName ?? text)"
        }
    }

    /// An app that is not running: found by its bundle id, or by the name of its bundle in
    /// the folders apps are kept in.
    private func openApp(_ text: String) -> String {
        let files = FileManager.default
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) ?? {
            let paths = FocusApp.folders(home: files.homeDirectoryForCurrentUser.path).flatMap { folder in
                ((try? files.contentsOfDirectory(atPath: folder)) ?? []).map { "\(folder)/\($0)" }
            }
            return FocusApp.bundle(named: text, among: paths).map { URL(fileURLWithPath: $0) }
        }()
        guard let url else { return "error: no app called '\(text)'" }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { Log.write("focus-app: could not open \(url.path): \(error.localizedDescription)") }
        }
        return "ok: opening \(url.deletingPathExtension().lastPathComponent)"
    }

    private func systemFocusedWindow() -> CGWindowID? {
        guard let front = NSWorkspace.shared.frontmostApplication, let state = apps[front.processIdentifier],
              let el = state.element.element(kAXFocusedWindowAttribute) else { return nil }
        return Private.windowID(of: el)
    }

    private func move(_ dir: Direction, _ named: CGWindowID?) -> String {
        guard let w = targetWindow(named), let frame = lastFrames[w.id],
              let (key, tree) = treeEntry(containing: w.id) else { return notTiled(named) }
        let id = w.id
        restore.stop(key)
        if tree.move(id, dir, visible: lastVisible) {
            refresh()
            return "ok"
        }
        // At the edge of this display: carry on to the display in that direction, if there is one.
        guard let here = displayIndex(for: frame), let there = neighbourDisplay(of: here, dir) else {
            return "ok: already at the edge"
        }
        carry(id, w, frame, from: tree, to: there)
        return "ok"
    }

    /// Take a tiled window out of its layout and put it on another display. A layout is made of
    /// the windows on its display, so the next refresh adds it to the layout of the desktop shown
    /// there, as it adds a window that has just opened: beside the window last focused there.
    private func carry(_ id: CGWindowID, _ w: WindowState, _ frame: CGRect, from tree: Tree, to display: Int) {
        let area = displays[display].usableFrame(config)
        w.element.setSize(CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height)))
        w.element.setPosition(area.origin)
        w.lastSetFrame = nil
        tree.remove(id)
        restore.stop(displays[display].treeKey)
        // The window joins the layout over there in this refresh, and that is part of the move.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.recording { self.refresh() }
        }
    }

    private func neighbourDisplay(of index: Int, _ dir: Direction) -> Int? {
        var frames: [WindowID: CGRect] = [:]
        for (i, d) in displays.enumerated() { frames[WindowID(i)] = d.frame }
        return nearestWindow(from: displays[index].frame, direction: dir, among: frames, excluding: WindowID(index)).map(Int.init)
    }

    // MARK: Displays by number

    /// Where `next` and `prev` count from: the display holding the focused window, floating or
    /// tiled, so that a display with only floating windows on it cannot hold on to the focus.
    private var displayWithFocus: Int? {
        if let id = focusedWindow, let w = windows[id], let f = lastFrames[id] ?? w.element.frame, let i = displayIndex(for: f) { return i }
        return activeDisplay.flatMap { a in displays.firstIndex { $0.uuid == a.uuid } }
    }

    /// The display a command names, as an index into `displays`, and its number.
    private func display(_ target: DisplayTarget, from here: Int?) -> Result<(index: Int, number: Int), DisplayTarget.Refusal> {
        let order = displays.enumerated().sorted { $0.element.number < $1.element.number }.map(\.offset)
        return target.resolve(active: here.flatMap { order.firstIndex(of: $0) }, count: order.count).map { (order[$0], $0 + 1) }
    }

    private func focusDisplay(_ target: DisplayTarget) -> String {
        let there: Int
        switch display(target, from: displayWithFocus) {
        case .failure(let refusal): return refusal.reply
        case .success(let found): there = found.index
        }
        let d = displays[there]
        let snap = ScreenSnapshot.take()
        let tree = trees[d.treeKey]
        var tiles: [CGWindowID: CGRect] = [:]
        for id in tree?.windows ?? [] where snap.onScreen[id] != nil { tiles[id] = lastFrames[id] }
        let others = snap.order.filter { id in
            guard tiles[id] == nil, windows[id] != nil, isShowing(id, snap), let f = snap.onScreen[id] else { return false }
            return displayIndex(for: f) == there
        }
        let usable = d.usableFrame(config)
        let centre = CGPoint(x: usable.midX, y: usable.midY)
        guard let id = DisplayTarget.windowToFocus(remembered: tree?.focused, tiles: tiles, others: others, centre: centre) else {
            if config.mouseFollowsFocus {
                CGWarpMouseCursorPosition(centre)
                onPointerWarp?(centre)
            }
            return "ok: no window on that display"
        }
        focus(window: id)
        return "ok"
    }

    /// The focus stays with the window, wherever it goes. A window `move-to-display` names with
    /// `--window` is taken instead of the focused one, and the focus stays where it is.
    private func moveToDisplay(_ target: DisplayTarget, _ named: CGWindowID? = nil) -> String {
        guard let w = targetWindow(named) else { return "error: no focused window" }
        let id = w.id
        let tile = lastFrames[id]
        guard let frame = tile ?? w.element.frame, let here = displayIndex(for: frame) else { return "error: cannot read the window's position" }
        guard displays[here].isDesktop else { return "error: a fullscreen window cannot be sent to another display" }
        let there: Int, number: Int
        switch display(target, from: here) {
        case .failure(let refusal): return refusal.reply
        case .success(let found): (there, number) = found
        }
        guard there != here else { return "ok: already on display \(number)" }
        guard displays[there].isDesktop else { return "error: display \(number) is showing a fullscreen app" }
        if let tile, let (key, tree) = treeEntry(containing: id) {
            restore.stop(key)
            restore.stop(displays[there].treeKey)
            carry(id, w, tile, from: tree, to: there)
        } else {
            let f = DisplayTarget.floatingFrame(frame, from: displays[here].usableFrame(config), to: displays[there].usableFrame(config))
            if f.size != frame.size { w.element.setSize(f.size) }
            w.element.setPosition(f.origin)
            scheduleRefresh(after: 0.05)
        }
        return "ok"
    }

    /// Put a window on another display, onto the desktop that display is showing, as `move`
    /// carries one across at the edge. A tiled window joins the layout there beside the window
    /// focused in it, as a new window would. A floating one keeps its size, as far as it fits, and
    /// is centred. The desktop being used and the focus stay as they are.
    private func sendWindow(_ id: CGWindowID, toDisplay index: Int) -> String {
        guard let w = windows[id] else { return "error: the window is gone" }
        guard displays.indices.contains(index) else { return "error: no such display" }
        guard displays[index].isDesktop else { return "error: that display is showing a fullscreen Space" }
        guard let frame = w.element.frame else { return "error: cannot read the window's position" }
        let area = displays[index].usableFrame(config)
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        animator.cancel(id)
        for tree in trees.values { tree.remove(id) }
        w.element.setSize(size)
        w.element.setPosition(CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        w.lastSetFrame = nil
        // The window server reports the move a moment later. A layout that runs before it shows
        // must not adopt the window where it still is, so it is kept out until the poll sees it
        // on the target display or gives up.
        inTransit[id] = (display: index, deadline: Date().addingTimeInterval(0.3))
        pollTransit(id)
        scheduleRefresh(after: 0.1)
        return "ok"
    }

    /// A window `sendWindow` moved that the window server has not caught up with yet.
    private var inTransit: [CGWindowID: (display: Int, deadline: Date)] = [:]

    /// Look again in a moment whether the window reached its display; give up after the deadline.
    private func pollTransit(_ id: CGWindowID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, let transit = inTransit[id] else { return }
            let arrived = Self.serverOrigin(id).map { origin in
                self.windows[id].flatMap { w in w.element.frame.map { self.displayIndex(for: CGRect(origin: origin, size: $0.size)) } } == transit.display
            } ?? false
            if arrived || Date() >= transit.deadline {
                inTransit[id] = nil
                if !arrived { Log.write("rule: window \(id) did not move to display \(transit.display + 1)") }
                scheduleRefresh()
            } else {
                pollTransit(id)
            }
        }
    }

    // MARK: Native Spaces

    private var activeDisplay: DisplayInfo? {
        if let id = focusedWindow, let f = lastFrames[id], let i = displayIndex(for: f) { return displays[i] }
        if let p = CGEvent(source: nil)?.location, let d = displays.first(where: { $0.frame.contains(p) }) { return d }
        return displays.first { $0.isMain } ?? displays.first
    }

    private func shortcut(for target: SpaceTarget) -> (id: Int32?, message: String) {
        displays = DisplayInfo.current()
        guard let d = activeDisplay else { return (nil, "error: no display") }
        switch target {
        case .next: return (Private.SystemShortcut.spaceRight, "ok")
        case .prev: return (Private.SystemShortcut.spaceLeft, "ok")
        case .recent:
            guard let desktop = recentDesktop(on: d) else { return (nil, "ok: no previous desktop") }
            return (Private.SystemShortcut.desktop(desktop.number), "ok")
        case .index(let n):
            // Desktops are numbered across all displays, exactly as Mission Control names them.
            let total = d.totalDesktops
            guard n <= total else { return (nil, "error: there are only \(total) desktops") }
            if let i = d.spaceIndex, d.desktopOffset + i == n { return (nil, "ok: already on desktop \(n)") }
            return (Private.SystemShortcut.desktop(n), "ok")
        }
    }

    /// Remembered for `space recent`, however the desktop changed. A fullscreen Space is not a
    /// desktop and is left out.
    private func noteDesktops() {
        for d in displays where d.isDesktop { desktopHistory.record(display: d.uuid, space: d.spaceID) }
    }

    /// The desktop `display` showed before the one it shows now, while that desktop still exists.
    /// It is found by its Space id and gets its number now, as numbers shift when desktops come and go.
    private func recentDesktop(on display: DisplayInfo) -> Desktop? {
        noteDesktops()
        guard let id = desktopHistory.previous(display: display.uuid, showing: display.spaceID) else { return nil }
        return Desktop.all().first { $0.id == id }
    }

    private func switchSpace(_ target: SpaceTarget) -> String {
        let (id, message) = shortcut(for: target)
        guard let id else { return message }
        return Private.press(shortcut: id) ? "ok" : "error: could not trigger the system shortcut"
    }

    /// `ruled` is the window a rule sends, in place of the focused one. It starts from the display
    /// it is on, and it is never carried across by hand, because that takes the user along.
    /// `named` is a window a request named with `--window`. It starts from where it is too, which
    /// can be a desktop that is not being shown, and takes the keyboard along only if it has it.
    private func moveToSpace(_ target: SpaceTarget, follow: Bool, window named: CGWindowID? = nil, ruled: CGWindowID? = nil) -> String {
        guard let id = ruled ?? targetWindow(named)?.id, let w = windows[id] else { return "error: no focused window" }
        guard !syntheticDrag else { return "error: a move is already in progress" }
        displays = DisplayInfo.current()
        guard let here = (ruled == nil && named == nil ? nil : display(holding: w)) ?? activeDisplay else { return "error: no display" }
        let desktops = Desktop.all()
        // The desktop the window is on. Only a named or ruled window can be on one that is not being shown.
        let spaces = (named == nil && ruled == nil) ? [] : Private.spaces(of: id)
        let from = spaces.isEmpty || spaces.contains(here.spaceID) ? here.spaceID : spaces[0]
        guard from == here.spaceID ? here.isDesktop : desktops.contains(where: { $0.id == from }) else {
            return "error: a fullscreen window cannot be sent to another desktop"
        }

        let destination: Desktop
        switch target {
        case .index(let n):
            guard n <= desktops.count else { return "error: there are only \(desktops.count) desktops" }
            destination = desktops[n - 1]
        case .next, .prev:
            let onThisDisplay = desktops.filter { $0.displayID == here.managedID }
            guard let i = onThisDisplay.firstIndex(where: { $0.id == from }) else { return "error: cannot tell which desktop is showing" }
            let j = target == .next ? i + 1 : i - 1
            guard onThisDisplay.indices.contains(j) else { return "ok: no desktop in that direction" }
            destination = onThisDisplay[j]
        case .recent:
            guard let previous = recentDesktop(on: here) else { return "ok: no previous desktop" }
            destination = previous
        }
        guard destination.id != from, !(spaces.count > 1 && spaces.contains(destination.id)) else {
            return "ok: already on desktop \(destination.number)"
        }
        if ruled == nil { restore.stop(treeEntry(containing: id)?.0 ?? here.treeKey) }

        // A window has to sit on the display its Space belongs to.
        if destination.displayID != here.managedID, let there = displays.first(where: { $0.managedID == destination.displayID }) {
            w.element.setPosition(there.usableFrame(config).origin)
        }

        // The quick way: ask the system's window-management bridge. It takes a few milliseconds
        // and does not switch Space.
        let oldSlot = slots[id]
        if Private.requestMove(window: id, toSpace: destination.id), arrived(id, on: destination.id) {
            for tree in trees.values { tree.remove(id) }
            // The window joins the destination's layout when that Space is next on screen, by the
            // same rule as a newly opened window: it splits the window that was last focused there.
            w.lastSetFrame = nil
            if follow, destination.id == here.spaceID {
                // Brought to the desktop being shown, so there is no desktop to go to.
                focus(window: id)
            } else if follow {
                let origin = here.spaceID
                _ = Private.press(shortcut: Private.SystemShortcut.desktop(destination.number))
                whenSpaceChanges(from: origin, timeout: 3) { [weak self] _ in self?.focus(window: id) }
            } else if ruled == nil, id == focusedWindow {
                // Hand the keyboard to the window that is left nearest to where this one was.
                // A ruled window leaves it alone: applyDesktopRules gives it back itself.
                let remaining = slots.filter { $0.key != id }
                if let oldSlot, let next = remaining.min(by: { distance($0.value, oldSlot) < distance($1.value, oldSlot) })?.key {
                    focus(window: next)
                }
            }
            // A rule's window is sent from inside a refresh, which lays out when this returns.
            if ruled == nil { refresh() }
            return "ok"
        }
        // Carrying it by hand needs it on screen.
        guard ruled == nil, named == nil || isShowing(id, ScreenSnapshot.take()) else { return "error: the system did not move the window" }

        // Older systems, or a window the bridge refuses: carry it across by hand. This always
        // ends on the destination desktop.
        Log.write("move-to-space: the quick route did not move window \(id), falling back to dragging it")
        guard let frame = w.element.frame else { return "error: cannot read the window's position" }
        return dragToSpace(id, w, frame, shortcutID: Private.SystemShortcut.desktop(destination.number))
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }

    /// The bridge answers asynchronously, normally within 20 ms.
    private func arrived(_ id: CGWindowID, on space: UInt64) -> Bool {
        let deadline = Date().addingTimeInterval(0.4)
        repeat {
            if Private.spaces(of: id).contains(space) { return true }
            usleep(4_000)
        } while Date() < deadline
        return false
    }

    /// macOS has no supported way to send another app's window to a Space. Before the bridge
    /// existed, what worked without turning off System Integrity Protection is what a person does
    /// by hand: hold the window by its title bar and switch Space.
    private func dragToSpace(_ id: CGWindowID, _ w: WindowState, _ frame: CGRect, shortcutID: Int32) -> String {

        let points = grabPoints(w, frame)
        let cursor = CGEvent(source: nil)?.location
        syntheticDrag = true
        let finish: (String?) -> Void = { [weak self] problem in
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            if let problem { Log.write("move-to-space: \(problem)") }
            guard let self else { return }
            self.syntheticDrag = false
            self.windows[id]?.lastSetFrame = nil
            self.allDirty = true
            self.scheduleRefresh(after: 0.1)
        }

        let origin = activeDisplay?.spaceID
        grab(id, at: points[...]) { [weak self] held in
            guard let self else { return }
            // Only switch Space once the window is really following the cursor.
            guard let held else { return finish("could not take hold of window \(id) by its title bar, so it stays where it is") }
            // If the desktop is not going to change, let go at once rather than hold the button.
            guard Private.press(shortcut: shortcutID) else {
                Self.postMouse(.leftMouseUp, held)
                return finish("could not trigger the system shortcut, so window \(id) stays where it is")
            }
            let pressed = Date()
            self.whenSpaceChanges(from: origin, timeout: 8) { changed in
                guard changed else {
                    Self.postMouse(.leftMouseUp, held)
                    return finish("the desktop did not change, so window \(id) stays where it is")
                }
                // The Space id flips part-way through the system's animation. Hold on for the rest
                // of it, scaled to how long the first part took: with Shift held (as in the default
                // shortcut) macOS may play the transition in slow motion.
                let rest = max(0.6, 3 * Date().timeIntervalSince(pressed))
                DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                    Self.postMouse(.leftMouseUp, held)
                    finish(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let showing = DisplayInfo.current().map(\.spaceID)
                        if !Private.spaces(of: id).contains(where: { showing.contains($0) }) {
                            Log.write("move-to-space: window \(id) did not come along to the new Space")
                        }
                    }
                }
            }
        }
        return "ok"
    }

    private static func postMouse(_ type: CGEventType, _ point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    /// Where the window server has the window right now.
    private static func serverOrigin(_ id: CGWindowID) -> CGPoint? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        return rect.origin
    }

    /// Spots to hold a window by, safest first. Apps that draw their own title bar put buttons
    /// in it, so the usual "just right of the traffic lights" is not safe everywhere.
    private func grabPoints(_ w: WindowState, _ frame: CGRect) -> [CGPoint] {
        let close = w.element.element(kAXCloseButtonAttribute)?.frame
        let mini = w.element.element(kAXMinimizeButtonAttribute)?.frame
        let zoom = w.element.element(kAXZoomButtonAttribute)?.frame
        var points: [CGPoint] = []
        // The gaps between the traffic lights belong to the title bar and never hold a control.
        if let close, let mini, mini.minX - close.maxX >= 3 { points.append(CGPoint(x: (close.maxX + mini.minX) / 2, y: close.midY)) }
        if let mini, let zoom, zoom.minX - mini.maxX >= 3 { points.append(CGPoint(x: (mini.maxX + zoom.minX) / 2, y: mini.midY)) }
        points.append(CGPoint(x: frame.midX, y: frame.minY + 6))
        if let zoom { points.append(CGPoint(x: zoom.maxX + 10, y: zoom.midY)) }
        points.append(CGPoint(x: frame.minX + 100, y: frame.minY + 14))
        return points
    }

    /// Press the mouse on the first spot that makes the window follow the cursor. Calls back with
    /// the point the button is held at, or nil when no spot worked (the button is up again then).
    private func grab(_ id: CGWindowID, at points: ArraySlice<CGPoint>, _ done: @escaping (CGPoint?) -> Void) {
        guard let p = points.first, let start = Self.serverOrigin(id) else { return done(nil) }
        Self.postMouse(.mouseMoved, p)
        Self.postMouse(.leftMouseDown, p)
        for k in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(k)) {
                Self.postMouse(.leftMouseDragged, CGPoint(x: p.x + CGFloat(2 * k), y: p.y + CGFloat(2 * k)))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if let now = Self.serverOrigin(id), abs(now.x - start.x) + abs(now.y - start.y) >= 3 {
                return done(CGPoint(x: p.x + 8, y: p.y + 8))
            }
            // Not a spot the window can be dragged by. Let go well away from it so nothing is
            // clicked, then try the next one.
            let away = CGPoint(x: p.x + 60, y: p.y + 60)
            Self.postMouse(.leftMouseDragged, away)
            Self.postMouse(.leftMouseUp, away)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.grab(id, at: points.dropFirst(), done) }
        }
    }

    private func whenSpaceChanges(from origin: UInt64?, timeout: TimeInterval, _ body: @escaping (Bool) -> Void) {
        let now = DisplayInfo.current().map(\.spaceID)
        if let origin, !now.contains(origin) { return body(true) }
        guard timeout > 0, origin != nil else { return body(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.whenSpaceChanges(from: origin, timeout: timeout - 0.05, body)
        }
    }

    // MARK: Config

    static var configURL: URL {
        // Only an absolute path counts, as the XDG specification says; anything else would
        // depend on the folder the command happened to be run from.
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("iguana/iguana.toml")
    }

    @discardableResult
    func reloadConfig() -> String {
        let url = Self.configURL
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
        placementRules.markExisting(ScreenSnapshot.take().all)
        displayRules.markExisting()
        applyFloatRules()
        // A mode that is gone, or whose keys changed, is left rather than half kept.
        if config.modes[mode] != modes[mode] { switchMode(Config.defaultMode) }
        onConfigChange?()
        if started { refresh() }
        return reply
    }

    /// Ask every window again whether a rule floats it, as when the config is read. A window
    /// floated or tiled by hand keeps that: the user's choice wins over a rule.
    private func applyFloatRules() {
        for (pid, state) in apps {
            for w in windows.values where w.pid == pid { w.ruleFloat = matchesFloatRule(w, app: state.app) }
        }
        for w in windows.values where w.floating { for tree in trees.values { tree.remove(w.id) } }
    }

    /// `apply-rules`: what the rules say, done now to the windows that are open. Otherwise a rule
    /// only sends a window as it opens. Each standard window goes to the desktop or the display
    /// its rule names, by the same routes as a new one, and the user stays where they are.
    private func applyRules() -> String {
        guard !paused else { return "error: tiling is paused" }
        applyFloatRules()
        let snap = ScreenSnapshot.take()
        let desktops = Desktop.all()
        var moved = 0, cannotStay = false
        for w in windows.values.sorted(by: { $0.id < $1.id }) {
            guard let app = apps[w.pid]?.app, let rule = rule(for: w, app: app), rule.desktop != nil || rule.display != nil,
                  w.tileable, w.element.bool(kAXMinimizedAttribute) != true, w.element.bool("AXFullScreen") != true,
                  let frame = w.element.frame,
                  // Of the tabs of one window, the one in front stands for all of them.
                  snap.onScreen[w.id] != nil || !isTab(w, frame) else { continue }
            let window = "window \(w.id) of \(app.localizedName ?? "an app")"
            var reply = ""
            if let n = rule.desktop {
                let on = Private.spaces(of: w.id)
                switch DesktopRuleAction.decide(wanted: n, standardWindow: true, windowDesktops: desktops.filter { on.contains($0.id) }.map(\.number),
                                                desktopCount: desktops.count, canStay: Private.hasMoveBridge) {
                case .send:
                    let position = w.element.position
                    reply = moveToSpace(.index(n), follow: false, ruled: w.id)
                    // Aiming at a desktop on another display moves the window there first. It did not go, so put it back.
                    if reply.hasPrefix("error"), let position { w.element.setPosition(position) }
                case .missing: Log.write("apply-rules: \(window) was not sent to desktop \(n): there are only \(desktops.count) desktops")
                case .cannotStay: cannotStay = true
                case .leave: break
                }
            } else if let d = rule.display, isShowing(w.id, snap) {
                // A window on a desktop that is not being shown stays on it.
                switch DisplayRuleAction.decide(wanted: d, standardWindow: true, windowDisplay: displayIndex(for: frame),
                                                names: displays.map(\.name), frames: displays.map(\.frame)) {
                case .send(let i): reply = sendWindow(w.id, toDisplay: i)
                case .missing: Log.write("apply-rules: \(window) was not sent to display \(d): no such display is connected")
                case .leave: break
                }
            }
            if reply == "ok" { moved += 1 }
            if reply.hasPrefix("error: ") { Log.write("apply-rules: \(window) was not moved: \(reply.dropFirst(7))") }
        }
        if cannotStay { Log.write("apply-rules: this macOS can only take a window to another desktop by going there with it, so desktops in rules were not applied") }
        refresh()
        return moved == 0 ? "ok: nothing to move" : "ok: \(moved) window(s) moved"
    }

    // MARK: Reports

    private func label(_ id: CGWindowID) -> String {
        guard let w = windows[id] else { return "window \(id) (not seen yet)" }
        let app = apps[w.pid]?.app.localizedName ?? "pid \(w.pid)"
        let title = w.element.string(kAXTitleAttribute) ?? ""
        let shown = lastVisible.contains(id) ? "" : "  (not on screen)"
        return "\(app): \(title.prefix(50)) #\(id)\(shown)"
    }

    private func describeTrees() -> String {
        var out: [String] = []
        for d in displays {
            let where_ = d.spaceIndex.map { "desktop \(d.desktopOffset + $0)" } ?? "fullscreen Space (not managed)"
            out.append("\(d.name), \(where_)")
            if let tree = trees[d.treeKey], !tree.isEmpty {
                out.append(tree.describe(label: label).split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
            } else if d.isDesktop {
                out.append("  (no tiled windows)")
            }
        }
        let others = trees.filter { key, tree in !tree.isEmpty && !displays.contains { $0.treeKey == key } }
        if !others.isEmpty { out.append("\(others.count) other Space(s) have a remembered layout") }
        return out.joined(separator: "\n")
    }

    private func listWindows() -> String {
        let onScreen = Set(ScreenSnapshot.take().onScreen.keys)
        let rows = windows.values.sorted { $0.id < $1.id }.map { w -> String in
            let state: String
            if lastFrames[w.id] != nil {
                state = "tiled"
            } else if !onScreen.contains(w.id) {
                state = "not on screen"
            } else if w.floating {
                state = "floating"
            } else {
                state = w.tileable ? "tiled" : "unmanaged"
            }
            let app = apps[w.pid]?.app.localizedName ?? "pid \(w.pid)"
            let mark = w.id == focusedWindow ? "*" : " "
            return "\(mark) \(w.id)\t\(state)\t\(app)\t\(w.element.string(kAXTitleAttribute) ?? "")"
        }
        return rows.isEmpty ? "no windows on this Space" : rows.joined(separator: "\n")
    }

    private func listSpaces() -> String {
        displays = DisplayInfo.current()
        return displays.sorted { $0.number < $1.number }.map { d in
            let now = d.spaceIndex.map { "desktop \(d.desktopOffset + $0) of \(d.totalDesktops)" } ?? "a fullscreen Space"
            return "Display \(d.number), \(d.name): showing \(now); this display has \(d.spaceCount) desktop(s)"
        }.joined(separator: "\n")
    }

    func status() -> String {
        guard AXIsProcessTrusted() else {
            return "Iguana \(Self.version): waiting for Accessibility permission\n(System Settings > Privacy & Security > Accessibility, switch on Iguana)"
        }
        var lines = ["Iguana \(Self.version): \(paused ? "paused" : "tiling")"]
        lines.append("config: \(FileManager.default.fileExists(atPath: Self.configURL.path) ? Self.configURL.path : "built-in defaults")")
        lines.append(contentsOf: configWarnings.map { "  warning: \($0)" })
        lines.append("windows: \(lastFrames.count) tiled on screen, \(windows.count) known, \(apps.count) apps watched")
        let strip = StageManager.reservedWidth(config)
        lines.append("stage manager: \(StageManager.isOn ? "on" : "off")\(strip > 0 ? ", leaving \(Int(strip)) pt for the strip" : "")")
        lines.append(listSpaces())
        if mode != Config.defaultMode { lines.append("mode: \(mode)") }
        lines.append(contentsOf: statusExtras?() ?? [])
        return lines.joined(separator: "\n")
    }

    var tiledWindowCount: Int { lastFrames.count }

    /// The layout of the desktop being shown, for the settings window's miniature.
    func desktopPreview() -> (layout: NodeSnapshot, visible: Set<CGWindowID>, owners: [CGWindowID: pid_t], focused: CGWindowID?, screen: CGSize, usable: CGRect, display: DisplayInfo)? {
        guard let display = activeDisplay ?? displays.first, display.isDesktop, let tree = trees[display.treeKey] else { return nil }
        let visible = lastVisible.intersection(tree.windows)
        guard visible.count >= 2 else { return nil }
        var owners: [CGWindowID: pid_t] = [:]
        for id in visible { if let w = windows[id] { owners[id] = w.pid } }
        let usable = display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return (tree.snapshot, visible, owners, focusedWindow.flatMap { visible.contains($0) ? $0 : nil } ?? tree.focused, display.frame.size, usable, display)
    }

    /// One desktop as the menu bar shows it: its number, its layout and the windows in it.
    struct Desk {
        let number: Int
        /// The desktop the user is on.
        let isActive: Bool
        let layout: NodeSnapshot
        /// The windows to draw: those on screen for a desktop being shown, every living window otherwise.
        let windows: Set<CGWindowID>
        let focused: CGWindowID?
        let screen: CGSize
        let usable: CGRect
        let display: DisplayInfo
    }

    /// Every desktop in Mission Control order, and which app each of their windows belongs to.
    func desks() -> (desks: [Desk], owners: [CGWindowID: pid_t]) {
        guard !displays.isEmpty else { return ([], [:]) }
        // Windows on other desktops are not on screen, but the system still lists them.
        var owners: [CGWindowID: pid_t] = [:]
        for info in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            if let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
               let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value { owners[id] = pid }
        }
        let active = activeDisplay ?? displays[0]
        let list = Desktop.all().map { desktop -> Desk in
            let display = displays.first { $0.uuid == desktop.displayID || $0.managedID == desktop.displayID } ?? displays[0]
            let tree = trees["\(desktop.key)|\(display.uuid)"]
            let showing = display.spaceKey == desktop.key
            let living = Set(tree?.windows ?? []).filter { owners[$0] != nil }
            let drawn = showing ? living.intersection(lastVisible) : living
            let isActive = showing && display.uuid == active.uuid
            let focused = isActive ? (focusedWindow.flatMap { drawn.contains($0) ? $0 : nil } ?? tree?.focused) : tree?.focused
            return Desk(number: desktop.number, isActive: isActive, layout: tree?.snapshot ?? Tree().snapshot, windows: drawn,
                        focused: focused, screen: display.frame.size,
                        usable: display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY), display: display)
        }
        return (list, owners.filter { id, _ in list.contains { $0.windows.contains(id) } })
    }

    /// Bring one window forward, as a click on it in the menu bar item's menu asks.
    func focusWindow(_ id: CGWindowID) {
        guard started, AXIsProcessTrusted(), windows[id] != nil else { return }
        focus(window: id)
        scheduleRefresh()
    }

    /// Focus the window the pointer rests on (`focus-follows-mouse`). The pointer is already
    /// where the user wants it, so `mouse-follows-focus` does not move it.
    func focusFromPointer(_ id: CGWindowID) {
        guard started, AXIsProcessTrusted(), windows[id] != nil else { return }
        focus(window: id, warp: false)
        scheduleRefresh()
    }

    /// Short text for the menu bar.
    var menuBarTitle: String {
        guard let d = activeDisplay ?? displays.first, let i = d.spaceIndex else { return "" }
        return "\(d.desktopOffset + i)"
    }

    // MARK: Facts for the JSON reports and the hooks

    /// What Reports.swift and Hooks.swift read. They only look: nothing outside this file
    /// changes a window or a layout.
    struct Facts {
        let windows: [CGWindowID: WindowState]
        let apps: [pid_t: AppState]
        let trees: [String: Tree]
        /// The windows that have a tile on screen right now.
        let tiled: Set<CGWindowID>
        let visible: Set<CGWindowID>
        let activeDisplay: DisplayInfo?
        /// Every window the system has, on any Space: on screen, minimised or hidden.
        let existing: Set<CGWindowID>
        /// The window that fills its desktop, by tree.
        let zoomed: [String: CGWindowID]
    }

    /// `fresh` looks at the displays and the focus again first, as running a command does.
    func facts(fresh: Bool = false) -> Facts {
        if fresh {
            displays = DisplayInfo.current()
            if started, AXIsProcessTrusted() { updateFocus(ScreenSnapshot.take()) }
        }
        return Facts(windows: windows, apps: apps, trees: trees, tiled: Set(lastFrames.keys), visible: lastVisible,
                     activeDisplay: activeDisplay, existing: lastExisting, zoomed: zoomed)
    }

    /// Where Iguana is sending a window right now, and whether it glides there or is placed
    /// at once. Nil for a window Iguana is not moving. The focus ring reads this.
    func motion(of id: CGWindowID) -> (to: CGRect, gliding: Bool)? {
        animator.destination(of: id).map { ($0, animator.isGliding(id)) }
    }

    // MARK: Saved layouts

    struct SavedState: Codable {
        var boot: Double
        var trees: [String: NodeSnapshot]
        var floating: [CGWindowID]
        /// Minimum sizes learned so far, as [width, height], so a restart does not relearn them.
        var minSizes: [String: [Double]]?
        /// What each window in `trees` and `floating` is, so that it can be known again after
        /// a restart of the Mac, when it has a new id.
        var windows: [String: WindowDescriptor]?
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Iguana")
    }

    private static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }

    /// Window ids are only meaningful until the next restart of the Mac.
    private static var bootTime: Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib = [CTL_KERN, KERN_BOOTTIME]
        return sysctl(&mib, 2, &tv, &size, nil, 0) == 0 ? Double(tv.tv_sec) : 0
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        var described: [CGWindowID: WindowDescriptor] = [:]
        for (key, d) in saved.windows ?? [:] { if let id = CGWindowID(key) { described[id] = d } }
        guard saved.boot == Self.bootTime else {
            // Every window comes back with a new id. The layouts wait for windows that look like theirs.
            restore = RestoreSession(trees: saved.trees, floating: saved.floating, windows: described, from: Date())
            if !restore.waiting.isEmpty {
                Log.write("restore: the Mac has restarted; for \(Int(RestoreSession.gracePeriod / 60)) minutes, windows that come back take their places in \(restore.waiting.count) saved layout(s)")
            }
            return
        }
        savedWindows = described
        for (key, snapshot) in saved.trees { trees[key] = Tree(snapshot: snapshot) }
        restoredFloating = Set(saved.floating)
        for (key, size) in saved.minSizes ?? [:] where size.count == 2 {
            if let id = CGWindowID(key) { restoredMinSizes[id] = CGSize(width: size[0], height: size[1]) }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveState() {
        // Before tiling has started there is nothing to save, and saving would wipe what was kept.
        guard started else { return }
        var snapshots: [String: NodeSnapshot] = [:]
        for (key, tree) in trees where !tree.isEmpty { snapshots[key] = tree.snapshot }
        var mins: [String: [Double]] = [:]
        for w in windows.values { if let m = w.minSize { mins["\(w.id)"] = [Double(m.width), Double(m.height)] } }
        let floating = windows.values.filter { $0.userFloat == true }.map(\.id)
        // A window that is not on screen is kept as it was last seen, without asking its app.
        var described: [CGWindowID: WindowDescriptor] = [:]
        for id in Set(trees.values.flatMap(\.windows) + floating) {
            let ask = lastVisible.contains(id) || savedWindows[id] == nil
            described[id] = (ask ? windows[id].flatMap { describe($0, frame: lastFrames[id]) } : nil) ?? savedWindows[id]
        }
        savedWindows = described
        let state = SavedState(boot: Self.bootTime, trees: snapshots, floating: floating, minSizes: mins,
                               windows: Dictionary(uniqueKeysWithValues: described.map { ("\($0.key)", $0.value) }))
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    // MARK: After a restart of the Mac

    /// What a window is, to know it again after a restart of the Mac. `frame` is where it is,
    /// when that is known already.
    private func describe(_ w: WindowState, frame: CGRect?) -> WindowDescriptor? {
        guard let app = apps[w.pid]?.app, let frame = frame ?? w.element.frame else { return nil }
        return WindowDescriptor(bundleID: app.bundleIdentifier, app: app.localizedName, title: w.element.string(kAXTitleAttribute), frame: frame)
    }

    /// Lay a desktop out in its saved shape again when more of its windows have come back. This
    /// comes before the layout is computed, so the windows go straight to their places: the ones
    /// that have just come back at once, the others gliding as usual.
    private func restoreLayout(_ display: DisplayInfo, _ here: [WindowState], _ snap: ScreenSnapshot, usable: CGRect, gap: Double) {
        // Never while a window is being dragged by hand.
        guard drag == nil else { return }
        let key = display.treeKey
        let wanted = restore.apps(waitingOn: key, at: Date())
        guard !wanted.isEmpty else { return }
        var seen: [CGWindowID: WindowDescriptor] = [:]
        for w in here {
            guard let bundle = apps[w.pid]?.app.bundleIdentifier, wanted.contains(bundle) else { continue }
            seen[w.id] = describe(w, frame: snap.onScreen[w.id])
        }
        let old = trees[key]
        let kept = Set(old?.windows ?? [])
        guard let tree = restore.rebuild(key, windows: seen, kept: kept, at: Date()) else { return }
        trees[key] = tree
        let back = tree.windows
        for id in back {
            for (k, other) in trees where k != key { other.remove(id) }
            if !kept.contains(id) { justAdopted.insert(id) }
        }
        // The windows that were here already and have no place in the saved layout go in as new
        // windows do, and glide there. Those not on screen keep a place at the end.
        tree.focused = old?.focused
        let ids = Set(here.map(\.id))
        for w in here where kept.contains(w.id) && !tree.contains(w.id) {
            adopt(w, into: tree, key: key, visible: ids, usable: usable, gap: gap)
            justAdopted.remove(w.id)
        }
        for id in old?.windows ?? [] where !tree.contains(id) { tree.insert(id) }
        let desktop = display.spaceIndex.map { "desktop \(display.desktopOffset + $0)" } ?? "a desktop"
        Log.write("restore: \(desktop) has \(back.count) window(s) back in its saved layout\(restore.waiting.contains(key) ? "" : ", which is complete")")
    }

    /// A window the user had floated by hand before a restart of the Mac floats again when it comes back.
    private func refloat(_ fresh: [WindowState], app: NSRunningApplication) {
        guard !fresh.isEmpty, let bundle = app.bundleIdentifier, restore.mayFloat(bundle, at: Date()) else { return }
        var seen: [CGWindowID: WindowDescriptor] = [:]
        // Where the window is does not matter here.
        for w in fresh where w.tileable {
            seen[w.id] = WindowDescriptor(bundleID: bundle, app: app.localizedName, title: w.element.string(kAXTitleAttribute), frame: .zero)
        }
        let count = windows.values.filter { $0.pid == app.processIdentifier && $0.tileable }.count
        for id in restore.refloat(seen, appWindows: [bundle: count], at: Date()) { windows[id]?.userFloat = true }
    }
}
