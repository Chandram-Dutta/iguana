import AppKit
import IguanaCore

/// The welcome tour as the rest of the app shell sees it: showing it, holding tiling back
/// until it ends, and handing it the shortcuts and commands meant for its practice desktop.
final class WelcomeTour {
    private let wm: WindowManager
    private let defaults: UserDefaults
    private var controller: TourWindowController?
    /// Tiling waits for the welcome tour to end, so that the windows fall into place as it lifts.
    private(set) var isHoldingStart = false
    private static let seenKey = "tourSeen"

    /// Where the menu bar item is on screen, which the tour points at.
    var irisTarget: () -> CGRect? = { nil }
    /// The tour has left the screen.
    var onEnd: (() -> Void)?

    init(wm: WindowManager, defaults: UserDefaults = .standard) {
        self.wm = wm
        self.defaults = defaults
    }

    var isShowing: Bool { controller?.isShowing == true }
    /// False the first time Iguana runs, which is when it introduces itself.
    var hasBeenSeen: Bool { defaults.bool(forKey: Self.seenKey) }

    /// Start tiling now, or when the tour ends if it is on screen.
    func startTiling() {
        if isShowing {
            isHoldingStart = true
        } else {
            wm.start()
        }
    }

    func show() {
        // The tour teaches the keys of [bindings].
        wm.switchMode(Config.defaultMode)
        if controller == nil {
            let made = TourWindowController(config: wm.config) { [weak self] in self?.irisTarget() }
            made.onFinish = { [weak self] completed in
                guard let self else { return }
                Log.write(completed ? "welcome tour finished" : "welcome tour left early")
                self.defaults.set(true, forKey: Self.seenKey)
                self.controller = nil
                if self.isHoldingStart {
                    self.isHoldingStart = false
                    self.wm.start()
                }
                self.onEnd?()
            }
            controller = made
        }
        controller?.show()
    }

    /// While the tour is on screen, shortcuts and commands act on its practice desktop.
    /// Nil when the command is for the real windows.
    func reply(to command: Command, binding: KeyBinding? = nil, window: CGWindowID? = nil) -> String? {
        // Only while the tour has the keyboard. With another app in front, shortcuts and commands
        // are meant for the real windows.
        guard let controller, controller.isInFront else { return nil }
        // A request that names a real window would otherwise land on the practice desktop.
        if window != nil { return "error: not while the welcome tour is on screen" }
        return controller.model.handle(command, binding: binding)
    }
}
