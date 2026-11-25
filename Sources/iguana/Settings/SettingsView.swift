import AppKit
import IguanaCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // The system's own split view: it brings the floating glass sidebar, the room for the
        // window buttons inside it, and the bar across the top.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Sidebar(model: model)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(224)
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch model.pane ?? .general {
                    case .general: GeneralPane(model: model)
                    case .layout: LayoutPane(model: model)
                    case .animation: MotionPane(model: model)
                    case .shortcuts: ShortcutsPane(model: model)
                    case .rules: FloatingPane(model: model)
                    case .hooks: HooksPane(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glass(Capsule())
                        .padding(.bottom, 18)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            if model.notice == notice { model.notice = nil }
                        }
                }
            }
            .animation(.snappy(duration: 0.25), value: model.notice)
            // The split view takes a column's ideal size as the least it may have, and a pane's
            // ideal height is the whole of its scrolling content. Say what is really needed.
            .frame(minWidth: 560, idealWidth: 660, minHeight: 320, idealHeight: 560)
        }
        .tint(Theme.accent)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    private var status: String {
        if model.needsPermission { return "Needs permission" }
        if model.paused { return "Paused" }
        return model.tiledWindowCount == 1 ? "Tiling 1 window" : "Tiling \(model.tiledWindowCount) windows"
    }

    var body: some View {
        List(selection: $model.pane) {
            ForEach(Pane.allCases) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
        }
        .listStyle(.sidebar)
        .frame(minHeight: 320, idealHeight: 560)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                if let logo = Bundle.main.image(forResource: "logo") {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .accessibilityHidden(true)
                } else {
                    // Running outside the app bundle (tests, `swift run`): draw the simple mark.
                    IguanaMark().frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Iguana").font(Theme.rounded(16, .bold))
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.setPaused(!model.paused)
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(model.paused ? Theme.attention : Theme.accent).frame(width: 7, height: 7)
                    Text(model.paused ? "Tiling is paused" : "Tiling is on").font(.system(size: 12))
                    Spacer()
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Capsule().fill(Theme.well))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(model.paused ? "Start tiling again" : "Leave every window where it is until you resume")
            .accessibilityLabel(model.paused ? "Resume tiling" : "Pause tiling")
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

private func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    private var path: String { model.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        PaneScaffold(title: "General", subtitle: "Startup, and where your settings are kept.") {
            if model.needsPermission {
                SettingSection {
                Callout(kind: .attention, text: "Iguana cannot move windows until it has Accessibility permission.") {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .glassButton()
                }
                }
            }

            SettingSection {
                SettingRow(title: "Open at login", detail: "Start tiling as soon as you log in to this Mac.") {
                    Toggle("Open at login", isOn: SwiftUI.Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if let error = model.loginItemError {
                    Callout(.attention, error)
                }
            }

            SettingSection(title: "Menu bar", footer: model.config.menuBarDesktops == .current
                ? "The icon in the menu bar is a drawing of the desktop you are on."
                : "Each desktop is drawn with its own layout.") {
                SettingRow(title: "Desktops drawn in the menu bar") {
                    Segmented(name: "Desktops drawn in the menu bar", options: [MenuBarDesktops.current, .occupied, .all],
                              selection: model.config.menuBarDesktops,
                              onSelect: { model.set(["menu-bar", "desktops"], .string($0.rawValue)) }) {
                        switch $0 {
                        case .current: return "This one"
                        case .occupied: return "Those in use"
                        case .all: return "All"
                        }
                    }
                }
                if model.config.menuBarDesktops != .current {
                    SettingRow(title: "Click a desktop to go to it",
                               detail: model.config.menuBarClickSwitches
                                   ? "A click on the desktop you are on opens the menu."
                                   : "A click anywhere on the item opens the menu.") {
                        Toggle("Click a desktop to go to it", isOn: SwiftUI.Binding(
                            get: { model.config.menuBarClickSwitches }, set: { model.set(["menu-bar", "click-to-switch"], .bool($0)) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            SettingSection(title: "Updates") {
                SettingRow(title: "Check for updates",
                           detail: "Once a day, ask GitHub whether a newer Iguana is out. Nothing about you is sent, and nothing is downloaded.") {
                    Toggle("Check for updates", isOn: SwiftUI.Binding(
                        get: { model.config.checkForUpdates }, set: { model.set(["updates", "check"], .bool($0)) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingRow(title: model.updateSummary(running: WindowManager.version)) {
                    HStack(spacing: 8) {
                        if model.checkingForUpdate { ProgressView().controlSize(.small) }
                        if let update = model.updateOffered {
                            Button("Show Iguana \(update.version)…") { NSWorkspace.shared.open(update.page) }
                                .glassButton()
                                .help("Open the page of this release in your browser")
                        }
                        Button("Check Now") { model.checkForUpdate() }
                            .glassButton()
                            .disabled(model.checkingForUpdate)
                    }
                    .controlSize(.small)
                }
            }

            SettingSection(title: "Settings file") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Theme.accent)
                            .font(.system(size: 14))
                        Text(path)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Show in Finder") {
                            ensureFile()
                            NSWorkspace.shared.activateFileViewerSelecting([model.configURL])
                        }
                        .glassButton()
                        Button("Open") {
                            ensureFile()
                            NSWorkspace.shared.open(model.configURL)
                        }
                        .glassButton()
                    }
                    .controlSize(.small)
                    Text(model.fileExists
                        ? "This window and that file are the same settings. A change here rewrites only the value you changed and keeps your comments; a change you save in the file appears here."
                        : "There is no file yet, so the built-in settings apply. Your first change here creates it, with every setting explained in comments.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            if model.problems.isEmpty {
                if model.fileExists {
                    SettingSection { Callout(.good, "No problems in the settings file.") }
                }
            } else {
                SettingSection(title: model.problems.count == 1 ? "1 problem in the settings file" : "\(model.problems.count) problems in the settings file") {
                    ForEach(model.problems, id: \.self) { Callout(.attention, $0) }
                }
            }
        }
    }

    private func ensureFile() {
        if !model.fileExists { model.edit { _ in } }
    }
}

// MARK: - Layout

private struct LayoutPane: View {
    @ObservedObject var model: SettingsModel
    @State private var perSide = false
    /// Looked at when the pane appears and when the user comes back to Iguana, which is how
    /// they return from switching it off in System Settings.
    @State private var systemTiles = SystemTiling.tilesDraggedWindows

    private var outer: Edges { model.config.gapOuter }
    private var outerIsUniform: Bool { outer.top == outer.left && outer.left == outer.bottom && outer.bottom == outer.right }
    private var showsEachEdge: Bool { perSide || !outerIsUniform }

    var body: some View {
        PaneScaffold(title: "Layout", subtitle: "How windows share the desktop.") {
            HStack(alignment: .center, spacing: 24) {
                DesktopPreview(config: model.config, data: model.preview)
                    .frame(width: DesktopPreview.width(forHeight: 172, data: model.preview), height: 172)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.preview.isExample ? "An example desktop" : "Your desktop, right now")
                        .font(Theme.rounded(13, .semibold))
                    Text(model.preview.isExample
                        ? "Open two or more windows and they appear here in place of the example."
                        : "These are your windows. They follow each setting as you change it, and so do the real ones.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        } content: {
            if systemTiles {
                SettingSection {
                    Callout(kind: .note, text: "macOS also tiles a window that is dragged to a screen edge, and shows an outline of its own. Iguana's layout wins when you let go. To see only Iguana's outline, turn off the options for tiling by dragging under Windows in Desktop & Dock.") {
                        Button("Open Desktop & Dock") { SystemTiling.openSettings() }
                            .controlSize(.small)
                    }
                }
            }
            SettingSection(title: "Gaps") {
                SettingRow(title: "Between windows") {
                    ValueSlider(label: "Gap between windows", value: model.config.gapInner, range: 0...40, step: 1, format: points) {
                        model.setNumber(["gaps", "inner"], $0)
                    }
                }
                if showsEachEdge {
                    edge("Top edge", \.top)
                    edge("Left edge", \.left)
                    edge("Bottom edge", \.bottom)
                    edge("Right edge", \.right)
                } else {
                    SettingRow(title: "Around the screen edge") {
                        ValueSlider(label: "Gap around the screen edge", value: outer.top, range: 0...60, step: 1, format: points) {
                            model.setOuterGap(Edges(all: $0))
                        }
                    }
                }
                SettingRow(title: "Set each edge separately") {
                    Toggle("Set each edge separately", isOn: SwiftUI.Binding(
                        get: { showsEachEdge },
                        set: { on in
                            perSide = on
                            if !on { model.setOuterGap(Edges(all: outer.top)) }
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingSection(title: "New windows") {
                SettingRow(title: "A new window",
                           detail: model.config.autoSplit
                               ? "Takes half of the focused window, cutting it along its longer side."
                               : "Joins the row or column of the focused window, and everything in it gets narrower.") {
                    Segmented(name: "A new window", options: [true, false], selection: model.config.autoSplit,
                              onSelect: { model.set(["layout", "auto-split"], .bool($0)) }) {
                        $0 ? "Splits the focused one" : "Joins its row"
                    }
                }
                SettingRow(title: "Resize step", detail: "How far one press of grow or shrink moves the divider.") {
                    ValueSlider(label: "Resize step", value: model.config.resizeStep * 100, range: 1...20, step: 1,
                                format: { "\(Int($0.rounded())) %" }) {
                        model.set(["layout", "resize-step"], .double($0 / 100))
                    }
                }
                SettingRow(title: "Stack peek", detail: "How much of each window in a stack shows behind the one in front.") {
                    ValueSlider(label: "Stack peek", value: model.config.stackPeek, range: 8...120, step: 4, format: points) {
                        model.setNumber(["layout", "stack-peek"], $0)
                    }
                }
                SettingRow(title: "Pointer follows focus", detail: "Move the pointer to a window when a shortcut focuses it.") {
                    Toggle("Pointer follows focus", isOn: SwiftUI.Binding(
                        get: { model.config.mouseFollowsFocus }, set: { model.set(["layout", "mouse-follows-focus"], .bool($0)) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingRow(title: "Focus follows pointer", detail: "Focus the window the pointer comes to rest on, without a click.") {
                    Toggle("Focus follows pointer", isOn: SwiftUI.Binding(
                        get: { model.config.focusFollowsMouse }, set: { model.set(["layout", "focus-follows-mouse"], .bool($0)) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingSection(title: "Stage Manager") {
                SettingRow(title: "Leave room for the strip of recent apps", detail: "Only matters while Stage Manager is on.") {
                    Segmented(name: "Leave room for the strip of recent apps", options: [0, 1, 2], selection: stripChoice, onSelect: setStrip) {
                        ["While it shows", "Always", "Never"][$0]
                    }
                }
                if stripChoice != 2 {
                    SettingRow(title: "Room to leave") {
                        ValueSlider(label: "Room for the Stage Manager strip", value: stripWidth, range: 60...300, step: 5, format: points) { width in
                            if stripChoice == 1 {
                                model.setNumber(["stage-manager", "reserve-strip"], width)
                            } else {
                                model.setNumber(["stage-manager", "strip-width"], width)
                            }
                        }
                    }
                }
            }

            FocusRingSection(model: model)
        }
        .onAppear { systemTiles = SystemTiling.tilesDraggedWindows }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemTiles = SystemTiling.tilesDraggedWindows
        }
    }

    private func edge(_ title: String, _ key: WritableKeyPath<Edges, Double>) -> some View {
        SettingRow(title: title) {
            ValueSlider(label: title, value: outer[keyPath: key], range: 0...60, step: 1, format: points) { v in
                var e = outer
                e[keyPath: key] = v
                // Four equal values would otherwise fold the sliders back into one mid-drag.
                perSide = true
                model.setOuterGap(e)
            }
        }
    }

    private var stripChoice: Int {
        switch model.config.stripReserve {
        case .auto: return 0
        case .points: return 1
        case .off: return 2
        }
    }

    private var stripWidth: Double {
        if case .points(let p) = model.config.stripReserve { return p }
        return model.config.stripWidth
    }

    private func setStrip(_ choice: Int) {
        switch choice {
        case 0: model.set(["stage-manager", "reserve-strip"], .string("auto"))
        case 1: model.setNumber(["stage-manager", "reserve-strip"], stripWidth)
        default: model.set(["stage-manager", "reserve-strip"], .bool(false))
        }
    }
}

// MARK: - Motion

private struct MotionPane: View {
    @ObservedObject var model: SettingsModel
    @State private var shuffle = 0

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var animation: Animation? {
        model.config.animate ? model.config.animationEasing.animation(duration: model.config.animationDuration) : nil
    }

    var body: some View {
        PaneScaffold(title: "Animation", subtitle: "How windows travel to their new place.") {
            HStack(alignment: .center, spacing: 24) {
                DesktopPreview(config: model.config, data: model.preview, shuffle: shuffle)
                    .animation(animation, value: shuffle)
                    .frame(width: DesktopPreview.width(forHeight: 172, data: model.preview), height: 172)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try the current settings on the preview before your real windows.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        shuffle += 1
                    } label: {
                        Label("Play a move", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
                    }
                    .glassButton()
                }
                Spacer(minLength: 0)
            }
        } content: {
            if reduceMotion {
                SettingSection {
                    Callout(.note, "Reduce Motion is on in System Settings, so windows are placed at once whatever is chosen here.")
                }
            }

            SettingSection(footer: "macOS cannot move another app's window without that app redrawing it. Apps that redraw slowly, such as browsers, skip frames and look less smooth than light apps. A shorter duration hides that best.") {
                SettingRow(title: "Animate window changes", detail: "Windows glide when one opens, closes, moves or is resized.") {
                    Toggle("Animate window changes", isOn: SwiftUI.Binding(
                        get: { model.config.animate },
                        set: {
                            model.set(["animation", "enabled"], .bool($0))
                            play()
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingRow(title: "Duration") {
                    ValueSlider(label: "Animation duration", value: model.config.animationDuration * 1000, range: 50...600, step: 10,
                                format: { "\(Int($0.rounded())) ms" }) {
                        model.set(["animation", "duration"], .double($0 / 1000))
                    }
                }
                .disabled(!model.config.animate)
                .opacity(model.config.animate ? 1 : 0.45)
                SettingRow(title: "Pacing") {
                    HStack(spacing: 10) {
                        EasingGlyph(easing: model.config.animationEasing).foregroundStyle(.secondary)
                        Segmented(name: "Pacing", options: [Easing.easeOut, .easeInOut, .linear], selection: model.config.animationEasing,
                                  onSelect: {
                                      model.set(["animation", "easing"], .string($0.rawValue))
                                      play()
                                  }) { $0.title }
                    }
                }
                .disabled(!model.config.animate)
                .opacity(model.config.animate ? 1 : 0.45)
            }
        }
    }

    private func play() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shuffle += 1 }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel
    @State private var customCommand = ""

    private let directions = [("left", "Left", "arrow.left"), ("down", "Down", "arrow.down"), ("up", "Up", "arrow.up"), ("right", "Right", "arrow.right")]
    private let desktops = (1...9).map { ("\($0)", "Desktop \($0)") } + [("next", "Next desktop"), ("prev", "Previous desktop")]
    private let windowCommands = [
        ("resize grow", "Grow"), ("resize shrink", "Shrink"), ("balance", "Even out all sizes"), ("zoom", "Fill the desktop"),
        ("flip", "Switch between side by side and top to bottom"), ("stack", "Stack or unstack"), ("float", "Float or tile"), ("close", "Close"), ("pause", "Pause tiling"),
    ]

    private var customText: String { customCommand.trimmingCharacters(in: .whitespaces) }
    private var customProblem: String? {
        guard !customText.isEmpty else { return nil }
        do {
            _ = try Command.parse(customText)
            return nil
        } catch {
            return "\(error)"
        }
    }

    var body: some View {
        PaneScaffold(title: "Shortcuts", subtitle: "Click a shortcut and type a new one. Delete clears it, Esc cancels.") {
            matrix(title: "Directions", columns: ["Focus", "Move", "Group with"], rows: directions.map { d in
                (AnyView(Label(d.1, systemImage: d.2).labelStyle(DirectionLabelStyle())), ["focus \(d.0)", "move \(d.0)", "join \(d.0)"])
            })

            SettingSection(title: "Focused window") {
                ForEach(windowCommands, id: \.0) { command in
                    SettingRow(title: command.1) { ShortcutCell(model: model, commandText: command.0) }
                }
            }

            matrix(title: "Desktops", columns: ["Go to", "Take the window to"], rows: desktops.map { d in
                (AnyView(Text(d.1)), ["space \(d.0)", "move-to-space \(d.0)"])
            })

            SettingSection(title: "Other commands", footer: "Any command Iguana understands can have a shortcut. Type it, then record the keys.") {
                ForEach(model.customBindings, id: \.source) { binding in
                    SettingRow(title: binding.commandText) { ShortcutCell(model: model, commandText: binding.commandText) }
                }
                HStack(spacing: 12) {
                    TextField("Command", text: $customCommand, prompt: Text("move-to-space 3 --stay"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Command for a new shortcut")
                    Spacer()
                    RecorderButton(model: model, slot: "custom|new", onClear: nil, onRecorded: { keys in
                        model.bind(keys, to: customText, replacing: nil)
                        customCommand = ""
                    }) {
                        Text("Record shortcut").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11).frame(height: 24)
                            .background(Capsule().fill(Theme.well))
                    }
                    .disabled(customText.isEmpty || customProblem != nil)
                    .opacity(customText.isEmpty || customProblem != nil ? 0.45 : 1)
                }
                if let customProblem { Callout(.attention, customProblem) }
            }

            SettingSection {
                HStack {
                    Text("In the settings file, ⌥ is written option.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore built-in shortcuts") { model.resetShortcuts() }
                        .glassButton()
                        .disabled(!model.shortcutsDifferFromBuiltIn)
                }
            }
        }
        .onDisappear { model.stopRecording() }
    }

    /// Commands that are one verb applied to several targets, as a table: targets down, verbs across.
    private func matrix(title: String, columns: [String], rows: [(AnyView, [String])]) -> some View {
        SettingSection(title: title) {
            HStack(spacing: 16) {
                Color.clear.frame(width: 150, height: 1)
                ForEach(columns, id: \.self) { column in
                    Text(column)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    row.0.frame(width: 150, alignment: .leading)
                    ForEach(row.1, id: \.self) { command in
                        ShortcutCell(model: model, commandText: command)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct DirectionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 14)
            configuration.title
        }
    }
}

/// The shortcuts of one command: its keys, or an empty slot to add one.
private struct ShortcutCell: View {
    @ObservedObject var model: SettingsModel
    let commandText: String

    private var bindings: [KeyBinding] {
        guard let command = try? Command.parse(commandText) else { return [] }
        return model.bindings(for: command)
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(bindings, id: \.source) { binding in
                RecorderButton(model: model, slot: "\(commandText)|\(binding.source)",
                               onClear: { model.unbind(binding) },
                               onRecorded: { model.bind($0, to: commandText, replacing: binding) }) {
                    KeyCaps(combo: binding.combo)
                }
                .contextMenu {
                    Button("Add Another Shortcut") {
                        model.startRecording(slot: "\(commandText)|new") { model.bind($0, to: commandText, replacing: nil) }
                    }
                    Button("Remove \(ShortcutFormat.display(binding.combo))") { model.unbind(binding) }
                }
                .help("Click to change. Right-click to add another or remove.")
                .accessibilityLabel("\(commandText): \(ShortcutFormat.spoken(binding.combo))")
                .accessibilityHint("Activate, then type a new shortcut")
            }
            if bindings.isEmpty || model.recording == "\(commandText)|new" {
                RecorderButton(model: model, slot: "\(commandText)|new", onClear: nil,
                               onRecorded: { model.bind($0, to: commandText, replacing: nil) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                        .contentShape(Rectangle())
                }
                .help("Add a shortcut")
                .accessibilityLabel("\(commandText): no shortcut")
                .accessibilityHint("Activate, then type a shortcut")
            }
        }
    }
}

/// Shows `label` until clicked, then listens for a shortcut.
private struct RecorderButton<Label: View>: View {
    @ObservedObject var model: SettingsModel
    let slot: String
    let onClear: (() -> Void)?
    let onRecorded: (String) -> Void
    @ViewBuilder var label: Label
    @State private var pulse = false

    private var recording: Bool { model.recording == slot }

    var body: some View {
        Button {
            if recording {
                model.stopRecording()
            } else {
                model.startRecording(slot: slot, onClear: onClear, completion: onRecorded)
            }
        } label: {
            if recording {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 5, height: 5).opacity(pulse ? 0.35 : 1)
                    Text("Type shortcut").font(Theme.rounded(11.5, .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Theme.accent))
                .onAppear {
                    pulse = false
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                }
            } else {
                label
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Floating windows

private struct FloatingPane: View {
    @ObservedObject var model: SettingsModel
    @State private var rows: [RuleRow] = []
    @State private var loadedFrom: [Rule]?

    struct RuleRow: Identifiable {
        let id = UUID()
        var app: String
        var title: String
        /// False for an exception: windows that match are tiled even if a later rule would float them.
        /// Nil for a rule that only names a desktop and says nothing about floating.
        var float: Bool? = true
        /// The desktop the rule sends new windows to.
        var desktop: Int?
        /// A row the user is still typing the app into.
        var isDraft = false
    }

    var body: some View {
        // Asked once for the pane, not once for every row.
        let desktopCount = Desktop.all().count
        PaneScaffold(title: "Window Rules", subtitle: "Apps whose windows float instead of being tiled, or open on a desktop of their own.") {
            if !Private.hasMoveBridge, rows.contains(where: { $0.desktop != nil }) {
                SettingSection {
                    Callout(.attention, "This version of macOS can only take a window to another desktop by going there with it, so the desktops chosen here are not used.")
                }
            }

            SettingSection {
                if rows.isEmpty {
                    Text("Nothing floats by rule. Every standard window is tiled. Add an app below to keep its windows where you put them.")
                        .foregroundStyle(.secondary)
                }
                ForEach($rows) { $row in
                    RuleRowView(row: $row, desktopCount: desktopCount, commit: commit) {
                        rows.removeAll { $0.id == row.id }
                        commit()
                    }
                }
            }

            SettingSection(footer: "Dialogs, sheets and windows that cannot be resized always float; they need no rule. To float one window for now, focus it and press the Float or tile shortcut. A window goes to the desktop chosen for it once, when it opens, and you stay where you are.") {
            HStack(spacing: 10) {
                Menu {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button {
                            rows.append(RuleRow(app: app.bundleIdentifier ?? app.localizedName ?? "", title: ""))
                            commit()
                        } label: {
                            Text(app.localizedName ?? app.bundleIdentifier ?? "App")
                            if let icon = app.icon { Image(nsImage: resized(icon, 16)) }
                        }
                    }
                    Divider()
                    Button("Another App…") { rows.append(RuleRow(app: "", title: "", isDraft: true)) }
                } label: {
                    Label("Add an App", systemImage: "plus")
                }
                .menuStyle(.button)
                .glassButton()
                .fixedSize()
                Spacer()
            }
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.config.rules) { load() }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func load() {
        guard model.config.rules != loadedFrom else { return }
        loadedFrom = model.config.rules
        let drafts = rows.filter { $0.isDraft && $0.app.trimmingCharacters(in: .whitespaces).isEmpty }
        rows = model.config.rules.map { RuleRow(app: $0.app ?? "", title: $0.title ?? "", float: $0.float, desktop: $0.desktop) } + drafts
    }

    private func commit() {
        let rules = rows
            .map { ($0.app.trimmingCharacters(in: .whitespaces), $0.title.trimmingCharacters(in: .whitespaces), $0.float, $0.desktop) }
            .filter { !$0.0.isEmpty || !$0.1.isEmpty }
            .map { Rule(app: $0.0.isEmpty ? nil : $0.0, title: $0.1.isEmpty ? nil : $0.1, float: $0.2, desktop: $0.3) }
        for i in rows.indices where !rows[i].app.trimmingCharacters(in: .whitespaces).isEmpty { rows[i].isDraft = false }
        loadedFrom = rules
        model.setRules(rules)
    }
}

private func resized(_ image: NSImage, _ side: CGFloat) -> NSImage {
    let copy = image.copy() as? NSImage ?? image
    copy.size = NSSize(width: side, height: side)
    return copy
}

private struct RuleRowView: View {
    @SwiftUI.Binding var row: FloatingPane.RuleRow
    /// How many desktops there are now, 0 when that is not known.
    let desktopCount: Int
    let commit: () -> Void
    let remove: () -> Void

    private var floats: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(get: { row.float ?? false }, set: { on in
            // Switched off, a rule that names a desktop says nothing about floating. One that
            // names none has to say `float = false`, or it would mean a floating rule again.
            row.float = on ? true : (row.desktop == nil ? false : nil)
            commit()
        })
    }

    private var desktop: SwiftUI.Binding<Int?> {
        SwiftUI.Binding(get: { row.desktop }, set: { n in
            if n == nil, row.float == nil { row.float = false }
            row.desktop = n
            commit()
        })
    }

    /// The desktops to offer: the ones there are, and the one the rule names if it is beyond them.
    private var desktopsOffered: ClosedRange<Int> {
        1...max(desktopCount > 0 ? desktopCount : 9, row.desktop ?? 1)
    }

    /// The app a rule names, looked up for its proper name and icon.
    private var app: (name: String, icon: NSImage) {
        let text = row.app.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        if !text.isEmpty, let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(text) == true
        }), let icon = running.icon {
            return (text, icon)
        }
        return (text.isEmpty ? "Any app" : text, NSWorkspace.shared.icon(for: .application))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                if row.isDraft {
                    TextField("App", text: $row.app, prompt: Text("App name or bundle identifier"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(.system(size: 13, weight: .medium))
                        .onSubmit(commit)
                } else {
                    HStack(spacing: 7) {
                        Text(app.name).font(.system(size: 13, weight: .medium))
                        if row.float == false {
                            // An exception written in the settings file: these windows are tiled.
                            Text("Tiled, as an exception")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Capsule().fill(Theme.accent.opacity(0.13)))
                        }
                    }
                }
                TextField("Title", text: $row.title, prompt: Text("All of its windows. Or type a pattern the title must match."))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .onSubmit(commit)
                    .accessibilityLabel("Title pattern for \(app.name)")
            }
            Spacer(minLength: 8)
            // The switch carries no label of its own: inside a form, a labelled control takes the
            // row over as "label on the left, control on the right" and pushes the app out of it.
            HStack(spacing: 6) {
                Text("Float").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Toggle("Float", isOn: floats)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Float the windows of \(app.name)")
            }
            .fixedSize()
            .help("Keep these windows where you put them instead of tiling them")
            Picker("Desktop for \(app.name)", selection: desktop) {
                Text("Any Desktop").tag(Int?.none)
                Divider()
                ForEach(desktopsOffered, id: \.self) { n in
                    Text(desktopCount > 0 && n > desktopCount ? "Desktop \(n) (not there now)" : "Desktop \(n)").tag(Int?.some(n))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Send these windows to a desktop when they open. You stay where you are.")
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove the rule for \(app.name)")
            .accessibilityLabel("Remove the rule for \(app.name)")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Hooks

private struct HooksPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PaneScaffold(title: "Hooks", subtitle: "Commands Iguana runs when something changes, for status bars and scripts.") {
            SettingSection {
                Callout(.attention, "Each command runs with /bin/sh and gets the facts as environment variables. A window title can be any text: write \"$IGUANA_TITLE\" with the double quotes, and never pass it to eval.")
            }
            SettingSection(footer: "A command is saved when you press Return or leave its field. An empty field runs nothing. The configuration reference lists the variables each event gets.") {
                ForEach(HookEvent.allCases, id: \.self) { HookRow(model: model, event: $0) }
            }
        }
    }
}

/// One event and its command. What is typed is written to the file when it is committed, not
/// on every key, so that a half-typed command never runs.
private struct HookRow: View {
    @ObservedObject var model: SettingsModel
    let event: HookEvent
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.rawValue).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                Text(event.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            TextField(event.rawValue, text: $text, prompt: Text("Runs nothing"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .focused($editing)
                .onSubmit(commit)
                .accessibilityLabel("Command for \(event.rawValue)")
        }
        .padding(.vertical, 2)
        .onAppear { text = model.hookCommand(event) }
        .onChange(of: editing) { if !editing { commit() } }
        // A change saved in the file shows up here, unless the field is being typed in.
        .onChange(of: model.config.hooks[event]) { if !editing { text = model.hookCommand(event) } }
        .onDisappear(perform: commit)
    }

    private func commit() { model.setHook(event, text) }
}
