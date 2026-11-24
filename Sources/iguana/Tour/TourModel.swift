import AppKit
import IguanaCore
import SwiftUI

/// The scenes of the welcome tour, in order.
enum TourStep: Int, CaseIterable, Comparable {
    case hello, open, focus, move, resize, desktops, permission, done

    static func < (a: TourStep, b: TourStep) -> Bool { a.rawValue < b.rawValue }

    /// The steps that are practised on the play desktop.
    var isLesson: Bool { self >= .open && self <= .desktops }
}

/// One key of the keys shown under a lesson.
struct KeyHint: Identifiable, Equatable {
    /// The key's config-file name (`h`, `minus`), or the whole shortcut when the keys of a lesson
    /// do not share their modifiers.
    let id: String
    let label: String
    /// An SF Symbol that says what the key does: an arrow, a number sign.
    var symbol: String?
    let command: Command
}

/// The keys of a lesson: the modifiers to hold, and the keys to press with them.
struct LessonKeys: Equatable {
    var modifiers: [Modifier] = []
    var keys: [KeyHint] = []
}

/// An outline on the play desktop that shows where a window is meant to end up.
struct TourGhost: Equatable {
    let desktop: Int
    let rect: CGRect
    let window: WindowID
}

/// A window of the play desktop, placed.
struct TourTile: Identifiable, Equatable {
    let id: WindowID
    let desktop: Int
    let rect: CGRect
    let color: Int
    let focused: Bool
}

/// The welcome tour: a small desktop to practise on, run by the same layout engine that arranges
/// real windows, and the goals that lead through it. It hears the real shortcuts, so what is
/// learned here is exactly what works afterwards.
final class TourModel: ObservableObject {
    enum Permission { case idle, waiting, granted }
    enum DesktopGoal { case jump, carry }

    /// The play desktop is laid out in these units and scaled to the screen by the view.
    static let stage = CGSize(width: 1600, height: 1000)
    static let windowsToOpen = 3
    static let desktopCount = 3
    static let focusTargets = 3

    @Published private(set) var step: TourStep = .hello
    @Published private(set) var revision = 0
    @Published private(set) var current = 0
    @Published private(set) var overview = false
    @Published private(set) var beacon: WindowID?
    @Published private(set) var desktopBeacon: Int?
    @Published private(set) var ghost: TourGhost?
    @Published private(set) var desktopGoal = DesktopGoal.jump
    @Published private(set) var lit: Set<String> = []
    @Published var held: Set<Modifier> = []
    @Published private(set) var reached = 0
    @Published private(set) var celebrations = 0
    @Published private(set) var refusals = 0
    @Published private(set) var permission = Permission.idle
    @Published private(set) var closing = false
    @Published private(set) var skipArmed = false
    @Published private(set) var muted = false
    @Published var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    private(set) var desktops: [Tree] = (0..<desktopCount).map { _ in Tree() }
    private(set) var colors: [WindowID: Int] = [:]
    let bindings: [KeyBinding]
    let resizeStep: Double

    // The world outside, replaceable in tests.
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var promptForTrust: () -> Void = {}
    var play: (TourSound.Cue) -> Void = { _ in }
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var setLoginItem: ((Bool) -> String?)?
    /// The tour steps aside for System Settings, or comes back in front of it.
    var onYield: (Bool) -> Void = { _ in }
    var onMute: (Bool) -> Void = { _ in }
    /// The tour is over. `completed` is false when it was left early.
    var onClose: (_ completed: Bool) -> Void = { _ in }

    private var nextID: WindowID = 1
    private var visits: [WindowID: Int] = [:]
    private var clock = 0
    private var advancing = false
    private var goalWindow: WindowID?
    private var goalDirection = Direction.left
    private var movesMade = 0
    private var growsNeeded = 3
    private var trustTimer: Timer?
    private var prompted = false

    init(config: Config) {
        bindings = config.bindings
        // Small steps are hard to see on a desktop this size.
        resizeStep = min(max(config.resizeStep, 0.04), 0.12)
    }

    deinit { trustTimer?.invalidate() }

