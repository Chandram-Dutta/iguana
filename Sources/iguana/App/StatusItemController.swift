import AppKit
import IguanaCore
import SwiftUI

/// The menu bar item: its picture, what a click on it does, and its menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let wm: WindowManager
    private let icons: AppIcons
    /// Whether Iguana has its Accessibility permission.
    private let trusted: () -> Bool
    /// The shortcuts that could not be registered, which the menu counts with the config's problems.
    private let shortcutProblems: () -> [String]
    /// The newer release to tell the user about, if there is one and it may be told.
    private let knownUpdate: () -> UpdateCheck.Update?
    /// Runs a command as a shortcut would: on the tour's practice desktop while the tour has
    /// the keyboard, on the real windows otherwise.
    private let run: (Command) -> String
    var onSettings: (() -> Void)?
    var onTour: (() -> Void)?

    private var statusItem: NSStatusItem?
    /// The menu of the menu bar item. Its first item is a view: the desktops, drawn.
    private let statusMenu = NSMenu()
    private let deskModel = DeskModel()
    private lazy var deskHost = NSHostingView(rootView: DeskView(model: deskModel))
    private let deskItem = NSMenuItem()
    /// The desktops drawn in the menu bar when it shows more than one, and the one in use.
    private var statusSlots: [StatusIcon.Slot] = []
    private var activeDeskNumber: Int?

    init(wm: WindowManager, icons: AppIcons, trusted: @escaping () -> Bool, shortcutProblems: @escaping () -> [String],
         knownUpdate: @escaping () -> UpdateCheck.Update?, run: @escaping (Command) -> String) {
        self.wm = wm
        self.icons = icons
        self.trusted = trusted
        self.shortcutProblems = shortcutProblems
        self.knownUpdate = knownUpdate
        self.run = run
    }

    /// Where the item is on screen, once it is in the menu bar.
    var frameOnScreen: CGRect? { statusItem?.button?.window?.frame }

    /// Put the item in the menu bar.
    func install() {
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
        let reply = run(.space(.index(number)))
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

    // MARK: The picture

    /// What the item shows: its picture, where each desktop is in it, and what it is called.
    struct Face {
        let image: NSImage
        /// Empty unless the picture is a row of desktops.
        let slots: [StatusIcon.Slot]
        let activeDesk: Int?
        let accessibilityTitle: String
    }

    func face() -> Face {
        let trusted = trusted()
        let all = trusted ? wm.desks().desks : []
        let active = all.first { $0.isActive }
        let aspect = active.map { $0.screen.width / max($0.screen.height, 1) } ?? 1.6
        // The number is drawn into the picture, so that it sits on one line with the drawing.
        let label = trusted ? StatusIcon.label(desktop: wm.menuBarTitle, mode: wm.mode) : "needs permission"
        let image: NSImage
        var slots: [StatusIcon.Slot] = []

        // The opt-in row of desktops: every one, or every one in use.
        let choice = wm.config.menuBarDesktops
        let row = choice == .current ? [] : all.filter { choice == .all || $0.isActive || !$0.windows.isEmpty }
        if trusted, !wm.paused, row.count > 1 {
            let drawn = StatusIcon.row(row.map {
                StatusIcon.Desk(number: $0.number, isActive: $0.isActive, layout: $0.layout, windows: $0.windows, focused: $0.focused)
            }, aspect: aspect, label: label)
            image = drawn.image
            slots = drawn.slots
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
            image = StatusIcon.image(state, aspect: aspect, label: label)
        }
        let mode = wm.mode == Config.defaultMode ? "" : ", \(wm.mode) mode"
        let desktop = wm.menuBarTitle.isEmpty ? "" : ", desktop \(wm.menuBarTitle)"
        return Face(image: image, slots: slots, activeDesk: active?.number,
                    accessibilityTitle: trusted ? "Iguana\(desktop)\(mode)" : "Iguana needs permission")
    }

    /// Draw the item again. Something it shows has changed.
    func update() {
        guard let button = statusItem?.button else { return }
        let face = face()
        activeDeskNumber = face.activeDesk
        statusSlots = face.slots
        button.image = face.image
        button.title = ""
        button.imagePosition = .imageOnly
        button.setAccessibilityTitle(face.accessibilityTitle)
    }

    // MARK: The menu

    private func fillDesk() {
        let model = deskModel
        let (desks, owners) = wm.desks()
        let icons = icons.icons(for: owners)
        model.desks = desks.map { d in
            DeskModel.Desk(number: d.number, isActive: d.isActive, preview: DesktopPreviewData(
                layout: d.layout, visible: d.windows, icons: icons.filter { d.windows.contains($0.key) }, focused: d.focused,
                screen: d.screen, usable: d.usable, isExample: false, display: (d.display.name, d.display.number)))
        }
        model.config = wm.config
        model.paused = wm.paused
        model.needsPermission = !trusted()
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
        if !trusted() {
            add("Open Accessibility Settings…", #selector(openAccessibilitySettings))
        } else {
            add(wm.paused ? "Resume Tiling" : "Pause Tiling", #selector(togglePause))
            add("Balance Windows", #selector(balance))
        }
        menu.addItem(.separator())
        let problems = wm.configWarnings + shortcutProblems()
        if !problems.isEmpty {
            add("\(problems.count) config problem\(problems.count == 1 ? "" : "s") (see log)", #selector(openLog))
        }
        if let update = knownUpdate() { add(UpdateCheck.menuTitle(update), #selector(openUpdatePage)) }
        add("Settings…", #selector(showSettings), key: ",")
        add("Edit Config File", #selector(editConfig))
        add("Welcome Tour…", #selector(showTourFromMenu))
        add("Show Log", #selector(openLog))
        menu.addItem(.separator())
        add("Quit Iguana", #selector(quit), key: "q")
    }

    @objc private func showSettings() { onSettings?() }
    @objc private func showTourFromMenu() { onTour?() }

    @objc private func togglePause() {
        _ = wm.run(.pause)
        update()
    }

    @objc private func balance() { _ = wm.run(.balance) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    /// Opens the page of the newer release in the browser. The address was checked when the
    /// release was found (`UpdateCheck.page`); the list of releases stands in if it is gone.
    @objc private func openUpdatePage() { NSWorkspace.shared.open(knownUpdate()?.page ?? UpdateCheck.releasesPage) }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func editConfig() {
        if let message = ConfigFile.createIfMissing() { Log.write(message) }
        NSWorkspace.shared.open(Iguana.configURL)
    }
}
