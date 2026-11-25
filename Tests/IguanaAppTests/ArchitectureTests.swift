import XCTest

/// The rule the window manager's tests rest on: nothing in `Sources/iguana/Manager` talks to
/// macOS itself. It asks `system` and waits with `scheduler`. A call that goes round them
/// cannot be reached by a test, and in a test it would act on the real desktop.
final class ArchitectureTests: XCTestCase {
    /// What only `Sources/iguana/Platform` may say, and what to say instead.
    private static let forbidden: [(pattern: String, instead: String)] = [
        ("NSWorkspace", "system (WindowSystem)"),
        ("NSRunningApplication", "RunningApp"),
        ("AXUIElement", "UIElement"),
        ("AXObserver", "AppObserver"),
        ("AXIsProcessTrusted", "system.isTrusted"),
        ("CGWindowListCopyWindowInfo", "system.snapshot() or system.windowOwners()"),
        ("CGEvent(", "system.pointerLocation or system.postMouse"),
        ("CGWarpMouseCursorPosition", "system.warpPointer(to:)"),
        ("CGEventSource", "system.leftMouseIsDown"),
        ("NSEvent.", "a SystemEvent from system.start"),
        ("NSScreen", "system.displays()"),
        ("NSApp", "system.terminate()"),
        ("DispatchQueue", "scheduler.after"),
        ("Date()", "scheduler.now"),
        ("usleep", "scheduler.sleep"),
        ("ScreenSnapshot.take", "system.snapshot()"),
        ("DisplayInfo.current", "system.displays()"),
        ("Desktop.all", "system.desktops()"),
        ("StageManager.current", "system.stageManager"),
        ("Private.spaces", "system.spaces(of:)"),
        ("Private.focus", "system.focus(pid:window:)"),
        ("Private.press", "system.press(shortcut:)"),
        ("Private.requestMove", "system.requestMove(window:toSpace:)"),
        ("Private.windowID", "element.windowID"),
    ]

    /// `Animator` writes frames from a queue of its own for each app and is driven by the
    /// display's refresh. It is the one part of the folder that is the Mac's, and the window
    /// manager reaches it only as a `FrameMover`.
    private static let exempt: Set<String> = ["Animator.swift"]

    private var managerFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/iguana/Manager")
    }

    func testTheWindowManagerReachesMacOSOnlyThroughTheWindowSystem() throws {
        let files = try FileManager.default.contentsOfDirectory(at: managerFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !Self.exempt.contains($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 10, "the window manager's files were not found at \(managerFolder.path)")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                // What a comment says is not a call.
                // Nor is the name of a notification, which has the type's name in it.
                let code = (line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line)
                    .replacingOccurrences(of: "kAXUIElementDestroyedNotification", with: "")
                for rule in Self.forbidden where code.contains(rule.pattern) {
                    XCTFail("\(file.lastPathComponent):\(number + 1) uses \(rule.pattern); use \(rule.instead)")
                }
            }
        }
    }
}
