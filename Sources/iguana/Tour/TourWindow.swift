import AppKit
import ApplicationServices
import IguanaCore
import ServiceManagement
import SwiftUI

private final class TourWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // A key that means nothing in the tour is ignored in silence. Left to the system, it would
    // answer every such key with its alert sound.
    override func keyDown(with event: NSEvent) {}
    override func noResponder(for eventSelector: Selector) {}
}

/// Shows the welcome tour over the whole screen and connects it to the keyboard, the sound and
/// the system.
final class TourWindowController: NSObject {
    let model: TourModel
    /// Called once the tour has left the screen. `completed` is false when it was left early.
    var onFinish: ((_ completed: Bool) -> Void)?

    private let sound = TourSound()
    private let irisTarget: () -> CGRect?
    private var window: TourWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var yielding = false
    /// Above the menu bar and the Dock, so that nothing of the desktop shows through.
    private static let raised = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)

    init(config: Config, irisTarget: @escaping () -> CGRect?) {
        model = TourModel(config: config)
        self.irisTarget = irisTarget
        super.init()
        model.play = { [sound] in sound.play($0) }
        model.onMute = { [sound] in sound.muted = $0 }
        model.promptForTrust = {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        model.setLoginItem = { value in
            do {
                if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                return nil
            } catch {
                return "macOS did not accept that: \(error.localizedDescription)"
            }
        }
        model.onYield = { [weak self] yield in self?.yield(yield) }
        model.onClose = { [weak self] completed in self?.close(completed: completed) }
    }

    var isShowing: Bool { window != nil }
    /// The tour is what the keyboard is talking to.
    var isInFront: Bool { window?.isKeyWindow ?? false }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let window = TourWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = Self.raised
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: TourView(model: model, safeTop: screen.safeAreaInsets.top,
                                                              irisPoint: irisPoint(on: screen)))
        window.setFrame(screen.frame, display: true)
        window.alphaValue = 0
        self.window = window

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.key(event) ?? event
        }
        let center = NotificationCenter.default
        observers = [
            // Another app in front must be able to cover the tour.
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.window?.level = .normal
                self?.model.held = []
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.yielding else { return }
                self.window?.level = Self.raised
            },
        ]

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.model.begin() }
    }

    /// The middle of the menu bar item, in the tour's own coordinates (y grows downwards).
    private func irisPoint(on screen: NSScreen) -> CGPoint? {
        guard let target = irisTarget(), target.width > 0 else { return nil }
        return CGPoint(x: target.midX - screen.frame.minX, y: screen.frame.maxY - target.midY)
    }

    private func key(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window || window.isKeyWindow else { return event }
        if event.type == .flagsChanged {
            var held = Set<Modifier>()
            if event.modifierFlags.contains(.option) { held.insert(.alt) }
            if event.modifierFlags.contains(.shift) { held.insert(.shift) }
            if event.modifierFlags.contains(.control) { held.insert(.ctrl) }
            if event.modifierFlags.contains(.command) { held.insert(.cmd) }
            if held != model.held { model.held = held }
            return event
        }
        // Command shortcuts (Quit) stay with the menu.
        if event.modifierFlags.contains(.command) { return event }
        switch event.keyCode {
        case 36, 76, 49: if !event.isARepeat { model.primary() }
        case 53: if !event.isARepeat { model.escape() }
        default: break
        }
        return nil
    }

    private func yield(_ yield: Bool) {
        yielding = yield
        guard let window else { return }
        if yield {
            window.level = .normal
        } else {
            window.level = Self.raised
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func close(completed: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window?.orderOut(nil)
        window = nil
        // Let the last notes ring out before the sound engine is shut down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [sound] in sound.stop() }
        onFinish?(completed)
    }
}

/// Renders the scenes of the tour to PNG files, and its sounds to WAV files. A development aid
/// (`iguana debug-tour <folder>`): it never talks to the running window manager.
enum TourSnapshot {
    /// `only` limits the pictures to the scenes whose name contains it.
    static func run(folder: String, only: String? = nil) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if only == nil { TourSound.export(to: out) }

        let size = NSSize(width: 1470, height: 956)
        let scenes: [(String, () -> TourModel)] = [
            ("1-hello", { .preview(.hello) }),
            ("2-open-empty", { .preview(.open) }),
            ("2-open-two", { .preview(.open, variant: 2) }),
            ("3-focus", { .preview(.focus) }),
            ("4-move", { .preview(.move) }),
            ("5-resize", { .preview(.resize) }),
            ("6-desktops-jump", { .preview(.desktops) }),
            ("6-desktops-carry", { .preview(.desktops, variant: 1) }),
            ("7-permission", { .preview(.permission) }),
            ("7-permission-waiting", { .preview(.permission, variant: 1) }),
            ("7-permission-granted", { .preview(.permission, variant: 2) }),
            ("8-done", { .preview(.done) }),
        ]
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        let origin = SnapshotStage.origin
        SnapshotStage.prepare()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, make) in scenes where (only == nil || name.contains(only ?? "")) && SnapshotStage.wants("\(name)-\(appearance == .aqua ? "light" : "dark")") {
                let model = make()
                if name == "3-focus" { model.held = [.alt] }
                let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.appearance = NSAppearance(named: appearance)
                window.contentView = NSHostingView(rootView: TourView(model: model, safeTop: 38))
                window.setFrame(NSRect(origin: origin, size: size), display: true)
                window.orderFrontRegardless()
                spin(name == "1-hello" ? 2.6 : 1.3)
                let file = out.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png")
                SnapshotStage.write(SnapshotStage.capture(window), to: file)
                window.orderOut(nil)
            }
        }
        exit(0)
    }
}