    // MARK: The play desktop

    var gaps: (outer: CGFloat, inner: CGFloat) { overview ? (11, 9) : (20, 16) }

    /// Where a desktop sits on the stage. One fills it; in the overview all three stand in a row.
    func panel(_ index: Int) -> CGRect {
        let stage = Self.stage
        guard overview else {
            return CGRect(x: CGFloat(index - current) * (stage.width + 180), y: 0, width: stage.width, height: stage.height)
        }
        let spacing: CGFloat = 56
        let total: CGFloat = 2600
        let width = (total - spacing * CGFloat(Self.desktopCount - 1)) / CGFloat(Self.desktopCount)
        let height = width * stage.height / stage.width
        let left = (stage.width - total) / 2
        return CGRect(x: left + CGFloat(index) * (width + spacing), y: (stage.height - height) / 2, width: width, height: height)
    }

    private func frames(_ index: Int, tree: Tree? = nil) -> [WindowID: CGRect] {
        computeLayout(tree ?? desktops[index], in: panel(index).insetBy(dx: gaps.outer, dy: gaps.outer), gap: gaps.inner)
    }

    var tiles: [TourTile] {
        desktops.indices.flatMap { index -> [TourTile] in
            let placed = frames(index)
            let focused = desktops[index].focused
            return desktops[index].windows.compactMap { id in
                placed[id].map { TourTile(id: id, desktop: index, rect: $0, color: colors[id] ?? 0, focused: index == current && id == focused) }
            }
        }
    }

    var focusedWindow: WindowID? { desktops[current].focused }
    var windowCount: Int { desktops[0].windows.count }

    /// Add a window the way the window manager does: beside the focused one, splitting its slot
    /// along the longer side.
    private func adopt(_ id: WindowID, into index: Int, tree: Tree? = nil) {
        let tree = tree ?? desktops[index]
        let anchor = tree.focused.flatMap { tree.contains($0) ? $0 : nil } ?? tree.windows.last
        var split: Orientation?
        if let anchor, let frame = frames(index, tree: tree)[anchor] {
            split = frame.width >= frame.height ? .horizontal : .vertical
        }
        tree.insert(id, after: anchor, split: split)
        tree.focused = id
    }

    private func copy(_ tree: Tree) -> Tree {
        let twin = Tree(snapshot: tree.snapshot)
        twin.focused = tree.focused
        return twin
    }

    private func touch(_ id: WindowID?) {
        guard let id else { return }
        clock += 1
        visits[id] = clock
    }

