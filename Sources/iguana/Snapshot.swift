import AppKit
import SwiftUI

/// Photographs a window for the development snapshots (`iguana debug-snapshot`, `debug-tour`).
///
/// A picture of a single window does not include what the system blurs behind it, so a
/// see-through window would come out flat. For the pictures only, the desktop picture is drawn
/// inside the window and blurred there, which shows the same thing.
enum SnapshotStage {
    /// Far off any screen, so that taking the pictures never covers what is being worked on.
    static let origin = NSPoint(x: 20_000, y: 20_000)

    /// The stand-in for the desktop. Nil outside the snapshot commands.
    private(set) static var picture: NSImage?

    static func prepare() {
        if let path = ProcessInfo.processInfo.environment["IGUANA_SNAPSHOT_WALLPAPER"], let image = NSImage(contentsOfFile: path) {
            picture = image
        } else if let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
            picture = image
        } else {
            let size = NSSize(width: 1600, height: 1000)
            picture = NSImage(size: size, flipped: false) { rect in
                NSGradient(colors: [.systemIndigo, .systemPink, .systemOrange])?.draw(in: rect, angle: 35)
                return true
            }
        }
    }

    /// `IGUANA_SNAPSHOT_ONLY=name,name` limits the pictures to the files whose name contains one of them.
    static func wants(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["IGUANA_SNAPSHOT_ONLY"] else { return true }
        return only.split(separator: ",").contains { name.contains($0) }
    }

    /// The window as the system draws it, with its glass, shadows and masks. The call is no
    /// longer in the headers, so it is looked up by name; plain view rendering is the fallback.
    static func capture(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let fn = Private.fn("CGWindowListCreateImage", Fn.self),
           let image = fn(.null, 1 << 3, UInt32(truncatingIfNeeded: window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(), image.width > 8 {
            return image
        }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    static func write(_ image: CGImage?, to file: URL) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("could not capture \(file.lastPathComponent)")
            return
        }
        try? data.write(to: file)
        print("wrote \(file.path)")
    }
}

/// What a see-through window has behind its content: the desktop, softened by the system.
struct WindowBackdrop: View {
    let material: NSVisualEffectView.Material

    var body: some View {
        if let picture = SnapshotStage.picture {
            GeometryReader { geometry in
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(VisualEffect(material: material, state: .active, blending: .withinWindow))
            }
        } else {
            VisualEffect(material: material, state: .active)
        }
    }
}
