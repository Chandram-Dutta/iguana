import AppKit
import ApplicationServices
import IguanaCore
import SwiftUI

extension WindowManager {
    /// Every standard window Iguana knows, on screen or not, for the window switcher, most
    /// recently focused first and the focused window last; and which app each belongs to.
    func switcherWindows() -> (windows: [Switcher.Window], owners: [CGWindowID: pid_t]) {
        let facts = self.facts()
        let snap = ScreenSnapshot.take()
        let desktops = Desktop.all()
        let showing = Set(displays.map(\.spaceID))
        let stages = StageManager.isOn
        var list: [Switcher.Window] = []
        var owners: [CGWindowID: pid_t] = [:]
        // Front to back, then the rest: the order of windows that have not had the focus yet.
        for id in snap.order + facts.windows.keys.sorted() where owners[id] == nil {
            guard let w = facts.windows[id], let app = facts.apps[w.pid]?.app,
                  w.tileable || w.element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
            let frame = snap.onScreen[id]
            let visibility: Switcher.Visibility
            if frame != nil {
                visibility = .onScreen
            } else if w.element.bool(kAXMinimizedAttribute) == true {
                visibility = .minimised
            } else if app.isHidden {
                visibility = .hidden
            } else if stages, Private.spaces(of: id).contains(where: showing.contains) {
                visibility = .otherStage
            } else {
                visibility = .elsewhere
            }
            owners[id] = w.pid
            list.append(Switcher.Window(id: id, app: app.localizedName ?? "pid \(w.pid)", title: w.element.string(kAXTitleAttribute) ?? "",
                                        desktop: place(of: id, frame: frame, desktops: desktops).desktop, visibility: visibility,
                                        focused: id == focusedWindow, lastFocused: lastFocused[id]))
        }
        return (Switcher.ordered(list), owners)
    }

    /// The window picked in the switcher: out of the Dock if it is minimised, with its app shown
    /// if that is hidden, then focused the way a click in the menu bar's miniature focuses one.
    /// A window on another desktop or in another stage takes the system there.
    func bringForward(_ id: CGWindowID) {
        let facts = self.facts()
        guard let w = facts.windows[id] else { return }
        if let app = facts.apps[w.pid]?.app, app.isHidden { app.unhide() }
        if w.element.bool(kAXMinimizedAttribute) == true { w.element.set(kAXMinimizedAttribute, false) }
        focusWindow(id)
    }
}

/// A panel that takes the keyboard without making Iguana the active app. The app in front
/// stays in front, and has the keyboard back as soon as the panel goes.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        if let field = searchField { makeFirstResponder(field) }
    }

    var searchField: NSView? { Self.field(in: contentView) }

    private static func field(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is SwitcherSearchField { return view }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }
}

/// Shows the window switcher (`switcher`) on the display in use, hands it the keyboard, and
/// gives the keyboard back when it goes.
///
/// The panel is non-activating, as Spotlight is: it becomes the key window, so what is typed
/// goes to it, but Iguana never becomes the active app and the app that was in front stays in
/// front. Esc puts the panel away and hands the keyboard back to that app. A click outside
/// gives the keyboard to whatever was clicked, which closes the panel. Return closes it and
/// focuses the chosen window.
final class SwitcherController: NSObject, NSWindowDelegate {
    let model = SwitcherModel()
    /// A window was chosen.
    var onChoose: ((WindowID) -> Void)?

    private let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: SwitcherView.width, height: SwitcherView.height(rows: 1)),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var monitor: Any?
    /// The app that had the keyboard before the switcher took it.
    private var previous: NSRunningApplication?
    private(set) var isShowing = false

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above other apps' floating panels, below the menu bar.
        panel.level = .modalPanel
        panel.becomesKeyOnlyIfNeeded = false
        // Iguana is hardly ever the active app, so a panel that hid when it is not would never show.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        // On the desktop being shown, over a fullscreen app too, and never in Mission Control.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: SwitcherView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        model.onChoose = { [weak self] id in self?.close(choosing: id) }
        model.onResize = { [weak self] in self?.fit() }
    }

    /// The panel itself, for tests.
    var window: NSWindow { panel }

    /// `display` is where the panel goes, in top-left coordinates; nil means the main display.
    func show(_ windows: [Switcher.Window], icons: [WindowID: NSImage], on display: CGRect?) {
        model.load(windows, icons: icons)
        let screen = NSScreen.screens.first { topLeftRect($0.frame) == display } ?? NSScreen.main ?? NSScreen.screens.first
        if let area = screen?.visibleFrame {
            // Hung from where the top of the panel is with all its rows, so that the field stays
            // put while the list gets shorter.
            let top = area.midY + SwitcherView.height(rows: SwitcherView.visibleRows) / 2
            let height = SwitcherView.height(rows: model.matches.count)
            panel.setFrame(NSRect(x: area.midX - SwitcherView.width / 2, y: top - height, width: SwitcherView.width, height: height), display: false)
        }
        previous = NSWorkspace.shared.frontmostApplication
        isShowing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.key(event) ?? event }
        let fade = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = fade ? 0 : 1
        // Laid out first, so that the search field is there to be given the keyboard.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.makeKey()
        // The shadow follows the rounded glass once it has been drawn.
        DispatchQueue.main.async { [panel] in panel.invalidateShadow() }
        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    /// `switcher` again while the panel is open: one row down.
    func step() { model.move(1) }

    /// The list got longer or shorter: the panel follows, its top edge where it was.
    private func fit() {
        guard isShowing else { return }
        var frame = panel.frame
        let height = SwitcherView.height(rows: model.matches.count)
        guard frame.height != height else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// The keys that work the list are taken before the search field sees them. Everything
    /// else is typed into it, and Iguana's own shortcuts are heard by the system first.
    private func key(_ event: NSEvent) -> NSEvent? {
        guard isShowing, event.window === panel else { return event }
        // While an input method is composing, the keys are its own.
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let letter = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command) {
            // Command-W closes the switcher, and Command-Q must not quit Iguana from it.
            guard letter == "w" || letter == "q" else { return event }
            close(choosing: nil)
            return nil
        }
        switch event.keyCode {
        case 125: model.move(1)
        case 126: model.move(-1)
        case 36, 76: model.choose()
        case 53: close(choosing: nil)
        default:
            guard flags.contains(.control), letter == "n" || letter == "p" else { return event }
            model.move(letter == "n" ? 1 : -1)
        }
        return nil
    }

    private func close(choosing choice: WindowID?) {
        guard isShowing else { return }
        isShowing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        if let choice {
            onChoose?(choice)
        } else if let previous, previous.processIdentifier != getpid(), !previous.isTerminated {
            // The app never stopped being in front, so this only makes sure the keyboard is
            // back with it, as it was before the switcher opened.
            previous.activate()
        }
        previous = nil
    }

    /// Another window took the keyboard: a click outside, or another app coming forward. The
    /// keyboard stays where it went.
    func windowDidResignKey(_ notification: Notification) {
        guard isShowing else { return }
        previous = nil
        close(choosing: nil)
    }
}

