import AppKit
import IguanaCore

/// What the settings window asks of the running app: the config in force, the pause, the
/// shortcuts while a new one is recorded, and the desktop for its live preview.
final class AppSettingsBackend: SettingsBackend {
    private let wm: WindowManager
    private let shortcuts: HotkeyRegistrar
    private let configWatcher: ConfigWatcher
    private let updates: UpdateChecker
    /// The newer release to tell the user about, if there is one and it may be told.
    private let knownUpdate: () -> UpdateCheck.Update?
    /// Whether Iguana has its Accessibility permission.
    private let trusted: () -> Bool
    /// Something the menu bar item shows may have changed.
    private let onChange: () -> Void

    init(wm: WindowManager, shortcuts: HotkeyRegistrar, configWatcher: ConfigWatcher, updates: UpdateChecker,
         knownUpdate: @escaping () -> UpdateCheck.Update?, trusted: @escaping () -> Bool, onChange: @escaping () -> Void) {
        self.wm = wm
        self.shortcuts = shortcuts
        self.configWatcher = configWatcher
        self.updates = updates
        self.knownUpdate = knownUpdate
        self.trusted = trusted
        self.onChange = onChange
    }

    var config: Config { wm.config }
    var problems: [String] { wm.configWarnings + shortcuts.problems }
    var configURL: URL { Iguana.configURL }
    var isPaused: Bool { wm.paused }

    func reloadConfig() {
        wm.reloadConfig()
        // The settings window saved the file itself: the watcher need not read it again.
        configWatcher.mark()
        onChange()
    }

    func setPaused(_ paused: Bool) {
        wm.setPaused(paused)
        onChange()
    }

    /// Shortcuts come back as those of [bindings]: a mode does not outlast the pause.
    func suspendShortcuts(_ suspended: Bool) {
        if suspended { shortcuts.unregisterAll() } else {
            wm.switchMode(Config.defaultMode)
            shortcuts.register()
        }
    }

    var tiledWindowCount: Int { wm.tiledWindowCount }
    var needsPermission: Bool { !trusted() }
    var availableUpdate: UpdateCheck.Update? { knownUpdate() }
    func checkForUpdate(_ completion: @escaping (UpdateCheck.Outcome) -> Void) { updates.checkNow(completion) }

    func desktopPreview() -> DesktopPreviewData? {
        guard let p = wm.desktopPreview() else { return nil }
        var icons: [WindowID: NSImage] = [:]
        for (id, pid) in p.owners { icons[id] = NSRunningApplication(processIdentifier: pid)?.icon }
        return DesktopPreviewData(layout: p.layout, visible: p.visible, icons: icons, focused: p.focused,
                                  screen: p.screen, usable: p.usable, isExample: false, display: (p.display.name, p.display.number))
    }
}
