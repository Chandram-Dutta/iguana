import AppKit
import ApplicationServices

// The only undocumented calls Iguana makes. Everything here is read-only or asks the system to
// do something it already offers the user (focus a window, run a Mission Control shortcut).
// Nothing needs System Integrity Protection to be turned off.

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum Private {
    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let anyImage = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT

    static func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(skylight, name) ?? dlsym(anyImage, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static let connection: Int32 = fn("SLSMainConnectionID", (@convention(c) () -> Int32).self)?() ?? 0

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// One entry per display: its identifier, its current Space and all of its Spaces in Mission Control order.
    static func managedDisplaySpaces() -> [[String: Any]] {
        typealias Fn = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let f = fn("SLSCopyManagedDisplaySpaces", Fn.self) else { return [] }
        return f(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// The Spaces a window is on (more than one for a window assigned to all desktops). Empty when unknown.
    static func spaces(of window: CGWindowID) -> [UInt64] {
        typealias Fn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        guard let f = fn("SLSCopySpacesForWindows", Fn.self) else { return [] }
        let list = f(connection, 0x7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return list?.map(\.uint64Value) ?? []
    }

    /// Ask the system's window-management bridge to put a window on another Space. This is the
    /// route macOS itself takes on recent versions; it is instant and does not switch Space. It
    /// only works inside a running app (AppKit installs the bridge), and the request is
    /// asynchronous, so the caller checks `spaces(of:)` to see whether the window arrived.
    static func requestMove(window: CGWindowID, toSpace space: UInt64) -> Bool {
        let initialise = NSSelectorFromString("initWithWindows:spaceID:")
        let perform = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              class_getInstanceMethod(cls, initialise) != nil, class_getInstanceMethod(cls, perform) != nil,
              let send = dlsym(anyImage, "objc_msgSend") else { return false }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias Init = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        typealias Perform = @convention(c) (AnyObject, Selector) -> AnyObject?
        guard let allocated = unsafeBitCast(send, to: Alloc.self)(cls, NSSelectorFromString("alloc")),
              let operation = unsafeBitCast(send, to: Init.self)(allocated, initialise, [NSNumber(value: window)] as NSArray, space)
        else { return false }
        _ = unsafeBitCast(send, to: Perform.self)(operation, perform)
        return true
    }

    // MARK: Focus

    /// Bring one specific window to the front without raising the app's other windows.
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
        typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
        typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
        guard let getPSN = fn("GetProcessForPID", GetPSN.self),
              let setFront = fn("_SLPSSetFrontProcessWithOptions", SetFront.self),
              let post = fn("SLPSPostEventRecordTo", PostRecord.self) else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        guard setFront(&psn, windowID, 0x200) == 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { raw in for i in 0..<4 { bytes[0x3c + i] = raw[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
        return true
    }

    // MARK: Mission Control shortcuts

    enum SystemShortcut {
        static let spaceLeft: Int32 = 79
        static let spaceRight: Int32 = 81
        static func desktop(_ n: Int) -> Int32 { Int32(117 + n) }
    }

    /// Press one of the system's own Mission Control shortcuts, whatever keys the user gave it.
    /// A shortcut that is switched off in System Settings is enabled just long enough to fire.
    static func press(shortcut: Int32) -> Bool {
        typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UniChar>, UnsafeMutablePointer<UniChar>, UnsafeMutablePointer<UInt32>) -> Int32
        typealias IsEnabled = @convention(c) (Int32) -> Bool
        typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
        guard let getValue = fn("CGSGetSymbolicHotKeyValue", GetValue.self),
              let isEnabled = fn("CGSIsSymbolicHotKeyEnabled", IsEnabled.self),
              let setEnabled = fn("CGSSetSymbolicHotKeyEnabled", SetEnabled.self) else { return false }
        var char: UniChar = 0, keyCode: UniChar = 0
        var flags: UInt32 = 0
        guard getValue(shortcut, &char, &keyCode, &flags) == 0, keyCode != 0xffff else { return false }
        let wasEnabled = isEnabled(shortcut)
        if !wasEnabled { _ = setEnabled(shortcut, true) }
        let modifiers = CGEventFlags(rawValue: UInt64(flags))
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return false }
            e.flags = modifiers
            e.post(tap: .cghidEventTap)
        }
        // A posted event that carries Control makes the system record the Control key as held,
        // and nothing ever records it as released. Release what the shortcut used.
        let keys: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 59), (.maskShift, 56), (.maskAlternate, 58), (.maskCommand, 55)]
        for (flag, key) in keys where modifiers.contains(flag) {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { continue }
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
        if !wasEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = setEnabled(shortcut, false) }
        }
        return true
    }
}

// MARK: - Accessibility helpers

extension AXUIElement {
    func raw(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { raw(name) as? String }
    func bool(_ name: String) -> Bool? { (raw(name) as? NSNumber)?.boolValue }

    func element(_ name: String) -> AXUIElement? {
        guard let v = raw(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement]? { raw(name) as? [AXUIElement] }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    var position: CGPoint? {
        guard let v = raw(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = raw(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func setPosition(_ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    func setSize(_ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, v) == .success
    }

    @discardableResult
    func set(_ name: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value as CFBoolean) == .success
    }
}

// MARK: - Coordinates

/// Accessibility and CoreGraphics measure from the top-left corner of the primary display with y
/// growing downwards. AppKit measures from its bottom-left corner with y growing upwards.
func topLeftRect(_ appKit: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: appKit.minX, y: primaryHeight - appKit.maxY, width: appKit.width, height: appKit.height)
}

func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.5) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

// MARK: - Logging

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return dir.appendingPathComponent("Iguana.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
