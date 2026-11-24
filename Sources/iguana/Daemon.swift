import AppKit
import ApplicationServices
import IguanaCore
import SwiftUI

final class Daemon: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let wm = WindowManager()
    private var hotkeys: Hotkeys?
    private var statusItem: NSStatusItem?
    private var trustTimer: Timer?
    private var hotkeyProblems: [String] = []
    private var settings: SettingsWindowController?
    private var configSignature = ""
    private var registeredShortcuts = 0
    private var lastShortcut: (keys: String, reply: String, at: Date)?
    private var tour: TourWindowController?
    /// The menu of the menu bar item. Its first item is a view: the desktops, drawn.
    private let statusMenu = NSMenu()
    private let deskModel = DeskModel()
    private lazy var deskHost = NSHostingView(rootView: DeskView(model: deskModel))
    private let deskItem = NSMenuItem()
    /// Tiling waits for the welcome tour to end, so that the windows fall into place as it lifts.
    private var startHeld = false
    private static let tourSeenKey = "tourSeen"

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("Iguana \(WindowManager.version) starting")
        setUpStatusItem()
        hotkeys = Hotkeys()
        wm.onChange = { [weak self] in
            self?.updateStatusItem()
            if self?.settings?.isVisible == true { self?.settings?.model.refresh() }
        }
        wm.onConfigChange = { [weak self] in self?.registerHotkeys() }
        wm.statusExtras = { [weak self] in
            guard let self else { return [] }
            var lines = ["shortcuts: \(self.registeredShortcuts) active"] + self.hotkeyProblems.map { "  warning: \($0)" }
            if self.tour?.isShowing == true {
                lines.append(self.startHeld ? "welcome tour: on screen; tiling starts when it ends" : "welcome tour: on screen; shortcuts act on its practice desktop")
            }
            if let last = self.lastShortcut {
                lines.append("last shortcut: \(last.keys), \(Int(Date().timeIntervalSince(last.at))) s ago, answered \"\(last.reply)\"")
            } else {
                lines.append("last shortcut: none received since Iguana started")
            }
            return lines
        }
        wm.onOpenSettings = { [weak self] in self?.openSettings() }
        wm.onOpenTour = { [weak self] in self?.showTour() }
        NSApp.mainMenu = makeMainMenu()
        wm.reloadConfig()
        configSignature = Self.signature(of: WindowManager.configURL)
        // Pick up the config file as soon as it is saved, whatever saved it.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkConfigFile() }

        if !IPC.listen({ [weak self] line in self?.handle(line) ?? "error: shutting down" }) {
            Log.write("could not open the command socket at \(IPC.socketPath)")
        }

        // The first time Iguana runs it introduces itself, and asks for its permission there.
        let firstRun = !UserDefaults.standard.bool(forKey: Self.tourSeenKey)
        if firstRun { showTour() }

        if AXIsProcessTrusted() {
            startTiling()
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
                self?.startTiling()
                self?.updateStatusItem()
            }
        }
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm.saveState()
        IPC.stop()
    }

    private func startTiling() {
        if tour?.isShowing == true {
            startHeld = true
        } else {
            wm.start()
        }
    }

    private func showTour() {
        if tour == nil {
            let controller = TourWindowController(config: wm.config) { [weak self] in
                self?.statusItem?.button?.window?.frame
            }
            controller.onFinish = { [weak self] completed in
                guard let self else { return }
                Log.write(completed ? "welcome tour finished" : "welcome tour left early")
                UserDefaults.standard.set(true, forKey: Self.tourSeenKey)
                self.tour = nil
                if self.startHeld {
                    self.startHeld = false
                    self.wm.start()
                }
                self.updateStatusItem()
            }
            tour = controller
        }
        tour?.show()
    }

    /// While the tour is on screen, shortcuts and commands act on its practice desktop.
    private func tourReply(_ command: Command, _ binding: KeyBinding? = nil) -> String? {
        // Only while the tour has the keyboard. With another app in front, shortcuts and commands
        // are meant for the real windows.
        guard let tour, tour.isInFront else { return nil }
        return tour.model.handle(command, binding: binding)
    }

    private func handle(_ line: String) -> String {
        do {
            let command = try Command.parse(line)
            return tourReply(command) ?? wm.run(command)
        } catch {
            return "error: \(error)"
        }
    }

    private static func signature(of url: URL) -> String {
        // The file itself, not a link to it: a config kept in a dotfiles folder is a link.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) else { return "missing" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(modified) \(attributes[.size] ?? 0) \(attributes[.systemFileNumber] ?? 0)"
    }

    private func checkConfigFile() {
        let now = Self.signature(of: WindowManager.configURL)
        guard now != configSignature else { return }
        configSignature = now
        wm.reloadConfig()
        settings?.model.refresh()
        updateStatusItem()
    }

    private func openSettings() {
        if settings == nil { settings = SettingsWindowController(backend: self) }
        settings?.show()
    }

    /// An app without a Dock icon still needs a menu bar for Copy, Paste, Close and Quit to work
    /// in its windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector?, String)]) {
            let menu = NSMenu(title: title)
            for (name, action, key) in items {
                if name == "-" {
                    menu.addItem(.separator())
                } else {
                    menu.addItem(NSMenuItem(title: name, action: action, keyEquivalent: key))
                }
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Iguana", [("Settings…", #selector(showSettings), ","), ("-", nil, ""), ("Quit Iguana", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("-", nil, ""),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [("Close", #selector(NSWindow.performClose(_:)), "w"), ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        main.items.first?.submenu?.items.first?.target = self
        return main
    }

    @objc private func showSettings() { openSettings() }
    @objc private func showTourFromMenu() { showTour() }

    private func registerHotkeys() {
        guard let hotkeys else { return }
        hotkeyProblems = hotkeys.register(wm.config.bindings) { [weak self] binding in
            guard let self else { return }
            let reply = self.tourReply(binding.command, binding) ?? self.wm.run(binding.command)
            self.lastShortcut = (binding.source, reply, Date())
            if reply.hasPrefix("error") { Log.write("\(binding.source): \(reply)") }
        }
        registeredShortcuts = wm.config.bindings.count - hotkeyProblems.count
        for p in hotkeyProblems { Log.write(p) }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // On the way down, as every menu in the menu bar opens.
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusMenu.delegate = self
        statusItem = item

        // A click in the drawing closes the menu first, then does what was asked.
        deskModel.onFocus = { [weak self] id in
            self?.statusMenu.cancelTracking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.wm.focusWindow(id) }
        }
        deskModel.onGo = { [weak self] number in
            self?.statusMenu.cancelTracking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.goToDesk(number) }
        }
    }

    private func goToDesk(_ number: Int) {
        let reply = tourReply(.space(.index(number))) ?? wm.run(.space(.index(number)))
        if reply.hasPrefix("error") { Log.write("menu bar: \(reply)") }
    }

    /// A click opens the menu. With several desktops drawn in the menu bar, and only when the
    /// user has asked for it, a click on one of the others goes there instead.
    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
           wm.config.menuBarClickSwitches, !statusSlots.isEmpty, let cell = button.cell as? NSButtonCell, let window = button.window {
            // Where the pointer really is. The click the system hands over says the middle of
            // the item wherever it was clicked, which would always mean the middle desktop.
            let inButton = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let x = inButton.x - cell.imageRect(forBounds: button.bounds).minX
            if button.bounds.insetBy(dx: 0, dy: -20).contains(inButton),
               let slot = statusSlots.first(where: { $0.range.contains(x) }), slot.number != activeDeskNumber {
                goToDesk(slot.number)
                return
            }
        }
        // Handing the menu to the item for the length of one click lets the system open it,
        // place it and draw it as it does every other menu in the menu bar.
        statusItem?.menu = statusMenu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    private var iconCache: [pid_t: NSImage] = [:]
    /// The desktops drawn in the menu bar when it shows more than one, and the one in use.
    private var statusSlots: [StatusIcon.Slot] = []
    private var activeDeskNumber: Int?

    private func fillDesk() {
        let model = deskModel
        let (desks, owners) = wm.desks()
        var icons: [WindowID: NSImage] = [:]
        for (id, pid) in owners {
            if iconCache[pid] == nil { iconCache[pid] = NSRunningApplication(processIdentifier: pid)?.icon }
            icons[id] = iconCache[pid]
        }
        model.desks = desks.map { d in
            DeskModel.Desk(number: d.number, isActive: d.isActive, preview: DesktopPreviewData(
                layout: d.layout, visible: d.windows, icons: icons.filter { d.windows.contains($0.key) }, focused: d.focused,
                screen: d.screen, usable: d.usable, isExample: false))
        }
        model.config = wm.config
        model.paused = wm.paused
        model.needsPermission = !AXIsProcessTrusted()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let trusted = AXIsProcessTrusted()
        let all = trusted ? wm.desks().desks : []
        let active = all.first { $0.isActive }
        let aspect = active.map { $0.screen.width / max($0.screen.height, 1) } ?? 1.6
        activeDeskNumber = active?.number
        statusSlots = []
        // The number is drawn into the picture, so that it sits on one line with the drawing.
        let label = trusted ? wm.menuBarTitle : "needs permission"

        // The opt-in row of desktops: every one, or every one in use.
        let choice = wm.config.menuBarDesktops
        let row = choice == .current ? [] : all.filter { choice == .all || $0.isActive || !$0.windows.isEmpty }
        if trusted, !wm.paused, row.count > 1 {
            let drawn = StatusIcon.row(row.map {
                StatusIcon.Desk(number: $0.number, isActive: $0.isActive, layout: $0.layout, windows: $0.windows, focused: $0.focused)
            }, aspect: aspect, label: label)
            button.image = drawn.image
            statusSlots = drawn.slots
        } else {
            let state: StatusIcon.State
            if !trusted {
                state = .needsPermission
            } else if wm.paused {
                state = .paused
            } else if let active {
                state = .layout(active.layout, windows: active.windows, focused: active.focused)
            } else {
                state = .layout(Tree().snapshot, windows: [], focused: nil)
            }
            button.image = StatusIcon.image(state, aspect: aspect, label: label)
        }
        button.title = ""
        button.imagePosition = .imageOnly
        button.setAccessibilityTitle(trusted ? (label.isEmpty ? "Iguana" : "Iguana, desktop \(label)") : "Iguana needs permission")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The desktops, drawn, as the first item.
        fillDesk()
        deskHost.layoutSubtreeIfNeeded()
        deskHost.frame = NSRect(origin: .zero, size: deskHost.fittingSize)
        deskItem.view = deskHost
        menu.addItem(deskItem)
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector?, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        if !AXIsProcessTrusted() {
            add("Open Accessibility Settings…", #selector(openAccessibilitySettings))
        } else {
            add(wm.paused ? "Resume Tiling" : "Pause Tiling", #selector(togglePause))
            add("Balance Windows", #selector(balance))
        }
        menu.addItem(.separator())
        let problems = wm.configWarnings + hotkeyProblems
        if !problems.isEmpty {
            add("\(problems.count) config problem\(problems.count == 1 ? "" : "s") (see log)", #selector(openLog))
        }
        add("Settings…", #selector(showSettings), key: ",")
        add("Edit Config File", #selector(editConfig))
        add("Welcome Tour…", #selector(showTourFromMenu))
        add("Show Log", #selector(openLog))
        menu.addItem(.separator())
        add("Quit Iguana", #selector(quit), key: "q")
    }

    @objc private func togglePause() {
        _ = wm.run(.pause)
        updateStatusItem()
    }

    @objc private func balance() { _ = wm.run(.balance) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func editConfig() {
        if let message = ConfigFile.createIfMissing() { Log.write(message) }
        NSWorkspace.shared.open(WindowManager.configURL)
    }
}

extension Daemon: SettingsBackend {
    var config: Config { wm.config }
    var problems: [String] { wm.configWarnings + hotkeyProblems }
    var configURL: URL { WindowManager.configURL }
    var isPaused: Bool { wm.paused }

    func reloadConfig() {
        wm.reloadConfig()
        configSignature = Self.signature(of: WindowManager.configURL)
        updateStatusItem()
    }

    func setPaused(_ paused: Bool) {
        wm.setPaused(paused)
        updateStatusItem()
    }

    func suspendShortcuts(_ suspended: Bool) {
        if suspended { hotkeys?.unregisterAll() } else { registerHotkeys() }
    }

    var tiledWindowCount: Int { wm.tiledWindowCount }
    var needsPermission: Bool { !AXIsProcessTrusted() }

    func desktopPreview() -> DesktopPreviewData? {
        guard let p = wm.desktopPreview() else { return nil }
        var icons: [WindowID: NSImage] = [:]
        for (id, pid) in p.owners { icons[id] = NSRunningApplication(processIdentifier: pid)?.icon }
        return DesktopPreviewData(layout: p.layout, visible: p.visible, icons: icons, focused: p.focused,
                                  screen: p.screen, usable: p.usable, isExample: false)
    }
}

enum ConfigFile {
    /// Save a config file, creating its folder, and put the editor schema beside it.
    static func write(_ text: String, to url: URL) throws {
        // Write through a link to the file it points at, instead of replacing the link.
        let url = url.resolvingSymlinksInPath()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        let schema = folder.appendingPathComponent("iguana.schema.json")
        if (try? String(contentsOf: schema, encoding: .utf8)) != Config.jsonSchema + "\n" {
            try? Data((Config.jsonSchema + "\n").utf8).write(to: schema, options: .atomic)
        }
    }

    /// Check a file the way the app would load it. Returns the lines to print and whether it loads.
    static func check(_ url: URL) -> (report: [String], ok: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (["\(url.path): no file there, so the built-in settings apply"], true)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (["\(url.path): cannot be read"], false)
        }
        do {
            let (config, warnings) = try Config.load(text)
            if warnings.isEmpty {
                return (["\(url.path): no problems (\(config.bindings.count) shortcuts, \(config.rules.count) rules)"], true)
            }
            return (["\(url.path): loads, with \(warnings.count) problem\(warnings.count == 1 ? "" : "s"):"] + warnings.map { "  - \($0)" }, true)
        } catch {
            return (["\(url.path): cannot be loaded: \(error)", "Iguana keeps its previous settings until this is fixed."], false)
        }
    }

    /// Write the default config unless a file is already there. Returns a note about what happened.
    static func createIfMissing() -> String? {
        let url = WindowManager.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try write(Config.defaultText + "\n", to: url)
            return "wrote the default config to \(url.path) (and iguana.schema.json beside it, for editor completion)"
        } catch {
            return "error: could not write \(url.path): \(error.localizedDescription)"
        }
    }
}
