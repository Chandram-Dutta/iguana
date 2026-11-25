import AppKit
import IguanaCore
import ServiceManagement
import SwiftUI

typealias KeyBinding = IguanaCore.Binding

/// What the settings window needs from the rest of the app.
protocol SettingsBackend: AnyObject {
    var config: Config { get }
    var problems: [String] { get }
    var configURL: URL { get }
    var isPaused: Bool { get }
    func reloadConfig()
    func setPaused(_ paused: Bool)
    /// Global shortcuts are released while a new one is being recorded, so the keys reach the window.
    func suspendShortcuts(_ suspended: Bool)
    /// The layout of the desktop being shown, for the live preview. Nil when there is too little to show.
    func desktopPreview() -> DesktopPreviewData?
    var tiledWindowCount: Int { get }
    var needsPermission: Bool { get }
    /// A newer release than the one running, when one is known and may be shown.
    var availableUpdate: UpdateCheck.Update? { get }
    /// Ask now whether there is a newer release. `completion` runs on the main thread.
    func checkForUpdate(_ completion: @escaping (UpdateCheck.Outcome) -> Void)
}

extension SettingsBackend {
    func desktopPreview() -> DesktopPreviewData? { nil }
    var tiledWindowCount: Int { 0 }
    var needsPermission: Bool { false }
    var availableUpdate: UpdateCheck.Update? { nil }
    func checkForUpdate(_ completion: @escaping (UpdateCheck.Outcome) -> Void) { completion(.failed("there is nothing to ask here")) }
}

/// What the miniature desktop in the settings window draws.
struct DesktopPreviewData {
    var layout: NodeSnapshot
    var visible: Set<WindowID>
    var icons: [WindowID: NSImage]
    var focused: WindowID?
    /// The real screen, in points.
    var screen: CGSize
    /// The part of the screen below the menu bar and above the Dock.
    var usable: CGRect
    var isExample: Bool

    /// Three windows on a laptop screen, for when the desktop has fewer than two tiled windows.
    static let example: DesktopPreviewData = {
        let tree = Tree()
        tree.insert(1)
        tree.insert(2, after: 1, split: .horizontal)
        tree.insert(3, after: 2, split: .vertical)
        return DesktopPreviewData(layout: tree.snapshot, visible: [1, 2, 3], icons: [:], focused: 2,
                                  screen: CGSize(width: 1512, height: 982), usable: CGRect(x: 0, y: 38, width: 1512, height: 944),
                                  isExample: true)
    }()
}

enum Pane: String, CaseIterable, Identifiable {
    case general, layout, animation, shortcuts, rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .layout: return "Layout"
        case .animation: return "Animation"
        case .shortcuts: return "Shortcuts"
        case .rules: return "Window Rules"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "rectangle.split.2x1"
        case .animation: return "wand.and.rays"
        case .shortcuts: return "keyboard"
        case .rules: return "macwindow.on.rectangle"
        }
    }
}

struct CommandInfo: Identifiable {
    let title: String
    let text: String
    var id: String { text }
    var command: Command? { try? Command.parse(text) }
}

struct CommandGroup: Identifiable {
    let title: String
    let commands: [CommandInfo]
    var id: String { title }

