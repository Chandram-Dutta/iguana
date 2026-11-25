import AppKit
import IguanaCore

// Everything the window manager asks of macOS, and everything macOS tells it.
//
// The window manager never calls Accessibility, the window server or NSWorkspace itself. It
// goes through these protocols, so the same code that tiles real windows can be run in a test
// against a desktop that is made up (`FakeWindowSystem` in the tests). The implementation
// that talks to the Mac is `MacWindowSystem`.

/// An accessibility element of another app: the app itself, one of its windows, or a button
/// in a window's title bar. The names are the ones the Accessibility API uses.
protocol UIElement: AnyObject {
    func string(_ name: String) -> String?
    func bool(_ name: String) -> Bool?
    func element(_ name: String) -> UIElement?
    func elements(_ name: String) -> [UIElement]?
    func isSettable(_ name: String) -> Bool
    var position: CGPoint? { get }
    var size: CGSize? { get }
    @discardableResult func setPosition(_ p: CGPoint) -> Bool
    @discardableResult func setSize(_ s: CGSize) -> Bool
    @discardableResult func set(_ name: String, _ value: Bool) -> Bool
    @discardableResult func perform(_ action: String) -> Bool
    /// The window server's number for a window. Nil for an element that is not a window.
    var windowID: CGWindowID? { get }
    var pid: pid_t { get }
    /// Two elements can stand for the same thing without being the same object.
    func isSame(as other: UIElement) -> Bool
}

extension UIElement {
    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }
}

/// A running app, as far as the window manager needs to know one.
protocol RunningApp: AnyObject {
    var processIdentifier: pid_t { get }
    var localizedName: String? { get }
    var bundleIdentifier: String? { get }
    var bundleURL: URL? { get }
    var isTerminated: Bool { get }
    var isHidden: Bool { get }
    /// An app with a Dock icon and windows of its own. Agents and helpers are left alone.
    var isRegular: Bool { get }
    @discardableResult func unhide() -> Bool
    func comeForward()
}

extension NSRunningApplication: RunningApp {
    var isRegular: Bool { activationPolicy == .regular }
    func comeForward() { activate() }
}

/// Listens to one app's accessibility notifications.
protocol AppObserver: AnyObject {
    /// False when the app could not be asked, and asking again later may work. A notification
    /// the app does not offer counts as done: asking again would change nothing.
    @discardableResult func watch(_ notification: String, on element: UIElement) -> Bool
    func stop()
}

/// What the system tells the window manager without being asked.
enum SystemEvent {
    case launched(RunningApp?)
    case terminated(RunningApp?)
    /// An app came to the front.
    case activated(RunningApp?)
    /// An app was hidden or shown again.
    case visibilityChanged
    /// Another Space is showing, or the displays changed.
    case spaceChanged
    case leftMouseUp
}

protocol WindowSystem: AnyObject {
    /// Whether Iguana has the Accessibility permission.
    var isTrusted: Bool { get }

    /// Start reporting events. Called once, when tiling starts.
    func start(_ handler: @escaping (SystemEvent) -> Void)

    // MARK: Apps

    func runningApps() -> [RunningApp]
    var frontmostPID: pid_t? { get }
    func element(forApp pid: pid_t) -> UIElement
    /// Nil when the app is not ready to be observed yet.
    func observer(for pid: pid_t, _ handler: @escaping (UIElement, String) -> Void) -> AppObserver?
    /// The app with this bundle id, wherever it is installed.
    func appURL(bundleID: String) -> URL?
    /// The paths of everything in these folders.
    func contents(ofFolders folders: [String]) -> [String]
    var homeDirectory: String { get }
    func openApp(at url: URL, failed: @escaping (String) -> Void)
    /// Quit Iguana.
    func terminate()

    // MARK: The screen

    func snapshot() -> ScreenSnapshot
    /// The part of `snapshot` that is on screen, for callers that ask many times a second.
    func windowsOnScreen() -> WindowsOnScreen
    func displays() -> [DisplayInfo]
    func desktops() -> [Desktop]
    /// The Spaces a window is on (more than one for a window assigned to all desktops). Empty when unknown.
    func spaces(of window: CGWindowID) -> [UInt64]
    /// Where the window server has a window right now.
    func serverOrigin(of window: CGWindowID) -> CGPoint?
    /// Every window the system has, on any desktop, and the app it belongs to.
    func windowOwners() -> [CGWindowID: pid_t]
    var stageManager: StageManager.State { get }
    var reduceMotion: Bool { get }

    // MARK: Focus and Spaces

    /// Bring one window to the front without raising the app's other windows.
    func focus(pid: pid_t, window: CGWindowID) -> Bool
    /// Whether a window can be put on another Space without going there with it.
    var hasMoveBridge: Bool { get }
    func requestMove(window: CGWindowID, toSpace space: UInt64) -> Bool
    /// Press one of the system's own Mission Control shortcuts.
    func press(shortcut: Int32) -> Bool

    // MARK: The pointer

    var pointerLocation: CGPoint? { get }
    var leftMouseIsDown: Bool { get }
    func warpPointer(to point: CGPoint)
    func postMouse(_ type: CGEventType, at point: CGPoint)
}

extension WindowSystem {
    func windowsOnScreen() -> WindowsOnScreen {
        let snap = snapshot()
        return WindowsOnScreen(order: snap.order, frames: snap.onScreen)
    }
}

/// The ordinary windows on screen, front to back, as the window server has them.
struct WindowsOnScreen {
    var order: [CGWindowID] = []
    /// Measured from the top-left corner of the primary display.
    var frames: [CGWindowID: CGRect] = [:]
}
