import AppKit
import IguanaCore
import SwiftUI

/// The welcome tour: a small desktop to practise on, run by the same layout engine that arranges
/// real windows, and the goals that lead through it. It hears the real shortcuts, so what is
/// learned here is exactly what works afterwards.
final class TourModel: ObservableObject {
    enum Permission { case idle, waiting, granted }
    enum DesktopGoal { case jump, carry }
    /// The stack lesson has two halves: make the stack, then reach a window behind the front one.
    enum StackGoal { case press, step }

    /// The play desktop is laid out in these units and scaled to the screen by the view.
    static let stage = CGSize(width: 1600, height: 1000)
    static let windowsToOpen = 3
    static let desktopCount = 3
    static let focusTargets = 3
    /// The colours of the two windows the tour opens by itself, as places in the palette.
    static let desktopColor = 3
    static let stackColor = 4

    // Only the model writes its state. Much of it is not private because the model's own
    // extensions, in the `TourModel+….swift` files, write it too.
    @Published var step: TourStep = .hello
    @Published var revision = 0
    @Published var current = 0
    @Published var overview = false
    @Published var beacon: WindowID?
    @Published var desktopBeacon: Int?
    @Published var ghost: TourGhost?
    @Published var desktopGoal = DesktopGoal.jump
    @Published var stackGoal = StackGoal.press
    @Published var lit: Set<String> = []
    @Published var held: Set<Modifier> = []
    @Published var reached = 0
    @Published var celebrations = 0
    @Published var refusals = 0
    @Published var permission = Permission.idle
    @Published private(set) var closing = false
    @Published private(set) var skipArmed = false
    @Published private(set) var muted = false
    @Published var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    var desktops: [Tree] = (0..<desktopCount).map { _ in Tree() }
    var colors: [WindowID: Int] = [:]
    let bindings: [KeyBinding]
    let resizeStep: Double

    // The world outside, replaceable in tests.
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var promptForTrust: () -> Void = {}
    var play: (TourSound.Cue) -> Void = { _ in }
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var setLoginItem: ((Bool) -> String?)?
    /// The tour steps aside for System Settings, or comes back in front of it.
    var onYield: (Bool) -> Void = { _ in }
    var onMute: (Bool) -> Void = { _ in }
    /// The tour is over. `completed` is false when it was left early.
    var onClose: (_ completed: Bool) -> Void = { _ in }

    var nextID: WindowID = 1
    /// The windows from front to back. Tiles never cover each other, so this only shows in a stack.
    var order: [WindowID] = []
    var visits: [WindowID: Int] = [:]
    var clock = 0
    var advancing = false
    var goalWindow: WindowID?
    var goalDirection = Direction.left
    var movesMade = 0
    var growsNeeded = 3
    private var trustTimer: Timer?
    private var prompted = false

    init(config: Config) {
        bindings = config.bindings
        // Small steps are hard to see on a desktop this size.
        resizeStep = min(max(config.resizeStep, 0.04), 0.12)
    }

    deinit { trustTimer?.invalidate() }

    // MARK: Permission

    func watchTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkTrust() }
    }

    func checkTrust() {
        guard step == .permission, permission != .granted, isTrusted() else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { permission = .granted }
        play(.granted)
        onYield(false)
        after(1.6) { [weak self] in
            guard let self, self.step == .permission else { return }
            self.advance()
        }
    }

    func requestPermission() {
        guard permission != .granted else { return }
        // System Settings has to be able to come in front of the tour.
        onYield(true)
        withAnimation(.easeOut(duration: 0.3)) { permission = .waiting }
        if prompted {
            openAccessibilitySettings()
        } else {
            prompted = true
            promptForTrust()
        }
    }

    func openAccessibilitySettings() {
        onYield(true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Leaving

    func setLaunchAtLogin(_ value: Bool) {
        launchAtLoginError = setLoginItem?(value)
        launchAtLogin = launchAtLoginError == nil ? value : !value
    }

    func toggleMute() {
        muted.toggle()
        onMute(muted)
    }

    func skipStep() {
        guard step.isLesson else { return }
        advance()
    }

    /// Escape. The first press asks, the second leaves; the permission is still asked for on the
    /// way out, because nothing works without it.
    func escape() {
        guard !closing else { return }
        guard skipArmed else {
            skipArmed = true
            after(2.6) { [weak self] in self?.skipArmed = false }
            return
        }
        skipArmed = false
        if step < .permission, isAvailable(.permission) {
            go(to: .permission)
        } else {
            close(completed: step == .done)
        }
    }

    func finish() {
        guard !closing else { return }
        play(.finale)
        close(completed: true)
    }

    private func close(completed: Bool) {
        trustTimer?.invalidate()
        trustTimer = nil
        withAnimation(.timingCurve(0.7, 0, 0.25, 1, duration: 0.85)) { closing = true }
        after(0.9) { [weak self] in self?.onClose(completed) }
    }
}
