import AppKit

/// macOS has window tiling of its own since macOS 15: a window dragged to a screen edge, or to
/// the menu bar, gets an outline from the system and is resized when it is let go. With Iguana
/// running the two answer the same drag. Iguana cannot switch the system's off, and should not:
/// it is the user's setting. It can say so, and take the user to where the switch is.
enum SystemTiling {
    /// Whether the system tiles a window that is dragged to an edge of the screen.
    /// The settings are on until the user has switched them off, which is when they are written.
    static var tilesDraggedWindows: Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else { return false }
        return setting("EnableTilingByEdgeDrag") || setting("EnableTopTilingByEdgeDrag")
    }

    private static func setting(_ key: String) -> Bool {
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        return (CFPreferencesCopyAppValue(key as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? true
    }

    /// Desktop & Dock in System Settings, which is where the window tiling switches are.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
