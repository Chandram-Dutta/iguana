import AppKit
import ApplicationServices
import IguanaCore
@testable import iguana

// A Mac that is made up: displays with Spaces, apps with windows, a pointer. The window
// manager runs against it exactly as it runs against the real one, and a test plays the user
// and the apps: it opens and closes windows, clicks, drags, switches desktop.
//
// It behaves like macOS where the window manager depends on it: a window on a Space that is
// not showing is not on screen, an app says so a moment after one of its windows moves, a
// window does not get smaller than its minimum size.

class FakeElement: UIElement {
    var pid: pid_t = 0
    func string(_ name: String) -> String? { nil }
    func bool(_ name: String) -> Bool? { nil }
    func element(_ name: String) -> UIElement? { nil }
    func elements(_ name: String) -> [UIElement]? { nil }
    func isSettable(_ name: String) -> Bool { false }
    var position: CGPoint? { nil }
    var size: CGSize? { nil }
    @discardableResult func setPosition(_ p: CGPoint) -> Bool { false }
    @discardableResult func setSize(_ s: CGSize) -> Bool { false }
    @discardableResult func set(_ name: String, _ value: Bool) -> Bool { false }
    @discardableResult func perform(_ action: String) -> Bool { false }
    var windowID: CGWindowID? { nil }
    func isSame(as other: UIElement) -> Bool { other === self }
}

/// A button in a window's title bar.
final class FakeButton: FakeElement {
    private let rect: () -> CGRect
    private let press: () -> Void

    init(pid: pid_t, rect: @escaping () -> CGRect, press: @escaping () -> Void) {
        self.rect = rect
        self.press = press
        super.init()
        self.pid = pid
    }

    override var position: CGPoint? { rect().origin }
    override var size: CGSize? { rect().size }

    @discardableResult
    override func perform(_ action: String) -> Bool {
        guard action == kAXPressAction else { return false }
        press()
        return true
    }
}

final class FakeWindow: FakeElement {
    let id: CGWindowID
    private unowned let system: FakeWindowSystem
    unowned let app: FakeApp

    var title: String
    /// Where the window is, measured from the top-left corner of the primary display. A window
    /// whose middle crosses onto another display is on the desktop that display is showing.
    var rect: CGRect {
        didSet { system.rehome(self) }
    }
    var role = kAXWindowRole
    var subrole = kAXStandardWindowSubrole
    var resizable = true
    var movable = true
    /// The window does not get smaller than this.
    var minSize = CGSize.zero
    var minimised = false
    var fullscreen = false
    /// True for a window that exists and is not on screen for a reason of the system's own:
    /// a native tab that is not the one in front, or a window in another Stage Manager stage.
    var offScreen = false
    /// False for a window whose app is busy: it tells nothing and takes no request.
    var answers = true
    var hasCloseButton = true
    /// The Spaces the window is on. More than one for a window assigned to all desktops.
    var spaces: Set<UInt64>
    /// Whether the window follows the pointer when it is held at this point of its title bar.
    var canBeDraggedAt: (CGPoint) -> Bool = { _ in true }

    /// How often the window was asked to come to the front of its app's windows.
    private(set) var raises = 0
    /// Every size the window was asked to take, oldest first.
    private(set) var sizesAsked: [CGSize] = []
    private(set) var positionsAsked: [CGPoint] = []

    init(id: CGWindowID, app: FakeApp, system: FakeWindowSystem, title: String, rect: CGRect, spaces: Set<UInt64>) {
        self.id = id
        self.app = app
        self.system = system
        self.title = title
        self.rect = rect
        self.spaces = spaces
        super.init()
        pid = app.processIdentifier
    }

    override var windowID: CGWindowID? { id }

    override func string(_ name: String) -> String? {
        guard answers else { return nil }
        switch name {
        case kAXTitleAttribute: return title
        case kAXRoleAttribute: return role
        case kAXSubroleAttribute: return subrole
        default: return nil
        }
    }

    override func bool(_ name: String) -> Bool? {
        guard answers else { return nil }
        switch name {
        case kAXMinimizedAttribute: return minimised
        case "AXFullScreen": return fullscreen
        case kAXMainAttribute: return app.focusedWindow === self
        default: return nil
        }
    }