    private func changed(_ body: () -> Void) {
        withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
            body()
            revision += 1
        }
    }

    // MARK: Keys

    private func binding(_ matches: (Command) -> Bool) -> KeyBinding? { bindings.first { matches($0.command) } }

    private static let arrows: [Direction: String] = [.left: "arrow.left", .down: "arrow.down", .up: "arrow.up", .right: "arrow.right"]

    private func keys(_ wanted: [(command: (Command) -> Bool, label: String?, symbol: String?)]) -> LessonKeys? {
        var found: [(KeyBinding, String?, String?)] = []
        for item in wanted {
            guard let b = binding(item.command) else { return nil }
            found.append((b, item.label, item.symbol))
        }
        guard let first = found.first else { return nil }
        let shared = found.allSatisfy { $0.0.combo.modifiers == first.0.combo.modifiers }
        let order: [Modifier] = [.ctrl, .option, .shift, .cmd]
        return LessonKeys(
            modifiers: shared ? order.filter { first.0.combo.modifiers.contains($0) } : [],
            keys: found.map { b, label, symbol in
                let name = ShortcutFormat.keys(b.combo).last ?? b.combo.key
                return KeyHint(id: shared ? b.combo.key : b.source, label: shared ? (label ?? name) : ShortcutFormat.display(b.combo),
                               symbol: symbol, command: b.command)
            })
    }

    private func directionKeys(_ make: @escaping (Direction) -> Command) -> LessonKeys? {
        // In the order the keys sit on the keyboard when they are H J K L.
        keys([Direction.left, .down, .up, .right].map { dir in
            (command: { $0 == make(dir) }, label: nil, symbol: Self.arrows[dir])
        })
    }

    private func numberKeys(_ matches: @escaping (Command, Int) -> Bool) -> LessonKeys? {
        keys((1...Self.desktopCount).map { n in (command: { matches($0, n) }, label: nil, symbol: nil) })
    }

    func keys(for step: TourStep) -> LessonKeys? {
        switch step {
        case .focus: return directionKeys { .focus($0) }
        case .move: return directionKeys { .move($0) }
        case .resize:
            return keys([
                (command: { if case .resize(_, let grow) = $0 { return grow < 0 }; return false }, label: nil, symbol: "arrow.down.right.and.arrow.up.left"),
                (command: { if case .resize(_, let grow) = $0 { return grow > 0 }; return false }, label: nil, symbol: "arrow.up.left.and.arrow.down.right"),
            ])
        case .desktops:
            switch desktopGoal {
            case .jump: return numberKeys { $0 == .space(.index($1)) }
            case .carry: return numberKeys { command, n in
                    if case .moveToSpace(.index(n), _) = command { return true }
                    return false
                }
            }
        default: return nil
        }
    }

    /// The key that takes the next step towards the goal, so that it can be pointed out.
    var suggested: Command? {
        switch step {
        case .focus:
            guard let beacon, let from = focusedWindow else { return nil }
            let placed = frames(current)
            guard let origin = placed[from], let target = placed[beacon] else { return nil }
            if let direct = Direction.allCases.first(where: { nearestWindow(from: origin, direction: $0, among: placed, excluding: from) == beacon }) {
                return .focus(direct)
            }
            let dx = target.midX - origin.midX, dy = target.midY - origin.midY
            return .focus(abs(dx) >= abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down))
        case .move:
            return goalWindow == focusedWindow ? .move(goalDirection) : nil
        case .resize:
            return goalWindow == focusedWindow ? keys(for: .resize)?.keys.last?.command : nil
        case .desktops:
            if let desktopBeacon { return desktopGoal == .jump ? .space(.index(desktopBeacon + 1)) : nil }
            if let ghost { return keys(for: .desktops)?.keys.dropFirst(ghost.desktop).first?.command }
            return nil
        default:
            return nil
        }
    }

    /// A key that has nothing to do here. There is no sound for it: a sound for "no" is what the
    /// system makes when something is wrong, and nothing is. The keys on screen give a small shake.
    private func refuse() {
        withAnimation(.linear(duration: 0.32)) { refusals += 1 }
    }

    private func flash(_ command: Command, binding: KeyBinding?) {
        let id: String
        if let hint = keys(for: step)?.keys.first(where: { $0.command == command }) {
            id = hint.id
        } else if let binding {
            id = binding.combo.key
        } else {
            return
        }
        lit.insert(id)
        after(0.22) { [weak self] in self?.lit.remove(id) }
    }

    // MARK: Steps

    private func isAvailable(_ step: TourStep) -> Bool {
        switch step {
        case .hello, .open, .done: return true
        case .focus, .move, .resize: return keys(for: step) != nil
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
            case .desktops:
                desktopGoal = .jump
                prepareDesktops()
            case .permission:
                permission = .idle
                watchTrust()
            default:
                break
            }
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
        adopt(id, into: 0)
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

    private func succeed(sound: Bool = true) {
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

    // MARK: Commands

    /// A command from a shortcut or the command line. Returns nil for the commands the tour
    /// leaves to the window manager.
    func handle(_ command: Command, binding: KeyBinding? = nil) -> String? {
        switch command {
        case .status, .reload, .quit, .listWindows, .listSpaces, .tree: return nil
        default: break
        }
        guard !closing else { return "ok: the tour is closing" }
        flash(command, binding: binding)

        switch command {
        case .focus(let dir) where step >= .focus && step.isLesson:
            focus(dir)
        case .move(let dir) where step >= .move && step.isLesson:
            move(dir)
        case .resize(let axis, let grow) where step >= .resize && step.isLesson:
            resize(axis, grow)
        case .space(let target) where step == .desktops:
            if let index = desktopIndex(target) { jump(to: index) }
        case .moveToSpace(let target, let follow) where step == .desktops:
            if let index = desktopIndex(target) { carry(to: index, follow: follow) }
        default:
            refuse()
        }
        return "ok: in the welcome tour"
    }

    private func focus(_ dir: Direction) {
        let tree = desktops[current]
        let placed = frames(current)
        guard let from = tree.focused, let origin = placed[from],
              let target = nearestWindow(from: origin, direction: dir, among: placed, excluding: from) else {
            refuse()
            return
        }
        changed { tree.focused = target }
        touch(target)
        let centre = (placed[target]?.midX ?? 0) - panel(current).minX
        play(.focus(Int(centre / panel(current).width * 6)))

        if step == .focus, target == beacon {
            reached += 1
            if reached >= Self.focusTargets {
                succeed()
            } else {
                play(.reached)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { pickBeacon() }
            }
        }
        refreshGoals()
    }

    /// Point at the window that has gone longest without the focus.
    private func pickBeacon() {
        let tree = desktops[current]
        beacon = tree.windows.filter { $0 != tree.focused }.min { (visits[$0] ?? 0) < (visits[$1] ?? 0) }
    }

    private func move(_ dir: Direction) {
        let tree = desktops[current]
        guard let id = tree.focused else {
            refuse()
            return
        }
        var moved = false
        changed { moved = tree.move(id, dir) }
        guard moved else {
            refuse()
            return
        }
        play(.move)
        if step == .move, id == goalWindow {
            movesMade += 1
            if !canMove(goalDirection) || movesMade >= 5 { succeed() }
        }
        refreshGoals()
    }

    private func canMove(_ dir: Direction) -> Bool {
        guard let id = goalWindow ?? focusedWindow else { return false }
        return copy(desktops[current]).move(id, dir)
    }

    private func resize(_ axis: Orientation?, _ grow: Int) {
        let tree = desktops[current]
        guard let id = tree.focused else {
            refuse()
            return
        }
        var resized = false
        changed { resized = tree.changeShare(of: id, along: axis, .delta(Double(grow) * resizeStep)) }
        guard resized else {
            refuse()
            return
        }
        play(.resize(grow: grow > 0))
        if step == .resize, id == goalWindow {
            growsNeeded -= grow
            if growsNeeded <= 0 { succeed() }
        }
        refreshGoals()
    }

    private func desktopIndex(_ target: SpaceTarget) -> Int? {
        switch target {
        case .index(let n): return (1...Self.desktopCount).contains(n) ? n - 1 : nil
        case .next: return current + 1 < Self.desktopCount ? current + 1 : nil
        case .prev: return current > 0 ? current - 1 : nil
        }
    }

    private func jump(to index: Int) {
        guard index != current else {
            refuse()
            return
        }
        changed { current = index }
        play(.desktop(index))
        // The next thing to learn needs a window to carry, so an empty desktop does not count yet.
        if desktopGoal == .jump, !desktops[index].isEmpty {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { desktopGoal = .carry }
        }
        refreshGoals()
    }

    private func carry(to index: Int, follow: Bool) {
        let tree = desktops[current]
        guard index != current, let id = tree.focused else {
            refuse()
            return
        }
        changed {
            tree.remove(id)
            tree.focused = tree.windows.last
            adopt(id, into: index)
            if follow { current = index }
        }
        touch(id)
        play(.carry)
        succeed()
    }

    /// The second desktop starts with a window of its own, so that there is something to see
    /// there and something to carry away.
    private func prepareDesktops() {
        guard desktops[1].isEmpty, desktops[2].isEmpty else { return }
        let id = nextID
        nextID += 1
        colors[id] = Int(id - 1)
        adopt(id, into: 1)
    }

    /// Work out what to point at, from where things are now. Goals are never stored as places:
    /// whatever the windows have been through, the outline shows the way from here.
    private func refreshGoals() {
        guard !advancing else { return }
        switch step {
        case .move:
            guard let id = goalWindow else { return }
            let twin = copy(desktops[current])
            var steps = 0
            while steps < 6, twin.move(id, goalDirection) { steps += 1 }
            ghost = steps > 0 ? frames(current, tree: twin)[id].map { TourGhost(desktop: current, rect: $0, window: id) } : nil
        case .resize:
            guard let id = goalWindow else { return }
            let twin = copy(desktops[current])
            for _ in 0..<max(growsNeeded, 0) { twin.changeShare(of: id, .delta(resizeStep)) }
            ghost = frames(current, tree: twin)[id].map { TourGhost(desktop: current, rect: $0, window: id) }
        case .desktops:
            switch desktopGoal {
            case .jump:
                let others = [1, 0, 2].filter { $0 != current && !desktops[$0].isEmpty }
                desktopBeacon = others.first
                ghost = nil
            case .carry:
                if let id = focusedWindow {
                    let others = desktops.indices.filter { $0 != current }
                    let target = others.first { desktops[$0].isEmpty } ?? others.last ?? 0
                    let twin = copy(desktops[target])
                    adopt(id, into: target, tree: twin)
                    ghost = frames(target, tree: twin)[id].map { TourGhost(desktop: target, rect: $0, window: id) }
                    desktopBeacon = nil
                } else {
                    // Nothing to carry from an empty desktop: point at one that has windows.
                    ghost = nil
                    desktopBeacon = desktops.indices.first { !desktops[$0].isEmpty }
                }
            }
        default:
            break
        }
    }

    // MARK: Permission

    private func watchTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkTrust() }
    }

    func checkTrust() {
        guard step == .permission, permission != .granted, isTrusted() else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { permission = .granted }
        play(.granted)
        onYield(false)
        after(1.6) { [weak self] in
            guard let self, self.step == .permission else { return }
            self.advance()
        }
    }

    func requestPermission() {
        guard permission != .granted else { return }
        // System Settings has to be able to come in front of the tour.
        onYield(true)
        withAnimation(.easeOut(duration: 0.3)) { permission = .waiting }
        if prompted {
            openAccessibilitySettings()
        } else {
            prompted = true
            promptForTrust()
        }
    }

    func openAccessibilitySettings() {
        onYield(true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Leaving

    func setLaunchAtLogin(_ value: Bool) {
        launchAtLoginError = setLoginItem?(value)
        launchAtLogin = launchAtLoginError == nil ? value : !value
    }

    func toggleMute() {
        muted.toggle()
        onMute(muted)
    }

    func skipStep() {
        guard step.isLesson else { return }
        advance()
    }

    /// Escape. The first press asks, the second leaves; the permission is still asked for on the
    /// way out, because nothing works without it.
    func escape() {
        guard !closing else { return }
        guard skipArmed else {
            skipArmed = true
            after(2.6) { [weak self] in self?.skipArmed = false }
            return
        }
        skipArmed = false
        if step < .permission, isAvailable(.permission) {
            go(to: .permission)
        } else {
            close(completed: step == .done)
        }
    }

    func finish() {
        guard !closing else { return }
        play(.finale)
        close(completed: true)
    }

    private func close(completed: Bool) {
        trustTimer?.invalidate()
        trustTimer = nil
        withAnimation(.timingCurve(0.7, 0, 0.25, 1, duration: 0.85)) { closing = true }
        after(0.9) { [weak self] in self?.onClose(completed) }
    }
}

extension TourModel {
    /// A tour stopped at one of its scenes, for looking at it without playing it through.
    static func preview(_ step: TourStep, config: Config = .default, variant: Int = 0) -> TourModel {
        let model = TourModel(config: config)
        model.isTrusted = { false }
        model.after = { _, _ in }
        switch step {
        case .hello:
            break
        case .open:
            model.go(to: .open)
            for _ in 0..<variant { model.primary() }
        case .permission:
            model.go(to: .permission)
            if variant == 1 { model.permission = .waiting }
            if variant == 2 { model.permission = .granted }
        case .desktops:
            model.go(to: .desktops)
            if variant == 1 { _ = model.handle(.space(.index(2))) }
        default:
            model.go(to: step)
        }
        return model
    }
}
