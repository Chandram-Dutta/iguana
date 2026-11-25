import AppKit
import ApplicationServices
import IguanaCore

/// The app delegate. It makes the parts of the app shell and connects them to the window
/// manager and to each other. What each part does is in its own file in this folder.
final class Daemon: NSObject, NSApplicationDelegate {
    private let wm = WindowManager()
    /// `focus-follows-mouse`: gives the focus to the window the pointer rests on.
    private let pointerFocus = FocusFollowsMouse()
    /// The window switcher (`switcher`).
    private let switcher = SwitcherController()
    /// The commands of `[hooks]`, run when something changes.
    private let hooks = Hooks()
    /// Looks once a day whether a newer Iguana has been released.
    private let updates = UpdateChecker()
    /// The ring around the focused window (`[focus-ring]`).
    private let focusRing = FocusRing()
    /// The outline that shows where a tiled window being dragged will land.
    private let dragPreview = DragPreview()
    private let icons = AppIcons()
    private let mainMenu = MainMenu()
    private let configWatcher = ConfigWatcher()
    private let tour: WelcomeTour
    private let shortcuts: HotkeyRegistrar
    private let statusItem: StatusItemController
    private let report: ShellReport
    private let requests: RequestHandler
    private let settingsBackend: AppSettingsBackend
    private var settings: SettingsWindowController?
    private var trustTimer: Timer?

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        if IPC.send("status") != nil {
            FileHandle.standardError.write(Data("Iguana is already running.\n".utf8))
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = Daemon()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    /// Makes the parts and hands each what it needs of the others. Nothing here touches the
    /// system: that waits for `applicationDidFinishLaunching`.
    override init() {
        let wm = self.wm, updates = self.updates
        // The newer release to tell the user about. With the check switched off Iguana says nothing.
        let knownUpdate = { wm.config.checkForUpdates ? updates.available : nil }
        let trusted = { AXIsProcessTrusted() }
        let tour = WelcomeTour(wm: wm)
        let shortcuts = HotkeyRegistrar(wm: wm) { binding in
            tour.reply(to: binding.command, binding: binding) ?? wm.run(binding.command)
        }
        let statusItem = StatusItemController(wm: wm, icons: icons, trusted: trusted, shortcutProblems: { shortcuts.problems },
                                              knownUpdate: knownUpdate) { command in
            tour.reply(to: command) ?? wm.run(command)
        }
        let report = ShellReport(wm: wm, shortcuts: shortcuts, tourShowing: { tour.isShowing },
                                 tilingHeld: { tour.isHoldingStart }, knownUpdate: knownUpdate)
        requests = RequestHandler(run: { wm.run($0, window: $1) }, tourReply: { tour.reply(to: $0, window: $1) },
                                  jsonReport: report.json, checkForUpdate: { updates.checkNow($0) })
        settingsBackend = AppSettingsBackend(wm: wm, shortcuts: shortcuts, configWatcher: configWatcher, updates: updates,
                                             knownUpdate: knownUpdate, trusted: trusted) { [weak statusItem] in statusItem?.update() }
        tour.irisTarget = { [weak statusItem] in statusItem?.frameOnScreen }
        tour.onEnd = { [weak statusItem] in statusItem?.update() }
        statusItem.onTour = { tour.show() }
        self.tour = tour
        self.shortcuts = shortcuts
        self.statusItem = statusItem
        self.report = report
        super.init()
        statusItem.onSettings = { [weak self] in self?.openSettings() }
        mainMenu.onSettings = { [weak self] in self?.openSettings() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("Iguana \(Iguana.version) starting")
        statusItem.install()
        shortcuts.start()
        wm.onChange = { [weak self] in
            guard let self else { return }
            self.pointerFocus.changed(self.wm)
            self.statusItem.update()
            if self.settings?.isVisible == true { self.settings?.model.refresh() }
            self.hooks.changed(self.wm)
            self.focusRing.changed(self.wm)
            self.dragPreview.changed(self.wm)
        }
        wm.onFrameChange = { [weak self] element in
            self?.focusRing.moved(element)
            self?.dragPreview.moved()
        }
        wm.onDrag = { [weak self] on in
            if let self { self.dragPreview.drag(on, self.wm) }
        }
        wm.onConfigChange = { [weak self] in self?.shortcuts.register() }
        icons.forgetAppsThatQuit()
        wm.onModeChange = { [weak self] in
            // On the next turn of the run loop: the key that switched the mode is still being
            // handled, and must not fire again in the new set.
            DispatchQueue.main.async {
                self?.shortcuts.register()
                self?.statusItem.update()
            }
        }
        wm.statusExtras = { [weak self] in self?.report.statusLines() ?? [] }
        wm.onOpenSettings = { [weak self] in self?.openSettings() }
        wm.onOpenTour = { [weak self] in self?.tour.show() }
        wm.onOpenSwitcher = { [weak self] in self?.openSwitcher() ?? "error: shutting down" }
        switcher.onChoose = { [weak self] id in self?.wm.bringForward(id) }
        switcher.onClose = { [weak self] in self?.pointerFocus.suspended = false }
        wm.onCheckForUpdate = { [weak self] in self?.updates.checkNow() }
        updates.onChange = { [weak self] in self?.settings?.model.refresh() }
        updates.start { [weak self] in self?.wm.config.checkForUpdates ?? false }
        NSApp.mainMenu = mainMenu.make()
        wm.reloadConfig()
        configWatcher.mark()
        // Pick up the config file as soon as it is saved, whatever saved it.
        configWatcher.start { [weak self] in self?.configFileChanged() }

        if !IPC.listen({ [weak self] line, reply in self?.requests.handle(line, reply: reply) ?? reply("error: shutting down") },
                       subscribed: { [weak self] subscriber in if let self { self.hooks.greet(subscriber, self.wm) } }) {
            Log.write("could not open the command socket at \(IPC.socketPath)")
        }

        // The first time Iguana runs it introduces itself, and asks for its permission there.
        let firstRun = !tour.hasBeenSeen
        if firstRun { tour.show() }

        if AXIsProcessTrusted() {
            tour.startTiling()
        } else {
            if !firstRun {
                // Shows the system prompt that leads to Privacy & Security > Accessibility.
                let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            }
            Log.write("waiting for Accessibility permission")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                Log.write("Accessibility permission granted")
                self?.tour.startTiling()
                self?.statusItem.update()
            }
        }
        statusItem.update()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm.saveState()
        IPC.stop()
    }

    private func configFileChanged() {
        wm.reloadConfig()
        settings?.model.refresh()
        statusItem.update()
    }

    private func openSettings() {
        if settings == nil { settings = SettingsWindowController(backend: settingsBackend) }
        settings?.show()
    }

    /// Open the window switcher, or move its selection down a row when it is open already.
    private func openSwitcher() -> String {
        if switcher.isShowing {
            switcher.step()
            return "ok"
        }
        let (windows, owners) = wm.switcherWindows()
        guard !windows.isEmpty else { return "ok: no windows to switch to" }
        let icons = icons.icons(for: owners)
        pointerFocus.suspended = true
        switcher.show(windows, icons: icons, on: wm.facts().activeDisplay?.frame)
        return "ok"
    }
}
