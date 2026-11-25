import CoreGraphics
import IguanaCore

/// Takes windows to their frames. `Animator` is the one that moves real windows; a test uses
/// one that puts each window in its place at once.
protocol FrameMover: AnyObject {
    /// Called on the main thread when a window has been given its final frame, with the frame
    /// that was asked for and the size the window actually took.
    var onLanded: ((CGWindowID, CGRect, CGSize?) -> Void)? { get set }

    /// Where a window is on its way to, if it is being moved.
    func destination(of id: CGWindowID) -> CGRect?
    func isMoving(_ id: CGWindowID) -> Bool
    /// On its way as a glide, as opposed to having been placed at once.
    func isGliding(_ id: CGWindowID) -> Bool

    /// Take a window to `to`. A window that is already gliding continues from where it is now.
    func move(_ id: CGWindowID, pid: pid_t, element: UIElement, app: UIElement?,
              from: CGRect, to: CGRect, duration: Double, easing: Easing)
    /// Stop moving a window and leave it where it is (the user grabbed it, or it is gone).
    func cancel(_ id: CGWindowID)
    func forget(pid: pid_t)
}