    static let all: [CommandGroup] = {
        let directions = [("left", "Left"), ("down", "Down"), ("up", "Up"), ("right", "Right")]
        return [
            CommandGroup(title: "Focus", commands: directions.map { CommandInfo(title: "Focus \($0.1)", text: "focus \($0.0)") }),
            CommandGroup(title: "Move Window", commands: directions.map { CommandInfo(title: "Move \($0.1)", text: "move \($0.0)") }),
            CommandGroup(title: "Group With Neighbour", commands: [
                CommandInfo(title: "Group With the Window on the Left", text: "join left"),
                CommandInfo(title: "Group With the Window Below", text: "join down"),
                CommandInfo(title: "Group With the Window Above", text: "join up"),
                CommandInfo(title: "Group With the Window on the Right", text: "join right"),
            ]),
            CommandGroup(title: "Size and Arrangement", commands: [
                CommandInfo(title: "Grow", text: "resize grow"),
                CommandInfo(title: "Shrink", text: "resize shrink"),
                CommandInfo(title: "Balance Sizes", text: "balance"),
                CommandInfo(title: "Fill the Desktop", text: "zoom"),
                CommandInfo(title: "Switch Side-by-Side / Top-to-Bottom", text: "flip"),
                CommandInfo(title: "Stack or Unstack Windows", text: "stack"),
                CommandInfo(title: "Float or Tile Window", text: "float"),
                CommandInfo(title: "Close Window", text: "close"),
                CommandInfo(title: "Pause Tiling", text: "pause"),
                CommandInfo(title: "Undo Layout Change", text: "undo"),
                CommandInfo(title: "Redo Layout Change", text: "redo"),
            ]),
            CommandGroup(title: "Go to Desktop", commands: (1...9).map { CommandInfo(title: "Desktop \($0)", text: "space \($0)") } + [
                CommandInfo(title: "Next Desktop", text: "space next"),
                CommandInfo(title: "Previous Desktop", text: "space prev"),
            ]),
            CommandGroup(title: "Take Window to Desktop", commands: (1...9).map { CommandInfo(title: "Desktop \($0)", text: "move-to-space \($0)") } + [
                CommandInfo(title: "Next Desktop", text: "move-to-space next"),
                CommandInfo(title: "Previous Desktop", text: "move-to-space prev"),
            ]),
        ]
    }()
}

/// The settings window edits the config file itself. Every change rewrites just the value that
/// changed and reloads, so the window, the file and the running window manager cannot disagree.
final class SettingsModel: ObservableObject {
    @Published var pane: Pane? = .general
    @Published private(set) var config: Config
    @Published private(set) var problems: [String]
    @Published private(set) var fileExists: Bool
    @Published private(set) var paused: Bool
    @Published private(set) var launchAtLogin = false
    @Published var loginItemError: String?
    @Published private(set) var preview = DesktopPreviewData.example
    @Published private(set) var tiledWindowCount = 0
    @Published private(set) var needsPermission = false
    /// A newer release found by the daily check.
    @Published private(set) var availableUpdate: UpdateCheck.Update?
    /// What Check Now found, the last time it was pressed in this window.
    @Published private(set) var updateOutcome: UpdateCheck.Outcome?
    @Published private(set) var checkingForUpdate = false
    /// The shortcut slot that is listening for keys right now.
    @Published var recording: String?
    @Published var notice: String?

    private let backend: SettingsBackend
    private var recorder: Any?

    init(backend: SettingsBackend) {
        self.backend = backend
        config = backend.config
        problems = backend.problems
        paused = backend.isPaused
        fileExists = FileManager.default.fileExists(atPath: backend.configURL.path)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        preview = backend.desktopPreview() ?? .example
        tiledWindowCount = backend.tiledWindowCount
        needsPermission = backend.needsPermission
        availableUpdate = backend.availableUpdate
    }

    var configURL: URL { backend.configURL }

    /// Pull the current state after the file changed (from here or from a text editor).
    func refresh() {
        config = backend.config
        problems = backend.problems
        paused = backend.isPaused
        fileExists = FileManager.default.fileExists(atPath: backend.configURL.path)
        preview = backend.desktopPreview() ?? .example
        tiledWindowCount = backend.tiledWindowCount
        needsPermission = backend.needsPermission
        availableUpdate = backend.availableUpdate
    }

    // MARK: Updates

    /// Ask now whether a newer Iguana has been released, whatever the setting says.
    func checkForUpdate() {
        guard !checkingForUpdate else { return }
        checkingForUpdate = true
        backend.checkForUpdate { [weak self] outcome in
            guard let self else { return }
            self.checkingForUpdate = false
            self.updateOutcome = outcome
            self.availableUpdate = self.backend.availableUpdate
        }
    }

    /// The newer release to offer: what Check Now just found, or else what the daily check found.
    var updateOffered: UpdateCheck.Update? {
        switch updateOutcome {
        case .newer(let update): return update
        case .latest: return nil
        case .failed, nil: return availableUpdate
        }
    }

    /// What the settings window says beside Check Now.
    func updateSummary(running: String) -> String {
        if checkingForUpdate { return "Asking GitHub…" }
        if let updateOutcome { return updateOutcome.summary(running: running) }
        if let availableUpdate { return UpdateCheck.Outcome.newer(availableUpdate).summary(running: running) }
        return "You have Iguana \(running)."
    }

