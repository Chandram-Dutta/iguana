import AppKit
import IguanaCore
import SwiftUI

/// What the top of the menu bar item's menu shows.
final class DeskModel: ObservableObject {
    struct Desk: Identifiable {
        let number: Int
        let isActive: Bool
        let preview: DesktopPreviewData
        var id: Int { number }
    }

    @Published var desks: [Desk] = []
    @Published var config = Config.default
    @Published var paused = false
    @Published var needsPermission = false

    var onFocus: (WindowID) -> Void = { _ in }
    var onGo: (Int) -> Void = { _ in }

    var active: Desk? { desks.first { $0.isActive } ?? desks.first }
}

/// The top of the menu under the menu bar item: the desktop you are on, large enough to click a
/// window in, and every other desktop beside it. It is an item of an ordinary menu, so the
/// window around it, its corners and its shadow are the system's; the commands are the menu's
/// own items underneath.
struct DeskView: View {
    @ObservedObject var model: DeskModel

    static let width: CGFloat = 320
    private static let inset: CGFloat = 14

    private var status: String {
        if model.needsPermission { return "Iguana cannot move windows until it has Accessibility permission." }
        if model.paused { return "Paused: windows stay where they are" }
        let count = model.active?.preview.visible.count ?? 0
        return count == 0 ? "No tiled windows here" : (count == 1 ? "1 window tiled" : "\(count) windows tiled")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.needsPermission ? "Iguana" : (model.active.map { "Desktop \($0.number)" } ?? "Iguana"))
                    .font(Theme.rounded(15, .bold))
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.needsPermission, let active = model.active {
                let inner = Self.width - Self.inset * 2
                DesktopPreview(config: model.config, data: active.preview, cornerRadius: 9) { model.onFocus($0) }
                    .frame(width: inner, height: inner * active.preview.screen.height / max(active.preview.screen.width, 1))
                    .opacity(model.paused ? 0.6 : 1)
                    .help("Click a window to bring it forward")

                if model.desks.count > 1 { strip }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(width: Self.width, alignment: .leading)
        .tint(Theme.accent)
    }

    /// Every desktop with its own layout. Click one to go there.
    private var strip: some View {
        let spacing: CGFloat = 8
        let count = CGFloat(model.desks.count)
        let room = Self.width - Self.inset * 2
        let width = min(max((room - spacing * (count - 1)) / count, 34), 70)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(model.desks) { desk in
                    VStack(spacing: 3) {
                        DesktopPreview(config: model.config, data: desk.preview, cornerRadius: 4.5)
                            .frame(width: width, height: width * desk.preview.screen.height / max(desk.preview.screen.width, 1))
                            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 2).opacity(desk.isActive ? 1 : 0))
                        Text("\(desk.number)")
                            .font(Theme.rounded(11, desk.isActive ? .bold : .medium))
                            .foregroundStyle(desk.isActive ? Color.primary : Color.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if !desk.isActive { model.onGo(desk.number) } }
                    .help(desk.isActive ? "You are on desktop \(desk.number)" : "Go to desktop \(desk.number)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Desktop \(desk.number), \(desk.preview.visible.count) windows")
                    .accessibilityAddTraits(desk.isActive ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Renders the top of the menu and the icon to PNG files. A development aid (`iguana debug-desk <folder>`).
enum DeskSnapshot {
    static func run(folder: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        SnapshotStage.prepare()
        let out = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let apps = ["/System/Applications/Utilities/Terminal.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
                    "/System/Applications/Notes.app", "/System/Applications/Calendar.app", "/System/Applications/Music.app"]
        func icon(_ i: Int) -> NSImage { NSWorkspace.shared.icon(forFile: apps[i % apps.count]) }
        let screen = CGSize(width: 1512, height: 982), usable = CGRect(x: 0, y: 38, width: 1512, height: 944)
        func desk(_ number: Int, active: Bool, build: (Tree) -> Void) -> DeskModel.Desk {
            let tree = Tree()
            build(tree)
            var icons: [WindowID: NSImage] = [:]
            for id in tree.windows { icons[id] = icon(Int(id)) }
            return DeskModel.Desk(number: number, isActive: active, preview: DesktopPreviewData(
                layout: tree.snapshot, visible: Set(tree.windows), icons: icons, focused: tree.windows.last, screen: screen, usable: usable, isExample: false))
        }
        let model = DeskModel()
        model.desks = [
            desk(1, active: false) { $0.insert(1); $0.insert(2, after: 1, split: .horizontal) },
            desk(2, active: true) { $0.insert(3); $0.insert(4, after: 3, split: .horizontal); $0.insert(5, after: 4, split: .vertical) },
            desk(3, active: false) { $0.insert(6) },
            desk(4, active: false) { _ in },
            desk(5, active: false) { $0.insert(7); $0.insert(8, after: 7, split: .horizontal); $0.insert(9, after: 8, split: .vertical); $0.insert(10, after: 9, split: .horizontal) },
        ]
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = NSSize(width: 460, height: 420)
            let window = NSWindow(contentRect: NSRect(origin: SnapshotStage.origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: appearance)
            // In the app the system's menu is around this view; a pane of glass stands in for it here.
            window.contentView = NSHostingView(rootView: ZStack {
                if let picture = SnapshotStage.picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped()
                }
                DeskView(model: model).glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }.frame(width: size.width, height: size.height))
            window.setFrame(NSRect(origin: SnapshotStage.origin, size: size), display: true)
            window.orderFrontRegardless()
            spin(1.0)
            SnapshotStage.write(SnapshotStage.capture(window), to: out.appendingPathComponent("desk-\(appearance == .aqua ? "light" : "dark").png"))
            window.orderOut(nil)
        }

        // The icon in each of its states, enlarged, on a light and a dark bar.
        let states: [StatusIcon.State] = model.desks.map { .layout($0.preview.layout, windows: $0.preview.visible, focused: $0.preview.focused) }
            + [.paused, .needsPermission]
        let scale: CGFloat = 8
        let strip = StatusIcon.row(model.desks.map {
            StatusIcon.Desk(number: $0.number, isActive: $0.isActive, layout: $0.preview.layout, windows: $0.preview.visible, focused: $0.preview.focused)
        }, aspect: screen.width / screen.height, label: "2").image
        let images = states.map { StatusIcon.image($0, aspect: screen.width / screen.height, label: "2") } + [strip]
        let cell: CGFloat = 46
        let sheet = NSImage(size: NSSize(width: (CGFloat(states.count) * cell + strip.size.width + 12) * scale, height: 2 * 24 * scale), flipped: true) { rect in
            for (row, dark) in [false, true].enumerated() {
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: CGFloat(row) * 24 * scale, width: rect.width, height: 24 * scale).fill()
                for (column, image) in images.enumerated() {
                    let tinted = NSImage(size: image.size, flipped: true) { r in
                        image.draw(in: r)
                        (dark ? NSColor.white : NSColor.black).set()
                        r.fill(using: .sourceIn)
                        return true
                    }
                    tinted.draw(in: NSRect(x: (CGFloat(column) * cell + 6) * scale, y: (CGFloat(row) * 24 + (24 - image.size.height) / 2) * scale,
                                           width: image.size.width * scale, height: image.size.height * scale))
                }
                // The line everything should sit on.
                NSColor.systemRed.withAlphaComponent(0.5).setFill()
                NSRect(x: 0, y: (CGFloat(row) * 24 + 12) * scale - 0.5, width: rect.width, height: 1).fill()
            }
            return true
        }
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: out.appendingPathComponent("icons.png"))
            print("wrote \(out.appendingPathComponent("icons.png").path)")
        }
        exit(0)
    }
}