    override func element(_ name: String) -> UIElement? {
        guard answers else { return nil }
        // The traffic lights, where macOS draws them.
        func button(_ index: Int, press: @escaping () -> Void = {}) -> FakeButton {
            FakeButton(pid: pid, rect: { [unowned self] in CGRect(x: rect.minX + 9 + CGFloat(index) * 20, y: rect.minY + 7, width: 14, height: 14) }, press: press)
        }
        switch name {
        case kAXCloseButtonAttribute: return hasCloseButton ? button(0) { [unowned self] in system.close(self) } : nil
        case kAXMinimizeButtonAttribute: return button(1) { [unowned self] in system.minimise(self) }
        case kAXZoomButtonAttribute: return button(2)
        default: return nil
        }
    }

    override func isSettable(_ name: String) -> Bool {
        guard answers else { return false }
        switch name {
        case kAXSizeAttribute: return resizable
        case kAXPositionAttribute: return movable
        default: return false
        }
    }

    override var position: CGPoint? { answers ? rect.origin : nil }
    override var size: CGSize? { answers ? rect.size : nil }

    @discardableResult
    override func setPosition(_ p: CGPoint) -> Bool {
        guard answers, movable else { return false }
        positionsAsked.append(p)
        guard p != rect.origin else { return true }
        rect.origin = p
        system.appSays(self, kAXWindowMovedNotification)
        return true
    }

    @discardableResult
    override func setSize(_ s: CGSize) -> Bool {
        guard answers, resizable else { return false }
        sizesAsked.append(s)
        let taken = CGSize(width: max(s.width, minSize.width), height: max(s.height, minSize.height))
        guard taken != rect.size else { return true }
        rect.size = taken
        system.appSays(self, kAXWindowResizedNotification)
        return true
    }

    @discardableResult
    override func set(_ name: String, _ value: Bool) -> Bool {
        guard answers else { return false }
        switch name {
        case kAXMainAttribute:
            if value { system.makeMain(self) }
            return true
        case kAXMinimizedAttribute:
            if value { system.minimise(self) } else { system.unminimise(self) }
            return true
        default:
            return false
        }
    }

    @discardableResult
    override func perform(_ action: String) -> Bool {
        guard answers, action == kAXRaiseAction else { return false }
        raises += 1
        system.bringToFront(self)
        return true
    }
}

/// What an app says about itself to Accessibility.
final class FakeAppElement: FakeElement {
    fileprivate weak var app: FakeApp?

    override func elements(_ name: String) -> [UIElement]? {
        guard let app, app.answers, name == kAXWindowsAttribute else { return nil }
        return app.windows
    }

    override func element(_ name: String) -> UIElement? {
        guard let app, app.answers, name == kAXFocusedWindowAttribute else { return nil }
        return app.focusedWindow
    }
}

final class FakeApp: RunningApp {
    let processIdentifier: pid_t
    var localizedName: String?
    var bundleIdentifier: String?
    var bundleURL: URL?
    var isTerminated = false
    var isHidden = false
    var isRegular = true
    /// False for an app whose windows cannot be listed right now.
    var answers = true
    /// False for an app that has only just launched: it cannot be observed yet.
    var readyToBeObserved = true

    let element = FakeAppElement()
    private unowned let system: FakeWindowSystem
    fileprivate(set) var windows: [FakeWindow] = []
    /// The window the app says has the keyboard among its own.
    fileprivate(set) weak var focusedWindow: FakeWindow?
    /// How often the app was asked to come forward as a whole.
    private(set) var activations = 0

    init(pid: pid_t, name: String, bundleID: String?, system: FakeWindowSystem) {
        processIdentifier = pid
        localizedName = name
        bundleIdentifier = bundleID
        bundleURL = URL(fileURLWithPath: "/Applications/\(name).app")
        self.system = system
        element.pid = pid
        element.app = self
    }

    @discardableResult
    func unhide() -> Bool {
        system.unhide(self)
        return true
    }

    func comeForward() {
        activations += 1
        system.activate(self)
    }
}

private final class FakeObserver: AppObserver {
    private unowned let app: FakeApp
    let handler: (UIElement, String) -> Void
    private var watched: [(notification: String, element: ObjectIdentifier)] = []
    private(set) var stopped = false

    init(app: FakeApp, handler: @escaping (UIElement, String) -> Void) {
        self.app = app
        self.handler = handler
    }

    @discardableResult
    func watch(_ notification: String, on element: UIElement) -> Bool {
        guard app.readyToBeObserved else { return false }
        if !watches(notification, on: element) { watched.append((notification, ObjectIdentifier(element))) }
        return true
    }

