import AppKit
import IguanaCore
import SwiftUI

/// The settings window. For the development snapshots it may sit off every screen, where the
/// system would otherwise pull a titled window back into view.
final class SettingsWindow: NSWindow {
    var staysOffScreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        staysOffScreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow?

    init(backend: SettingsBackend) {
        model = SettingsModel(backend: backend)
    }

    static func makeWindow(_ model: SettingsModel) -> SettingsWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        // The window keeps the size it is given; the settings scroll inside it.
        hosting.sizingOptions = []
        // The split view lays its columns out once, at the size it first appears with.
        hosting.view.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
        let window = SettingsWindow(contentViewController: hosting)
        window.title = "Iguana Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // A window with a bar across the top gets the system's sidebar, with the window buttons
        // inside it. The bar shows the name of the pane.
        window.toolbar = NSToolbar(identifier: "IguanaSettings")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 860, height: 600)
        window.setContentSize(NSSize(width: 900, height: 660))
        window.isReleasedWhenClosed = false
        return window
    }

    func show() {
        if window == nil {
            let w = Self.makeWindow(model)
            w.delegate = self
            w.center()
            window = w
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Keys pressed in another app must not be swallowed by a recording left running here.
        model.stopRecording()
    }
}

/// Renders every pane of the settings window to PNG files, in light and dark appearance.
/// A development aid (`iguana debug-snapshot <folder>`): it works on a throwaway config file and
/// never talks to the running window manager.
enum SettingsSnapshot {
    private final class FileBackend: SettingsBackend {
        let configURL: URL
        private(set) var config = Config.default
        private(set) var problems: [String] = []
        private(set) var isPaused = false

        init(url: URL) {
            configURL = url
            reloadConfig()
        }

        func reloadConfig() {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
                config = .default
                problems = []
                return
            }
            do {
                (config, problems) = try Config.load(text)
            } catch {
                problems = ["\(error)"]
            }
        }

        func setPaused(_ paused: Bool) { isPaused = paused }
        func suspendShortcuts(_ suspended: Bool) {}
        var tiledWindowCount: Int { 3 }

        /// The example desktop, dressed with the icons of three apps every Mac has.
        func desktopPreview() -> DesktopPreviewData? {
            var data = DesktopPreviewData.example
            let apps = ["/System/Applications/Utilities/Terminal.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app", "/System/Applications/Notes.app"]
            for (i, path) in apps.enumerated() { data.icons[WindowID(i + 1)] = NSWorkspace.shared.icon(forFile: path) }
            data.isExample = false
            return data
        }
    }

    static func run(folder: String, sampleConfig: String?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        SnapshotStage.prepare()
        let out = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let configURL = out.appendingPathComponent("snapshot-config/iguana.toml")
        try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
        if let sampleConfig { try? ConfigFile.write(sampleConfig, to: configURL) }

        let model = SettingsModel(backend: FileBackend(url: configURL))
        let window = SettingsWindowController.makeWindow(model)
        window.staysOffScreen = true
        // A pane that is longer than the window can be photographed whole: IGUANA_SNAPSHOT_HEIGHT=1600.
        if let height = ProcessInfo.processInfo.environment["IGUANA_SNAPSHOT_HEIGHT"].flatMap(Double.init), height > 200 {
            window.setContentSize(NSSize(width: window.frame.width, height: height))
        }
        window.setFrameOrigin(SnapshotStage.origin)
        window.orderFrontRegardless()

        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for pane in Pane.allCases where SnapshotStage.wants("\(pane.rawValue)-\(appearance == .aqua ? "light" : "dark")") {
                model.pane = pane
                spin(0.5)
                if ProcessInfo.processInfo.environment["IGUANA_SNAPSHOT_DEBUG"] != nil {
                    print("window", window.frame, "content", window.contentView?.frame ?? .zero, "layout", window.contentLayoutRect,
                          "toolbar", window.toolbar != nil, "safe", window.contentView?.safeAreaInsets ?? NSEdgeInsets())
                    func dump(_ v: NSView, _ depth: Int) {
                        guard depth < 7 else { return }
                        var extra = ""
                        if #available(macOS 26.0, *), let glass = v as? NSGlassEffectView { extra = " corner \(glass.cornerRadius) style \(glass.style.rawValue)" }
                        if let split = v as? NSSplitView { extra = " dividerStyle \(split.dividerStyle.rawValue)" }
                        print(String(repeating: "  ", count: depth), type(of: v), v.frame, extra)
                        v.subviews.forEach { dump($0, depth + 1) }
                    }
                    if let v = window.contentView { dump(v, 0) }
                }
                let name = "\(pane.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                SnapshotStage.write(SnapshotStage.capture(window), to: out.appendingPathComponent(name))
            }
        }
        exit(0)
    }
}
