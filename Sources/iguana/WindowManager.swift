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
    static let version = "0.1.0"

    private(set) var config = Config.default
    private(set) var configWarnings: [String] = []
    var onChange: (() -> Void)?
    var onConfigChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenTour: (() -> Void)?
    /// Extra lines for `status`, supplied by the app shell.
    var statusExtras: (() -> [String])?

    private var apps: [pid_t: AppState] = [:]
    private var windows: [CGWindowID: WindowState] = [:]
    private var trees: [String: Tree] = [:]
    private var zoomed: [String: CGWindowID] = [:]
    /// Where each visible tiled window belongs according to its tree.
    private var slots: [CGWindowID: CGRect] = [:]
    /// What was actually applied (differs from `slots` for a zoomed window).
    private var lastFrames: [CGWindowID: CGRect] = [:]
    private var lastVisible = Set<CGWindowID>()
    private(set) var displays: [DisplayInfo] = []
    private var dirtyApps = Set<pid_t>()
    private var allDirty = true
    private(set) var paused = false
    private var refreshPending = false
    private(set) var focusedWindow: CGWindowID?
    private var focusIntent: CGWindowID?
    private var drag: (id: CGWindowID, start: CGRect)?
    private var syntheticDrag = false
    private var started = false
    private var restoredFloating = Set<CGWindowID>()
    private var restoredMinSizes: [CGWindowID: CGSize] = [:]
    private var saveWork: DispatchWorkItem?
    private var lastConfigLog = ""
    private let animator = Animator()
    /// Windows that joined a layout in this refresh. They are placed at once; the rest glide.
    private var justAdopted = Set<CGWindowID>()
    /// The next refresh places windows at once (arriving on a desktop, first layout).
    private var instantNext = true

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
            if drag == nil { drag = (id, slot) }
            return
        }
        if mouseIsDown { return }
        scheduleRefresh(after: 0.1)
    }

    private func mouseUp() {
        guard let d = drag else { return }
        drag = nil
        defer { scheduleRefresh(after: 0) }
        guard let w = windows[d.id], let now = w.element.frame, let (_, tree) = treeEntry(containing: d.id) else { return }
        w.lastSetFrame = nil
        let dw = now.width - d.start.width, dh = now.height - d.start.height
        if abs(dw) > 3 || abs(dh) > 3 {
            // Resized by hand: keep the new proportions.
            if abs(dw) > 3 { tree.changeShare(of: d.id, along: .horizontal, .ratio(Double(now.width / d.start.width)), visible: lastVisible) }
            if abs(dh) > 3 { tree.changeShare(of: d.id, along: .vertical, .ratio(Double(now.height / d.start.height)), visible: lastVisible) }
        } else if let cursor = CGEvent(source: nil)?.location,
                  let target = lastFrames.first(where: { $0.key != d.id && $0.value.contains(cursor) })?.key {
            // Dropped on another tile: trade places.
            if tree.contains(target) {
                tree.swap(d.id, target)
            } else if let (_, other) = treeEntry(containing: target) {
                tree.remove(d.id)
                other.insert(d.id, after: target)
            }
        }
    }

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

        let snap = ScreenSnapshot.take()
        prune(existing: snap.all)
        displays = DisplayInfo.current()
        updateFocus(snap)

        guard !paused else {
            onChange?()
            return
        }

        let (frames, newSlots) = layoutAll(snap)
        apply(frames, snap, animated: !instantNext)
        instantNext = false
        slots = newSlots
        lastFrames = frames
        lastVisible = Set(frames.keys)
        scheduleSave()
        onChange?()
    }

    private func enumerate(_ state: AppState) {
        guard let list = state.element.elements(kAXWindowsAttribute) else { return }
        let pid = state.app.processIdentifier
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
            w.ruleFloat = matchesFloatRule(w, app: state.app)
            if restoredFloating.remove(id) != nil { w.userFloat = true }
            if let size = restoredMinSizes.removeValue(forKey: id) { w.minSize = size }
            windows[id] = w
            if let o = state.observer {
                AXObserverAddNotification(o, el, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    private static func isTileable(_ el: AXUIElement) -> Bool {
        el.string(kAXRoleAttribute) == kAXWindowRole
            && el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && el.isSettable(kAXSizeAttribute) && el.isSettable(kAXPositionAttribute)
    }

    private func matchesFloatRule(_ w: WindowState, app: NSRunningApplication) -> Bool {
        guard !config.rules.isEmpty else { return false }
        let title = config.rules.contains { $0.title != nil } ? w.element.string(kAXTitleAttribute) : nil
        // The first rule that matches decides, so `float = false` can carve an exception out of a later rule.
        return config.rules.first { $0.matches(bundleID: app.bundleIdentifier, appName: app.localizedName, title: title) }?.float ?? false
    }

    private func prune(existing: Set<CGWindowID>) {
        for id in windows.keys where !existing.contains(id) {
            animator.cancel(id)
            windows[id] = nil
            lastFrames[id] = nil
            slots[id] = nil
        }
        for tree in trees.values { tree.prune { existing.contains($0) } }
        for (key, id) in zoomed where !existing.contains(id) { zoomed[key] = nil }
        if let waiting = focusIntent, !existing.contains(waiting) { focusIntent = nil }
        if let f = focusedWindow, !existing.contains(f) { focusedWindow = nil }
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
            guard let rect = snap.onScreen[w.id], let i = displayIndex(for: rect) else { continue }
            // While macOS slides from one Space to the next, the windows of both are on screen.
            // Only the ones that really live on the Space being shown belong in its layout.
            let spaces = Private.spaces(of: w.id)
            guard spaces.isEmpty || spaces.contains(displays[i].spaceID) else { continue }
            byDisplay[i, default: []].append(w)
        }
        let mins = minSizes
        for (i, d) in displays.enumerated() where d.isDesktop {
            let here = (byDisplay[i] ?? []).sorted { $0.id < $1.id }
            let ids = Set(here.map(\.id))
            let usable = d.usableFrame(config)
            let key = d.treeKey
            let tree: Tree
            if let t = trees[key] {
                tree = t
            } else {
                tree = Tree(orientation: usable.width >= usable.height ? .horizontal : .vertical)
                trees[key] = tree
            }
            for w in here where !tree.contains(w.id) {
                adopt(w, into: tree, key: key, visible: ids, usable: usable)
            }
            if let z = zoomed[key], !ids.contains(z) { zoomed[key] = nil }
            let computed = computeLayout(tree, in: usable, gap: config.gapInner, visible: ids, minSizes: mins)
            allSlots.merge(computed) { a, _ in a }
            var applied = computed
            if let z = zoomed[key] { applied[z] = usable }
            frames.merge(applied) { a, _ in a }
        }
        return (frames, allSlots)
    }

    private func adopt(_ w: WindowState, into tree: Tree, key: String, visible: Set<CGWindowID>, usable: CGRect) {
        for (k, other) in trees where k != key { other.remove(w.id) }
        justAdopted.insert(w.id)

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
        if config.autoSplit, let anchor,
           let f = computeLayout(tree, in: usable, gap: config.gapInner, visible: visible)[anchor] {
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

    /// A window has been given its final frame. If it came out bigger than asked, it has a
    /// minimum size: remember it and lay out again around it.
    private func landed(_ id: CGWindowID, asked: CGRect, actual: CGSize?) {
        guard let w = windows[id], let actual, !zoomed.values.contains(id) else { return }
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

    // MARK: Commands

    func run(_ command: Command) -> String {
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
        case .quit:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return "ok"
        default: break
        }
        guard AXIsProcessTrusted() else {
            return "error: Iguana needs Accessibility permission (System Settings > Privacy & Security > Accessibility)"
        }
        switch command {
        case .focus(let dir): return focus(dir)
        case .move(let dir): return move(dir)
        case .join(let dir):
            return withFocusedTile { id, tree, _ in
                tree.join(id, with: dir, visible: lastVisible) ? "ok" : "ok: no neighbour in that direction"
            }
        case .resize(let axis, let grow):
            return withFocusedTile { id, tree, _ in
                tree.changeShare(of: id, along: axis, .delta(Double(grow) * config.resizeStep), visible: lastVisible)
                    ? "ok" : "ok: nothing to resize against"
            }
        case .flip:
            return withFocusedTile { id, tree, _ in tree.flip(id) ? "ok" : "error: cannot flip" }
        case .balance:
            return withFocusedTile { _, tree, _ in
                tree.balance()
                return "ok"
            }
        case .zoom:
            return withFocusedTile { id, _, key in
                zoomed[key] = zoomed[key] == id ? nil : id
                if let w = windows[id] { AXUIElementPerformAction(w.element, kAXRaiseAction as CFString) }
                return "ok"
            }
        case .float:
            guard let id = focusedWindow, let w = windows[id] else { return "error: no focused window" }
            guard w.tileable else { return "error: this window cannot be tiled" }
            w.userFloat = !w.floating
            if w.floating { for tree in trees.values { tree.remove(id) } }
            refresh()
            return w.floating ? "ok: floating" : "ok: tiled"
        case .close:
            guard let id = focusedWindow, let w = windows[id] else { return "error: no focused window" }
            guard let button = w.element.element(kAXCloseButtonAttribute) else { return "error: this window has no close button" }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return "ok"
        case .space(let target): return switchSpace(target)
        case .moveToSpace(let target, let follow): return moveToSpace(target, follow: follow)
        case .pause:
            setPaused(!paused)
            return paused ? "ok: paused" : "ok: tiling"
        case .reload: return reloadConfig()
        case .settings, .tour: return "ok"
        case .listWindows: return listWindows()
        case .listSpaces: return listSpaces()
        case .tree: return describeTrees()
        case .status: return status()
        case .quit:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return "ok"
        }
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        instantNext = false
        refresh()
    }

    private func withFocusedTile(_ body: (CGWindowID, Tree, String) -> String) -> String {
        guard let id = focusedWindow, lastFrames[id] != nil, let (key, tree) = treeEntry(containing: id) else {
            return "error: the focused window is not tiled"
        }
        let result = body(id, tree, key)
        refresh()
        return result
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
        guard let target = nearestWindow(from: origin, direction: dir, among: frames, excluding: current) else {
            return "ok: nothing in that direction"
        }
        focus(window: target)
        return "ok"
    }

    private func focus(window id: CGWindowID, attempt: Int = 0) {
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
        if config.mouseFollowsFocus, attempt == 0, let f = lastFrames[id] ?? w.element.frame {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
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

    private func systemFocusedWindow() -> CGWindowID? {
        guard let front = NSWorkspace.shared.frontmostApplication, let state = apps[front.processIdentifier],
              let el = state.element.element(kAXFocusedWindowAttribute) else { return nil }
        return Private.windowID(of: el)
    }

    private func move(_ dir: Direction) -> String {
        guard let id = focusedWindow, let w = windows[id], let frame = lastFrames[id],
              let (_, tree) = treeEntry(containing: id) else { return "error: the focused window is not tiled" }
        if tree.move(id, dir, visible: lastVisible) {
            refresh()
            return "ok"
        }
        // At the edge of this display: carry on to the display in that direction, if there is one.
        guard let here = displayIndex(for: frame), let there = neighbourDisplay(of: here, dir) else {
            return "ok: already at the edge"
        }
        let area = displays[there].usableFrame(config)
        w.element.setSize(CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height)))
        w.element.setPosition(area.origin)
        w.lastSetFrame = nil
        tree.remove(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refresh() }
        return "ok"
    }

    private func neighbourDisplay(of index: Int, _ dir: Direction) -> Int? {
        var frames: [WindowID: CGRect] = [:]
        for (i, d) in displays.enumerated() { frames[WindowID(i)] = d.frame }
        return nearestWindow(from: displays[index].frame, direction: dir, among: frames, excluding: WindowID(index)).map(Int.init)
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
        case .index(let n):
            // Desktops are numbered across all displays, exactly as Mission Control names them.
            let total = d.totalDesktops
            guard n <= total else { return (nil, "error: there are only \(total) desktops") }
            if let i = d.spaceIndex, d.desktopOffset + i == n { return (nil, "ok: already on desktop \(n)") }
            return (Private.SystemShortcut.desktop(n), "ok")
        }
    }

    private func switchSpace(_ target: SpaceTarget) -> String {
        let (id, message) = shortcut(for: target)
        guard let id else { return message }
        return Private.press(shortcut: id) ? "ok" : "error: could not trigger the system shortcut"
    }

    private func moveToSpace(_ target: SpaceTarget, follow: Bool) -> String {
        guard let id = focusedWindow, let w = windows[id] else { return "error: no focused window" }
        guard !syntheticDrag else { return "error: a move is already in progress" }
        displays = DisplayInfo.current()
        guard let here = activeDisplay else { return "error: no display" }
        guard here.isDesktop else { return "error: a fullscreen window cannot be sent to another desktop" }

        let desktops = Desktop.all()
        let destination: Desktop
        switch target {
        case .index(let n):
            guard n <= desktops.count else { return "error: there are only \(desktops.count) desktops" }
            destination = desktops[n - 1]
        case .next, .prev:
            let onThisDisplay = desktops.filter { $0.displayID == here.managedID }
            guard let i = onThisDisplay.firstIndex(where: { $0.id == here.spaceID }) else { return "error: cannot tell which desktop is showing" }
            let j = target == .next ? i + 1 : i - 1
            guard onThisDisplay.indices.contains(j) else { return "ok: no desktop in that direction" }
            destination = onThisDisplay[j]
        }
        guard destination.id != here.spaceID else { return "ok: already on desktop \(destination.number)" }

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
            if follow {
                let origin = here.spaceID
                _ = Private.press(shortcut: Private.SystemShortcut.desktop(destination.number))
                whenSpaceChanges(from: origin, timeout: 3) { [weak self] _ in self?.focus(window: id) }
            } else {
                // Hand the keyboard to the window that is left nearest to where this one was.
                let remaining = slots.filter { $0.key != id }
                if let oldSlot, let next = remaining.min(by: { distance($0.value, oldSlot) < distance($1.value, oldSlot) })?.key {
                    focus(window: next)
                }
            }
            refresh()
            return "ok"
        }

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
        for (pid, state) in apps {
            for w in windows.values where w.pid == pid { w.ruleFloat = matchesFloatRule(w, app: state.app) }
        }
        for w in windows.values where w.floating { for tree in trees.values { tree.remove(w.id) } }
        onConfigChange?()
        if started { refresh() }
        return reply
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
        return displays.map { d in
            let now = d.spaceIndex.map { "desktop \(d.desktopOffset + $0) of \(d.totalDesktops)" } ?? "a fullscreen Space"
            return "\(d.name): showing \(now); this display has \(d.spaceCount) desktop(s)"
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
        lines.append(contentsOf: statusExtras?() ?? [])
        return lines.joined(separator: "\n")
    }

    var tiledWindowCount: Int { lastFrames.count }

    /// The layout of the desktop being shown, for the settings window's miniature.
    func desktopPreview() -> (layout: NodeSnapshot, visible: Set<CGWindowID>, owners: [CGWindowID: pid_t], focused: CGWindowID?, screen: CGSize, usable: CGRect)? {
        guard let display = activeDisplay ?? displays.first, display.isDesktop, let tree = trees[display.treeKey] else { return nil }
        let visible = lastVisible.intersection(tree.windows)
        guard visible.count >= 2 else { return nil }
        var owners: [CGWindowID: pid_t] = [:]
        for id in visible { if let w = windows[id] { owners[id] = w.pid } }
        let usable = display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return (tree.snapshot, visible, owners, focusedWindow.flatMap { visible.contains($0) ? $0 : nil } ?? tree.focused, display.frame.size, usable)
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
                        usable: display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
        }
        return (list, owners.filter { id, _ in list.contains { $0.windows.contains(id) } })
    }

    /// Bring one window forward, as a click on it in the menu bar item's menu asks.
    func focusWindow(_ id: CGWindowID) {
        guard started, AXIsProcessTrusted(), windows[id] != nil else { return }
        focus(window: id)
        scheduleRefresh()
    }

    /// Short text for the menu bar.
    var menuBarTitle: String {
        guard let d = activeDisplay ?? displays.first, let i = d.spaceIndex else { return "" }
        return "\(d.desktopOffset + i)"
    }

    // MARK: Saved layouts

    private struct SavedState: Codable {
        var boot: Double
        var trees: [String: NodeSnapshot]
        var floating: [CGWindowID]
        /// Minimum sizes learned so far, as [width, height], so a restart does not relearn them.
        var minSizes: [String: [Double]]?
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
              let saved = try? JSONDecoder().decode(SavedState.self, from: data),
              saved.boot == Self.bootTime else { return }
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
        let state = SavedState(boot: Self.bootTime, trees: snapshots,
                               floating: windows.values.filter { $0.userFloat == true }.map(\.id), minSizes: mins)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}