/// Renders the window switcher to PNG files, with made-up windows, in light and dark
/// appearance, with and without a query. A development aid (`iguana debug-switcher <folder>`):
/// it never talks to the running window manager and never looks at a real window.
enum SwitcherSnapshot {
    static func run(folder: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        SnapshotStage.prepare()
        let out = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let apps = ["Safari": "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
                    "Terminal": "/System/Applications/Utilities/Terminal.app", "Notes": "/System/Applications/Notes.app",
                    "Mail": "/System/Applications/Mail.app", "Calendar": "/System/Applications/Calendar.app",
                    "Music": "/System/Applications/Music.app", "Finder": "/System/Library/CoreServices/Finder.app",
                    "Preview": "/System/Applications/Preview.app", "Xcode": "/Applications/Xcode.app"]
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let windows: [Switcher.Window] = [
            .init(id: 1, app: "Terminal", title: "iguana — zsh — 120×40", desktop: 1, focused: true, lastFocused: now),
            .init(id: 2, app: "Safari", title: "Pull requests · iguana", desktop: 1, lastFocused: ago(1)),
            .init(id: 3, app: "Xcode", title: "Switcher.swift", desktop: 2, visibility: .elsewhere, lastFocused: ago(4)),
            .init(id: 4, app: "Notes", title: "Things to pack for the weekend", desktop: 1, visibility: .minimised, lastFocused: ago(9)),
            .init(id: 5, app: "Mail", title: "Inbox – iCloud", desktop: 1, lastFocused: ago(15)),
            .init(id: 6, app: "Safari", title: "Swift Package Index", desktop: 2, visibility: .elsewhere, lastFocused: ago(22)),
            .init(id: 7, app: "Calendar", title: "", desktop: 3, visibility: .elsewhere, lastFocused: ago(40)),
            .init(id: 8, app: "Music", title: "Recently Played", desktop: 1, visibility: .hidden, lastFocused: ago(55)),
            .init(id: 9, app: "Preview", title: "Floor plan.pdf", desktop: 1, visibility: .otherStage, lastFocused: ago(70)),
            .init(id: 10, app: "Finder", title: "Downloads", desktop: 1),
            .init(id: 11, app: "Terminal", title: "logs — tail -f Iguana.log", desktop: 3, visibility: .elsewhere),
            .init(id: 12, app: "Finder", title: "Documents", desktop: 2, visibility: .elsewhere),
        ]
        var icons: [WindowID: NSImage] = [:]
        for w in windows { if let path = apps[w.app] { icons[w.id] = NSWorkspace.shared.icon(forFile: path) } }
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        // "solid" is the panel as Reduce Transparency draws it.
        let scenes: [(name: String, query: String, selection: Int)] = [("all", "", 0), ("query", "sa", 1), ("none", "qqq", 0), ("solid", "re", 0)]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scene in scenes where SnapshotStage.wants("\(scene.name)-\(appearance == .aqua ? "light" : "dark")") {
                let model = SwitcherModel()
                model.load(Switcher.ordered(windows), icons: icons)
                model.query = scene.query
                model.selection = scene.selection
                // Room around the panel for its shadow, with the desktop behind it.
                let margin: CGFloat = 40
                let size = NSSize(width: SwitcherView.width + margin * 2, height: SwitcherView.height(rows: model.matches.count) + margin * 2)
                let window = NSWindow(contentRect: NSRect(origin: SnapshotStage.origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.appearance = NSAppearance(named: appearance)
                window.contentView = NSHostingView(rootView: ZStack {
                    if let picture = SnapshotStage.picture {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped()
                    }
                    SwitcherView(model: model, solid: scene.name == "solid")
                        .frame(width: SwitcherView.width, height: SwitcherView.height(rows: model.matches.count))
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                }.frame(width: size.width, height: size.height))
                window.setFrame(NSRect(origin: SnapshotStage.origin, size: size), display: true)
                window.orderFrontRegardless()
                spin(1.0)
                let file = out.appendingPathComponent("switcher-\(scene.name)-\(appearance == .aqua ? "light" : "dark").png")
                SnapshotStage.write(SnapshotStage.capture(window), to: file)
                window.orderOut(nil)
            }
        }
        exit(0)
    }
}
