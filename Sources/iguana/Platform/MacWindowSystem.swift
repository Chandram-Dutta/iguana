import AppKit
import ApplicationServices
import IguanaCore

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<MacAppObserver>.fromOpaque(refcon).takeUnretainedValue().handler(AXElement(element), notification as String)
}

/// One app's accessibility notifications, delivered on the main run loop.
private final class MacAppObserver: AppObserver {
    private let observer: AXObserver
    fileprivate let handler: (UIElement, String) -> Void

    init?(pid: pid_t, handler: @escaping (UIElement, String) -> Void) {
        var made: AXObserver?
        guard AXObserverCreate(pid, axCallback, &made) == .success, let made else { return nil }
        observer = made
        self.handler = handler
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
    }

    // The callback is handed this object unretained, so it must not outlive its place on the run loop.
    deinit { stop() }

    @discardableResult
    func watch(_ notification: String, on element: UIElement) -> Bool {
        guard let ax = (element as? AXElement)?.ax else { return false }
        let e = AXObserverAddNotification(observer, ax, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
        return e == .success || e == .notificationAlreadyRegistered || e == .notificationUnsupported
    }

    func stop() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}

/// The Mac itself: Accessibility for the windows of other apps, the window server for what is
/// on screen, NSWorkspace for the apps, and the few undocumented calls in `Private`.
final class MacWindowSystem: WindowSystem {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func start(_ handler: @escaping (SystemEvent) -> Void) {
        // An app that is busy must never be able to stall the window manager. Set on the
        // system-wide element, this is the limit for every accessibility call this process makes;
        // set on an app's element it would cover that element only, and not its windows.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)

        let workspace = NSWorkspace.shared.notificationCenter
        func app(_ n: Notification) -> NSRunningApplication? {
            n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { handler(.launched(app($0))) }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { handler(.terminated(app($0))) }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { handler(.activated(app($0))) }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in handler(.visibilityChanged) }
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in handler(.spaceChanged) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            handler(.spaceChanged)
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in handler(.leftMouseUp) }
    }

    // MARK: Apps

    func runningApps() -> [RunningApp] { NSWorkspace.shared.runningApplications }

    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func element(forApp pid: pid_t) -> UIElement {
        let element = AXUIElementCreateApplication(pid)
        // An app that is busy must never be able to stall the window manager.
        AXUIElementSetMessagingTimeout(element, 0.4)
        return AXElement(element)
    }

    func observer(for pid: pid_t, _ handler: @escaping (UIElement, String) -> Void) -> AppObserver? {
        MacAppObserver(pid: pid, handler: handler)
    }

    func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func contents(ofFolders folders: [String]) -> [String] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { "\(folder)/\($0)" }
        }
    }

    var homeDirectory: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func openApp(at url: URL, failed: @escaping (String) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { failed(error.localizedDescription) }
        }
    }

    func terminate() { NSApp.terminate(nil) }

    // MARK: The screen

    func snapshot() -> ScreenSnapshot { .take() }
    func windowsOnScreen() -> WindowsOnScreen { .take() }
    func displays() -> [DisplayInfo] { DisplayInfo.current() }
    func desktops() -> [Desktop] { Desktop.all() }
    func spaces(of window: CGWindowID) -> [UInt64] { Private.spaces(of: window) }

    func serverOrigin(of window: CGWindowID) -> CGPoint? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        return rect.origin
    }

    func windowOwners() -> [CGWindowID: pid_t] {
        var owners: [CGWindowID: pid_t] = [:]
        for info in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            if let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
               let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value { owners[id] = pid }
        }
        return owners
    }

    var stageManager: StageManager.State { StageManager.current }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Focus and Spaces

    func focus(pid: pid_t, window: CGWindowID) -> Bool { Private.focus(pid: pid, windowID: window) }
    var hasMoveBridge: Bool { Private.hasMoveBridge }
    func requestMove(window: CGWindowID, toSpace space: UInt64) -> Bool { Private.requestMove(window: window, toSpace: space) }
    func press(shortcut: Int32) -> Bool { Private.press(shortcut: shortcut) }

    // MARK: The pointer

    var pointerLocation: CGPoint? { CGEvent(source: nil)?.location }
    var leftMouseIsDown: Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }
    func warpPointer(to point: CGPoint) { CGWarpMouseCursorPosition(point) }

    func postMouse(_ type: CGEventType, at point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }
}

extension WindowsOnScreen {
    /// One call, and no permission needed.
    static func take() -> WindowsOnScreen {
        var list = WindowsOnScreen()
        for info in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            list.order.append(id)
            list.frames[id] = frame
        }
        return list
    }
}
