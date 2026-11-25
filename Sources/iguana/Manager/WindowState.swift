import AppKit
import ApplicationServices
import IguanaCore

final class WindowState {
    let id: CGWindowID
    let pid: pid_t
    let element: UIElement
    /// A standard window that can be moved and resized. Dialogs, sheets and fixed-size windows are left alone.
    var tileable: Bool
    var ruleFloat = false
    var userFloat: Bool?
    /// The frame Iguana last asked for, used to tell its own changes from the user's.
    var lastSetFrame: CGRect?
    /// Learned when a window refuses to get as small as its slot.
    var minSize: CGSize?

    var floating: Bool { userFloat ?? ruleFloat }

    init(id: CGWindowID, pid: pid_t, element: UIElement, tileable: Bool) {
        self.id = id
        self.pid = pid
        self.element = element
        self.tileable = tileable
    }
}