    // MARK: Editing the file

    private func currentText() -> String {
        // The first change creates the file from the documented default, so it is pleasant to read.
        (try? String(contentsOf: configURL, encoding: .utf8)) ?? Config.defaultText + "\n"
    }

    func edit(_ body: (inout TOMLEditor) -> Void) {
        // A file that is there but cannot be read must not be replaced by the default one.
        if FileManager.default.fileExists(atPath: configURL.path), (try? String(contentsOf: configURL, encoding: .utf8)) == nil {
            notice = "The config file cannot be read as text, so nothing was changed."
            return
        }
        var editor = TOMLEditor(currentText())
        body(&editor)
        do {
            try ConfigFile.write(editor.text, to: configURL)
        } catch {
            notice = "Could not save the config file: \(error.localizedDescription)"
            return
        }
        notice = nil
        backend.reloadConfig()
        refresh()
    }

    func set(_ path: [String], _ value: TOMLValue) {
        edit { $0.set(path, to: value) }
    }

    func setNumber(_ path: [String], _ value: Double) {
        set(path, value == value.rounded() ? .int(Int(value)) : .double(value))
    }

    func setOuterGap(_ edges: Edges) {
        if edges.top == edges.left, edges.left == edges.bottom, edges.bottom == edges.right {
            setNumber(["gaps", "outer"], edges.top)
        } else {
            func n(_ v: Double) -> TOMLValue { v == v.rounded() ? .int(Int(v)) : .double(v) }
            set(["gaps", "outer"], .table(["top": n(edges.top), "left": n(edges.left), "bottom": n(edges.bottom), "right": n(edges.right)]))
        }
    }

    func setPaused(_ value: Bool) {
        backend.setPaused(value)
        paused = backend.isPaused
        tiledWindowCount = backend.tiledWindowCount
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "macOS did not accept the change: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Shortcuts

    func bindings(for command: Command) -> [KeyBinding] {
        config.bindings.filter { $0.command == command }
    }

    /// Shortcuts for commands that are not in the standard list (for example `move-to-space 3 --stay`).
    var customBindings: [KeyBinding] {
        let known = Set(CommandGroup.all.flatMap(\.commands).compactMap(\.command).map { "\($0)" })
        return config.bindings.filter { !known.contains("\($0.command)") }
    }

    /// How the file spells the shortcut for `combo`, if the file mentions it.
    private func fileKey(for combo: KeyCombo, in text: String) -> String? {
        guard let table = (try? TOML.parse(text))?["bindings"]?.tableValue else { return nil }
        return table.keys.first { (try? KeyCombo.parse($0)) == combo }
    }

    private func isBuiltIn(_ combo: KeyCombo) -> Bool {
        Config.default.bindings.contains { $0.combo == combo }
    }

    private func clear(_ combo: KeyCombo, in editor: inout TOMLEditor, text: String, fallbackKey: String) {
        let key = fileKey(for: combo, in: text) ?? fallbackKey
        if isBuiltIn(combo) {
            // A built-in shortcut is switched off by an empty entry.
            editor.set(["bindings", key], to: .string(""))
        } else {
            editor.remove(["bindings", key])
        }
    }

    /// Give `command` the shortcut `keys`, replacing `old` if this was a change rather than an addition.
    func bind(_ keys: String, to commandText: String, replacing old: KeyBinding?) {
        guard let combo = try? KeyCombo.parse(keys), (try? Command.parse(commandText)) != nil else { return }
        let text = currentText()
        let taken = config.bindings.first { $0.combo == combo && $0.commandText != commandText }
        edit { editor in
            if let old, old.combo != combo { clear(old.combo, in: &editor, text: text, fallbackKey: old.source) }
            editor.set(["bindings", fileKey(for: combo, in: text) ?? keys], to: .string(commandText))
        }
        if let taken { notice = "\(ShortcutFormat.display(combo)) used to run “\(taken.commandText)”. It now runs “\(commandText)”." }
    }

    func unbind(_ binding: KeyBinding) {
        let text = currentText()
        edit { clear(binding.combo, in: &$0, text: text, fallbackKey: binding.source) }
    }

    /// Drop every shortcut entry from the file, which brings the built-in set back.
    func resetShortcuts() {
        let text = currentText()
        guard let table = (try? TOML.parse(text))?["bindings"]?.tableValue else { return }
        edit { editor in for key in table.keys { editor.remove(["bindings", key]) } }
    }

    var shortcutsDifferFromBuiltIn: Bool {
        Set(config.bindings.map { "\($0.combo.modifiers.map(\.rawValue).sorted()) \($0.combo.key) \($0.command)" })
            != Set(Config.default.bindings.map { "\($0.combo.modifiers.map(\.rawValue).sorted()) \($0.combo.key) \($0.command)" })
    }

    // MARK: Recording a shortcut

    /// Listen for the next shortcut typed in the settings window. Esc cancels; Delete calls `onClear`.
    func startRecording(slot: String, onClear: (() -> Void)? = nil, completion: @escaping (String) -> Void) {
        stopRecording()
        recording = slot
        backend.suspendShortcuts(true)
        recorder = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, flags.isEmpty {
                self.stopRecording()
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty, let onClear {
                self.stopRecording()
                onClear()
                return nil
            }
            guard !flags.isEmpty, let key = Hotkeys.keyName(for: Int(event.keyCode)) else {
                NSSound.beep()
                return nil
            }
            var parts: [String] = []
            if flags.contains(.control) { parts.append("ctrl") }
            if flags.contains(.option) { parts.append("option") }
            if flags.contains(.shift) { parts.append("shift") }
            if flags.contains(.command) { parts.append("cmd") }
            parts.append(key)
            self.stopRecording()
            completion(parts.joined(separator: "-"))
            return nil
        }
    }

    func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        if recording != nil {
            recording = nil
            backend.suspendShortcuts(false)
        }
    }