    func watches(_ notification: String, on element: UIElement) -> Bool {
        watched.contains { $0.notification == notification && $0.element == ObjectIdentifier(element) }
    }

    func stop() { stopped = true }
}

struct FakeSpace {
    let id: UInt64
    let uuid: String
    /// False for the Space of an app in native fullscreen.
    var isDesktop = true
}

final class FakeDisplay {
    let uuid: String
    var name: String
    /// Whole display, top-left coordinates.
    var frame: CGRect
    /// The display minus the menu bar and the Dock.
    var visibleFrame: CGRect
    fileprivate(set) var spaces: [FakeSpace] = []
    /// The Space being shown, as a position in `spaces`.
    fileprivate(set) var current = 0

    var currentSpace: FakeSpace { spaces[current] }

    init(uuid: String, name: String, frame: CGRect, visibleFrame: CGRect) {
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

final class FakeWindowSystem: WindowSystem {
    let scheduler: FakeScheduler

    init(scheduler: FakeScheduler) {
        self.scheduler = scheduler
    }

    // MARK: What the test arranges

    var isTrusted = true
    var stageManager = StageManager.State()
    var reduceMotion = false
    private(set) var displayList: [FakeDisplay] = []
    private(set) var apps: [FakeApp] = []
    /// Every window, front to back.
    private(set) var order: [FakeWindow] = []
    private(set) weak var frontmost: FakeApp?
    private var nextWindow: CGWindowID = 100
    private var nextPID: pid_t = 5000
    private var nextSpace: UInt64 = 1

    /// False to make the direct way of focusing a window fail, so the window manager goes through the app.
    var directFocusWorks = true
    /// False to make every way of focusing a window report success and change nothing.
    var focusSticks = true
    /// False for a macOS without the window-management bridge.
    var hasMoveBridge = true
    /// False to make the bridge take a request and not move the window.
    var bridgeMovesWindows = true
    /// False to make the Mission Control shortcuts do nothing, as when one has no keys.
    var shortcutsWork = true
    /// Apps that are installed, by bundle id.
    var installed: [String: URL] = [:]
    /// What is in the folders apps are kept in.
    var folders: [String: [String]] = [:]
    var homeDirectory = "/Users/test"
    /// What opening an app fails with. Nil when it opens.
    var openFailure: String?

    // MARK: What the window manager did

    private(set) var pressed: [Int32] = []
    private(set) var warps: [CGPoint] = []
    private(set) var posted: [(type: CGEventType, point: CGPoint)] = []
    private(set) var focusRequests: [CGWindowID] = []
    private(set) var moveRequests: [(window: CGWindowID, space: UInt64)] = []
    private(set) var opened: [URL] = []
    private(set) var terminated = false
    private(set) var started = false

    private var handler: ((SystemEvent) -> Void)?
    private var observers: [pid_t: FakeObserver] = [:]

    // MARK: Displays and Spaces

    /// Add a display with a menu bar across the top. The first one added is the main display.
    @discardableResult
    func addDisplay(_ name: String = "Built-in Display", frame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
                    menuBar: CGFloat = 25, desktops: Int = 1) -> FakeDisplay {
        let visible = CGRect(x: frame.minX, y: frame.minY + menuBar, width: frame.width, height: frame.height - menuBar)
        let display = FakeDisplay(uuid: "display-\(displayList.count + 1)", name: name, frame: frame, visibleFrame: visible)
        displayList.append(display)
        for _ in 0..<max(1, desktops) { addDesktop(to: display) }
        handler?(.spaceChanged)
        return display
    }

    func removeDisplay(_ display: FakeDisplay) {
        displayList.removeAll { $0 === display }
        handler?(.spaceChanged)
    }

    @discardableResult
    func addDesktop(to display: FakeDisplay) -> FakeSpace {
        let space = FakeSpace(id: nextSpace, uuid: "space-uuid-\(nextSpace)")
        nextSpace += 1
        // Desktops come before the fullscreen Spaces, as Mission Control keeps them.
        let at = display.spaces.lastIndex { $0.isDesktop }.map { $0 + 1 } ?? 0
        display.spaces.insert(space, at: at)
        if display.spaces.count > 1, display.current >= at { display.current += 1 }
        return space
    }

    /// Add the Space of an app in native fullscreen.
    @discardableResult
    func addFullscreenSpace(to display: FakeDisplay) -> FakeSpace {
        let space = FakeSpace(id: nextSpace, uuid: "space-uuid-\(nextSpace)", isDesktop: false)
        nextSpace += 1
        display.spaces.append(space)
        return space
    }

    /// Show another Space on a display, as a swipe or Mission Control does.
    func show(_ space: FakeSpace, on display: FakeDisplay) {
        guard let index = display.spaces.firstIndex(where: { $0.id == space.id }), index != display.current else { return }
        display.current = index
        // A window that is being held comes along.
        if let held { held.window.spaces = [space.id] }
        handler?(.spaceChanged)
    }

    /// Show the desktop with this number, counted across the displays as Mission Control counts.
    func showDesktop(_ number: Int) {
        var n = 0
        for display in displayList {
            for space in display.spaces where space.isDesktop {
                n += 1
                if n == number { return show(space, on: display) }
            }
        }
    }

    private var showing: Set<UInt64> { Set(displayList.map(\.currentSpace.id)) }

    private func display(at point: CGPoint) -> FakeDisplay? {
        displayList.first { $0.frame.contains(point) }
    }

    // MARK: Apps and windows

    @discardableResult
    func launch(_ name: String, bundleID: String? = nil, regular: Bool = true) -> FakeApp {
        let app = FakeApp(pid: nextPID, name: name, bundleID: bundleID ?? "com.example.\(name.lowercased().replacingOccurrences(of: " ", with: "-"))", system: self)
        nextPID += 1
        app.isRegular = regular
        apps.append(app)
        handler?(.launched(app))
        return app
    }

    func quit(_ app: FakeApp) {
        for window in app.windows { remove(window) }
        app.isTerminated = true
        apps.removeAll { $0 === app }
        if frontmost === app { frontmost = order.first { isOnScreen($0) }?.app }
        handler?(.terminated(app))
    }

    /// Open a window. It comes to the front and takes the keyboard, as a new window does,
    /// unless `focus` is false. It is on the desktop its display is showing, or on `space`.
    @discardableResult
    func open(_ app: FakeApp, title: String = "", frame: CGRect? = nil, on space: FakeSpace? = nil, focus: Bool = true) -> FakeWindow {
        let rect = frame ?? CGRect(x: 200 + CGFloat(order.count) * 20, y: 120 + CGFloat(order.count) * 20, width: 640, height: 480)
        let home = display(at: CGPoint(x: rect.midX, y: rect.midY)) ?? displayList[0]
        let window = FakeWindow(id: nextWindow, app: app, system: self, title: title, rect: rect, spaces: [space?.id ?? home.currentSpace.id])
        nextWindow += 1
        app.windows.append(window)
        if focus && isOnScreen(window) {
            order.insert(window, at: 0)
            app.focusedWindow = window
            frontmost = app
        } else {
            order.append(window)
            if app.focusedWindow == nil { app.focusedWindow = window }
        }
        appSays(window, kAXWindowCreatedNotification)
        return window
    }

    func close(_ window: FakeWindow) {
        guard order.contains(where: { $0 === window }) else { return }
        remove(window)
        let app = window.app
        if app.focusedWindow == nil { app.focusedWindow = order.first { $0.app === app } }
        // The destroyed notification goes to whoever asked about this window.
        if let observer = observers[app.processIdentifier], !observer.stopped,
           observer.watches(kAXUIElementDestroyedNotification, on: window) {
            scheduler.after(0) { observer.handler(window, kAXUIElementDestroyedNotification) }
        }
    }

    private func remove(_ window: FakeWindow) {
        order.removeAll { $0 === window }
        window.app.windows.removeAll { $0 === window }
        if window.app.focusedWindow === window { window.app.focusedWindow = nil }
        if held?.window === window { held = nil }
    }

    func window(_ id: CGWindowID) -> FakeWindow? {
        order.first { $0.id == id }
    }

    /// The user clicks a window: it comes to the front and takes the keyboard.
    func click(_ window: FakeWindow) {
        bringToFront(window)
        let app = window.app
        let changed = app.focusedWindow !== window
        app.focusedWindow = window
        let activated = frontmost !== app
        frontmost = app
        if changed { appSays(window, kAXFocusedWindowChangedNotification) }
        if activated { handler?(.activated(app)) }
    }

    func minimise(_ window: FakeWindow) {
        guard !window.minimised else { return }
        window.minimised = true
        appSays(window, kAXWindowMiniaturizedNotification)
    }

    func unminimise(_ window: FakeWindow) {
        guard window.minimised else { return }
        window.minimised = false
        appSays(window, kAXWindowDeminiaturizedNotification)
    }

    func hide(_ app: FakeApp) {
        guard !app.isHidden else { return }
        app.isHidden = true
        handler?(.visibilityChanged)
    }

    func unhide(_ app: FakeApp) {
        guard app.isHidden else { return }
        app.isHidden = false
        handler?(.visibilityChanged)
    }

    /// Put a window on another Space behind the window manager's back, as Mission Control does.
    func put(_ window: FakeWindow, on space: FakeSpace) {
        window.spaces = [space.id]
    }

    /// A window whose middle has crossed onto another display is on the desktop that display
    /// is showing, as macOS has it. One assigned to several desktops stays on them.
    fileprivate func rehome(_ window: FakeWindow) {
        guard window.spaces.count == 1, let space = window.spaces.first,
              let now = display(at: CGPoint(x: window.rect.midX, y: window.rect.midY)),
              !now.spaces.contains(where: { $0.id == space }) else { return }
        window.spaces = [now.currentSpace.id]
    }

    func isOnScreen(_ window: FakeWindow) -> Bool {
        !window.minimised && !window.offScreen && !window.app.isHidden && !window.spaces.isDisjoint(with: showing)
    }

    fileprivate func bringToFront(_ window: FakeWindow) {
        guard let index = order.firstIndex(where: { $0 === window }) else { return }
        order.remove(at: index)
        order.insert(window, at: 0)
    }

    fileprivate func makeMain(_ window: FakeWindow) {
        guard focusSticks else { return }
        window.app.focusedWindow = window
    }

    fileprivate func activate(_ app: FakeApp) {
        guard focusSticks else { return }
        frontmost = app
    }

    /// An app tells its observers about one of its windows a moment after the fact, on the main thread.
    fileprivate func appSays(_ window: FakeWindow, _ notification: String) {
        scheduler.after(0) { [weak self, weak window] in
            guard let self, let window, let observer = self.observers[window.pid], !observer.stopped,
                  observer.watches(notification, on: window.app.element) || observer.watches(notification, on: window) else { return }
            observer.handler(window, notification)
        }
    }

    // MARK: The user's hand

    var pointerLocation: CGPoint? = CGPoint(x: 720, y: 450)
    var leftMouseIsDown = false
    /// The window that follows the pointer, and where in it the pointer has hold of it.
    private var held: (window: FakeWindow, offset: CGPoint)?

    /// The user presses the mouse on a window's title bar and moves it so that the window's
    /// top-left corner is at `origin`. The button stays down until `releaseMouse()`.
    func drag(_ window: FakeWindow, to origin: CGPoint) {
        leftMouseIsDown = true
        pointerLocation = CGPoint(x: origin.x + window.rect.width / 2, y: origin.y + 10)
        guard window.rect.origin != origin else { return }
        window.rect.origin = origin
        appSays(window, kAXWindowMovedNotification)
    }

    /// The user drags an edge of a window: it changes size. The button stays down until `releaseMouse()`.
    func resize(_ window: FakeWindow, to rect: CGRect) {
        leftMouseIsDown = true
        guard window.rect != rect else { return }
        let moved = window.rect.origin != rect.origin
        window.rect = rect
        if moved { appSays(window, kAXWindowMovedNotification) }
        appSays(window, kAXWindowResizedNotification)
    }

    func releaseMouse() {
        leftMouseIsDown = false
        held = nil
        handler?(.leftMouseUp)
    }

    // MARK: - WindowSystem

    func start(_ handler: @escaping (SystemEvent) -> Void) {
        started = true
        self.handler = handler
    }

    func runningApps() -> [RunningApp] { apps }
    var frontmostPID: pid_t? { frontmost?.processIdentifier }

    func element(forApp pid: pid_t) -> UIElement {
        apps.first { $0.processIdentifier == pid }?.element ?? FakeElement()
    }

    func observer(for pid: pid_t, _ handler: @escaping (UIElement, String) -> Void) -> AppObserver? {
        guard let app = apps.first(where: { $0.processIdentifier == pid }), app.readyToBeObserved else { return nil }
        let observer = FakeObserver(app: app, handler: handler)
        observers[pid] = observer
        return observer
    }

    func appURL(bundleID: String) -> URL? {
        installed.first { $0.key.lowercased() == bundleID.lowercased() }?.value
    }

    func contents(ofFolders folders: [String]) -> [String] {
        folders.flatMap { folder in (self.folders[folder] ?? []).map { "\(folder)/\($0)" } }
    }

    func openApp(at url: URL, failed: @escaping (String) -> Void) {
        opened.append(url)
        if let openFailure { scheduler.after(0) { failed(openFailure) } }
    }

    func terminate() { terminated = true }

    func snapshot() -> ScreenSnapshot {
        var snap = ScreenSnapshot()
        for window in order {
            snap.all.insert(window.id)
            guard isOnScreen(window) else { continue }
            snap.onScreen[window.id] = window.rect
            snap.order.append(window.id)
        }
        return snap
    }

    func displays() -> [DisplayInfo] {
        let total = displayList.reduce(0) { $0 + $1.spaces.filter(\.isDesktop).count }
        var offset = 0
        var list: [DisplayInfo] = []
        for (i, display) in displayList.enumerated() {
            let desktops = display.spaces.filter(\.isDesktop)
            let current = display.currentSpace
            list.append(DisplayInfo(
                uuid: display.uuid, managedID: display.uuid, name: display.name, frame: display.frame, visibleFrame: display.visibleFrame,
                spaceID: current.id, spaceKey: current.uuid,
                spaceIndex: desktops.firstIndex { $0.id == current.id }.map { $0 + 1 },
                spaceCount: desktops.count, desktopOffset: offset, totalDesktops: total, isMain: i == 0))
            offset += desktops.count
        }
        for (i, n) in DisplayOrder.numbers(list.map(\.frame)).enumerated() {
            list[i].number = n
            list[i].stage = stageManager
        }
        return list
    }

    func desktops() -> [Desktop] {
        var result: [Desktop] = []
        for display in displayList {
            for space in display.spaces where space.isDesktop {
                result.append(Desktop(id: space.id, key: space.uuid, displayID: display.uuid, number: result.count + 1))
            }
        }
        return result
    }

    func spaces(of window: CGWindowID) -> [UInt64] {
        self.window(window).map { $0.spaces.sorted() } ?? []
    }

    func serverOrigin(of window: CGWindowID) -> CGPoint? {
        self.window(window)?.rect.origin
    }

    func windowOwners() -> [CGWindowID: pid_t] {
        Dictionary(uniqueKeysWithValues: order.map { ($0.id, $0.pid) })
    }

    func focus(pid: pid_t, window id: CGWindowID) -> Bool {
        focusRequests.append(id)
        guard directFocusWorks, let window = window(id), window.pid == pid else { return false }
        guard focusSticks else { return true }
        bringToFront(window)
        window.app.focusedWindow = window
        frontmost = window.app
        return true
    }

    func requestMove(window id: CGWindowID, toSpace space: UInt64) -> Bool {
        moveRequests.append((id, space))
        guard hasMoveBridge, let window = window(id) else { return false }
        if bridgeMovesWindows { window.spaces = [space] }
        return true
    }

    func press(shortcut: Int32) -> Bool {
        pressed.append(shortcut)
        guard shortcutsWork else { return false }
        switch shortcut {
        case Private.SystemShortcut.spaceLeft, Private.SystemShortcut.spaceRight:
            // The display the pointer is on is the one that changes.
            guard let display = pointerLocation.flatMap(display(at:)) ?? displayList.first else { return true }
            let next = display.current + (shortcut == Private.SystemShortcut.spaceRight ? 1 : -1)
            if display.spaces.indices.contains(next) { show(display.spaces[next], on: display) }
        default:
            showDesktop(Int(shortcut) - 117)
        }
        return true
    }

    func warpPointer(to point: CGPoint) {
        warps.append(point)
        pointerLocation = point
    }

    func postMouse(_ type: CGEventType, at point: CGPoint) {
        posted.append((type, point))
        switch type {
        case .leftMouseDown:
            leftMouseIsDown = true
            pointerLocation = point
            // The window in front under the pointer is taken hold of, if that spot drags it.
            if let window = order.first(where: { isOnScreen($0) && $0.rect.contains(point) }),
               point.y - window.rect.minY <= 28, window.canBeDraggedAt(point) {
                held = (window, CGPoint(x: point.x - window.rect.minX, y: point.y - window.rect.minY))
            }
        case .leftMouseDragged:
            pointerLocation = point
            if let held {
                held.window.rect.origin = CGPoint(x: point.x - held.offset.x, y: point.y - held.offset.y)
                appSays(held.window, kAXWindowMovedNotification)
            }
        case .leftMouseUp:
            pointerLocation = point
            releaseMouse()
        default:
            pointerLocation = point
        }
    }
}
