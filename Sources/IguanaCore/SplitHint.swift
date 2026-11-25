import Foundation

extension Tree {
    /// Whether a window that opens beside this one joins the stack it is in. `insert` puts it
    /// there whatever split it is asked for, so a `split` hint has nothing to say there.
    public func newWindowJoinsStack(beside id: WindowID) -> Bool { node(id)?.parent?.stacked == true }
}
