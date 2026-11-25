import IguanaCore
import SwiftUI

/// The scenes of the welcome tour, in order.
enum TourStep: Int, CaseIterable, Comparable {
    case hello, open, focus, move, resize, stack, desktops, permission, done

    static func < (a: TourStep, b: TourStep) -> Bool { a.rawValue < b.rawValue }

    /// The steps that are practised on the play desktop.
    var isLesson: Bool { self >= .open && self <= .desktops }
}

extension TourModel {
    // MARK: Steps

    func isAvailable(_ step: TourStep) -> Bool {
        switch step {
        case .hello, .open, .done: return true
        case .focus, .move, .resize, .stack: return keys(for: step) != nil
        case .desktops:
            let jump = numberKeys { $0 == .space(.index($1)) }
            let carry = numberKeys { command, n in
                if case .moveToSpace(.index(n), _) = command { return true }
                return false
            }
            return jump != nil && carry != nil
        case .permission: return !isTrusted()
        }
    }

    /// The lessons this tour will go through, for the progress marks.
    var lessons: [TourStep] { TourStep.allCases.filter { $0.isLesson && isAvailable($0) } }

    func begin() {
        play(.hello)
    }

    /// Return, Space, or a click on the prompt.
    func primary() {
        switch step {
        case .hello: go(to: .open)
        case .open: openWindow()
        case .permission: requestPermission()
        case .done: finish()
        default: break
        }
    }

    func advance() {
        let later = TourStep.allCases.filter { $0 > step }
        go(to: later.first(where: isAvailable) ?? .done)
    }

    func go(to next: TourStep) {
        advancing = false
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
            // A lesson that is skipped still needs its windows.
            if next.isLesson, next > .open { fillDesktop() }
            step = next
            beacon = nil
            desktopBeacon = nil
            ghost = nil
            goalWindow = nil
            overview = next == .desktops
            revision += 1
            switch next {
            case .focus:
                reached = 0
                pickBeacon()
            case .move:
                goalWindow = focusedWindow
                movesMade = 0
                goalDirection = canMove(.left) ? .left : .right
            case .resize:
                goalWindow = focusedWindow
                growsNeeded = 3
            case .stack:
                stackGoal = .press
                crowdColumn()
            case .desktops:
                desktopGoal = .jump
                prepareDesktops()
            case .permission:
                permission = .idle
                watchTrust()
            default:
                break
            }
            restack()
            refreshGoals()
        }
    }

    private func fillDesktop() {
        while desktops[0].windows.count < Self.windowsToOpen { addWindow() }
        if desktops[current].focused == nil { desktops[current].focused = desktops[current].windows.last }
    }

    private func addWindow() {
        let id = nextID
        nextID += 1
        colors[id] = Int(id - 1)
        order.insert(id, at: 0)
        adopt(id, into: 0)
        touch(id)
    }

    /// The stack lesson starts from one tile beside a column of three: more windows in a column
    /// than sit there comfortably. The windows that are here stay on the side they are on, and
    /// one more opens under them and has the focus, as a new window does.
    private func crowdColumn() {
        let old = desktops[0].windows
        guard old.count == Self.windowsToOpen, let front = desktops[0].focused ?? old.last else { return }
        let placed = frames(0)
        func middle(_ id: WindowID) -> CGPoint { placed[id].map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero }
        // The window furthest to the side of the focused one keeps a side of the desktop to itself.
        let others = old.filter { $0 != front }
        guard let alone = others.max(by: { abs(middle($0).x - middle(front).x) < abs(middle($1).x - middle(front).x) }) else { return }
        let column = old.filter { $0 != alone }.sorted { (middle($0).y, middle($0).x) < (middle($1).y, middle($1).x) }

        let id = nextID
        nextID += 1
        colors[id] = Self.stackColor
        order.insert(id, at: 0)

        let tree = Tree()
        if middle(front).x < middle(alone).x {
            tree.insert(column[0])
            tree.insert(alone, after: column[0])
        } else {
            tree.insert(alone)
            tree.insert(column[0], after: alone)
        }
        tree.insert(column[1], after: column[0], split: .vertical)
        tree.insert(id, after: column[1])
        tree.focused = id
        desktops[0] = tree
        touch(id)
    }

    private func openWindow() {
        guard windowCount < Self.windowsToOpen, !advancing else { return }
        let n = windowCount
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
            addWindow()
            revision += 1
        }
        play(.open(n))
        if windowCount == Self.windowsToOpen { succeed(sound: false) }
    }

    func succeed(sound: Bool = true) {
        guard !advancing else { return }
        advancing = true
        beacon = nil
        desktopBeacon = nil
        ghost = nil
        celebrations += 1
        if sound { after(0.12) { [weak self] in self?.play(.success) } }
        let from = step
        after(sound ? 1.0 : 0.75) { [weak self] in
            guard let self, self.step == from, self.advancing else { return }
            self.advance()
        }
    }
}
