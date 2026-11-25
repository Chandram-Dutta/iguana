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

    /// Whether this macOS has the bridge `requestMove` asks. Without it a window only reaches
    /// another Space by being carried there, which takes the user along.
    static let hasMoveBridge: Bool = {
        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else { return false }
        return class_getInstanceMethod(cls, NSSelectorFromString("initWithWindows:spaceID:")) != nil
            && class_getInstanceMethod(cls, NSSelectorFromString("performWithWMBridgeDelegate")) != nil
    }()

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
