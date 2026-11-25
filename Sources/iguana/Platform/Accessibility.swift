import AppKit
import ApplicationServices

/// An element of another app, read and written through the Accessibility API.
final class AXElement: UIElement {
    let ax: AXUIElement

    init(_ ax: AXUIElement) { self.ax = ax }

    func string(_ name: String) -> String? { ax.string(name) }
    func bool(_ name: String) -> Bool? { ax.bool(name) }
    func element(_ name: String) -> UIElement? { ax.element(name).map(AXElement.init) }
    func elements(_ name: String) -> [UIElement]? { ax.elements(name)?.map(AXElement.init) }
    func isSettable(_ name: String) -> Bool { ax.isSettable(name) }
    var position: CGPoint? { ax.position }
    var size: CGSize? { ax.size }
    @discardableResult func setPosition(_ p: CGPoint) -> Bool { ax.setPosition(p) }
    @discardableResult func setSize(_ s: CGSize) -> Bool { ax.setSize(s) }
    @discardableResult func set(_ name: String, _ value: Bool) -> Bool { ax.set(name, value) }
    @discardableResult func perform(_ action: String) -> Bool { AXUIElementPerformAction(ax, action as CFString) == .success }
    var windowID: CGWindowID? { Private.windowID(of: ax) }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(ax, &pid)
        return pid
    }

    func isSame(as other: UIElement) -> Bool {
        (other as? AXElement).map { CFEqual(ax, $0.ax) } ?? false
    }
}

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