    // MARK: Rules

    func setRules(_ rules: [Rule]) {
        edit { editor in
            // `rule = []` says "no rules at all"; without it an empty list would bring the built-in rules back.
            editor.remove(["rule"])
            editor.replaceArrayOfTables("rule", with: rules.map { rule in
                var entry: [(String, TOMLValue)] = []
                if let app = rule.app, !app.isEmpty { entry.append(("app", .string(app))) }
                if let title = rule.title, !title.isEmpty { entry.append(("title", .string(title))) }
                // A rule that only names a desktop says nothing about floating, and is written that way.
                if let float = rule.float { entry.append(("float", .bool(float))) }
                if let desktop = rule.desktop { entry.append(("desktop", .int(desktop))) }
                return entry
            })
            if rules.isEmpty { editor.set(["rule"], to: .array([])) }
        }
    }
}

enum ShortcutFormat {
    private static let keySymbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "enter": "↩", "space": "Space", "tab": "⇥",
        "esc": "⎋", "escape": "⎋", "delete": "⌫", "minus": "−", "equal": "=", "comma": ",", "period": ".", "slash": "/",
        "semicolon": ";", "quote": "'", "backslash": "\\", "backtick": "`", "leftbracket": "[", "rightbracket": "]",
    ]

    /// The keys of `option-shift-h` one by one, as printed on a keyboard: ⌥ ⇧ H.
    static func keys(_ combo: KeyCombo) -> [String] {
        var keys: [String] = []
        if combo.modifiers.contains(.ctrl) { keys.append("⌃") }
        if combo.modifiers.contains(.option) { keys.append("⌥") }
        if combo.modifiers.contains(.shift) { keys.append("⇧") }
        if combo.modifiers.contains(.cmd) { keys.append("⌘") }
        keys.append(keySymbols[combo.key] ?? combo.key.uppercased())
        return keys
    }

    /// `option-shift-h` as it appears on a keyboard: ⌥⇧H.
    static func display(_ combo: KeyCombo) -> String { keys(combo).joined() }

    /// The same, spelled out for VoiceOver.
    static func spoken(_ combo: KeyCombo) -> String {
        var words: [String] = []
        if combo.modifiers.contains(.ctrl) { words.append("Control") }
        if combo.modifiers.contains(.option) { words.append("Option") }
        if combo.modifiers.contains(.shift) { words.append("Shift") }
        if combo.modifiers.contains(.cmd) { words.append("Command") }
        words.append(combo.key.count == 1 ? combo.key.uppercased() : combo.key)
        return words.joined(separator: " ")
    }
}
