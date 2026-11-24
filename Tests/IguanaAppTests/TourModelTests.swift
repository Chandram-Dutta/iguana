import IguanaCore
import XCTest
@testable import iguana

final class TourModelTests: XCTestCase {
    private var pending: [() -> Void] = []
    private var trusted = false
    private var prompts = 0
    private var cues: [TourSound.Cue] = []
    private var closed: Bool?

    override func setUp() {
        pending = []
        trusted = false
        prompts = 0
        cues = []
        closed = nil
    }

    private func makeModel(_ config: Config = .default) -> TourModel {
        let model = TourModel(config: config)
        model.isTrusted = { [unowned self] in self.trusted }
        model.promptForTrust = { [unowned self] in self.prompts += 1 }
        model.play = { [unowned self] in self.cues.append($0) }
        model.after = { [unowned self] _, work in self.pending.append(work) }
        model.onClose = { [unowned self] in self.closed = $0 }
        return model
    }

    /// Run everything the tour has put off until later.
    private func flush() {
        while !pending.isEmpty { pending.removeFirst()() }
    }

    /// Press whichever key the tour points at, until the lesson is over.
    private func follow(_ model: TourModel, through step: TourStep, file: StaticString = #filePath, line: UInt = #line) {
        var presses = 0
        while model.step == step, presses < 30 {
            guard let command = model.suggested else {
                XCTFail("\(step): the tour points at no key", file: file, line: line)
                return
            }
            XCTAssertNotNil(model.handle(command), file: file, line: line)
            flush()
            presses += 1
        }
        XCTAssertNotEqual(model.step, step, "\(step) did not end by following the keys it points at", file: file, line: line)
    }

    private func reachLessons(_ model: TourModel) {
        model.primary()
        for _ in 0..<TourModel.windowsToOpen { model.primary() }
        flush()
    }

    func testTheKeysTheTourPointsAtLeadThroughAllOfIt() {
        let model = makeModel()
        XCTAssertEqual(model.step, .hello)
        model.primary()
        XCTAssertEqual(model.step, .open)

        for _ in 0..<TourModel.windowsToOpen { model.primary() }
        XCTAssertEqual(model.windowCount, 3)
        model.primary()
        XCTAssertEqual(model.windowCount, 3, "a fourth window must not open")
        flush()
        XCTAssertEqual(model.step, .focus)
        // The windows were opened the way real ones are: the third splits the second.
        let tiles = model.tiles
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles[0].rect.height, tiles[1].rect.height + tiles[2].rect.height + model.gaps.inner, accuracy: 0.5)

        follow(model, through: .focus)
        XCTAssertEqual(model.step, .move)
        follow(model, through: .move)
        XCTAssertEqual(model.step, .resize)
        follow(model, through: .resize)
        XCTAssertEqual(model.step, .stack)
        follow(model, through: .stack)
        XCTAssertEqual(model.step, .desktops)
        XCTAssertTrue(model.overview)
        follow(model, through: .desktops)

        XCTAssertEqual(model.step, .permission)
        XCTAssertFalse(model.overview)
        model.primary()
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(model.permission, .waiting)
        model.checkTrust()
        XCTAssertEqual(model.permission, .waiting, "nothing is granted until the system says so")
        trusted = true
        model.checkTrust()
        XCTAssertEqual(model.permission, .granted)
        flush()

        XCTAssertEqual(model.step, .done)
        model.primary()
        XCTAssertTrue(model.closing)
        flush()
        XCTAssertEqual(closed, true)
        XCTAssertTrue(cues.contains(.finale))
    }

    func testTheOutlineShowsWhereTheWindowLands() {
        let model = makeModel()
        reachLessons(model)
        model.go(to: .move)
        let moving = model.ghost
        XCTAssertNotNil(moving)
        follow(model, through: .move)
        XCTAssertEqual(model.tiles.first { $0.id == moving?.window }?.rect, moving?.rect)

        XCTAssertEqual(model.step, .resize)
        let growing = model.ghost
        XCTAssertNotNil(growing)
        let before = model.tiles.first { $0.id == growing?.window }?.rect ?? .zero
        // Measure before the lesson hands over: the next one shows the desktops from further away.
        var presses = 0
        while model.ghost != nil, presses < 10, let command = model.suggested {
            _ = model.handle(command)
            presses += 1
        }
        let after = model.tiles.first { $0.id == growing?.window }?.rect ?? .zero
        flush()
        XCTAssertGreaterThan(after.width * after.height, before.width * before.height)
        XCTAssertEqual(after.width, growing?.rect.width ?? 0, accuracy: 0.5)
        XCTAssertEqual(after.height, growing?.rect.height ?? 0, accuracy: 0.5)

        XCTAssertEqual(model.step, .stack)
        let stacking = model.ghost
        XCTAssertNotNil(stacking)
        XCTAssertEqual(stacking?.window, model.focusedWindow)
        _ = model.handle(.stack)
        XCTAssertEqual(model.tiles.first { $0.id == stacking?.window }?.rect, stacking?.rect)
        XCTAssertNil(model.ghost, "a stack that is made needs no outline")
        follow(model, through: .stack)

        XCTAssertEqual(model.step, .desktops)
        XCTAssertEqual(model.desktopBeacon, 1)
        _ = model.handle(.space(.index(2)))
        XCTAssertEqual(model.current, 1)
        XCTAssertEqual(model.desktopGoal, .carry)
        let carried = model.ghost
        XCTAssertEqual(carried?.desktop, 2, "the outline waits on the empty desktop")
        _ = model.handle(.moveToSpace(.index(3), follow: true))
        XCTAssertEqual(model.current, 2)
        XCTAssertEqual(model.tiles.first { $0.id == carried?.window }?.rect, carried?.rect)
    }

    func testAnEmptyDesktopDoesNotEndTheJumpLesson() {
        let model = makeModel()
        reachLessons(model)
        model.go(to: .desktops)
        _ = model.handle(.space(.index(3)))
        XCTAssertEqual(model.current, 2)
        XCTAssertEqual(model.desktopGoal, .jump)
        XCTAssertEqual(model.desktopBeacon, 1)
        XCTAssertEqual(model.suggested, .space(.index(2)))
    }

    func testKeysDoNothingBeforeTheirLesson() {
        let model = makeModel()
        reachLessons(model)
        XCTAssertEqual(model.step, .focus)
        let before = model.tiles
        XCTAssertNotNil(model.handle(.move(.left)))
        XCTAssertNotNil(model.handle(.resize(axis: nil, grow: 1)))
        XCTAssertNotNil(model.handle(.stack))
        XCTAssertNotNil(model.handle(.moveToSpace(.index(2), follow: true)))
        XCTAssertEqual(model.tiles, before)
        XCTAssertEqual(model.current, 0)
        // Commands about the app itself are left to the window manager.
        XCTAssertNil(model.handle(.status))
        XCTAssertNil(model.handle(.quit))
    }

    func testAPermissionAlreadyGivenIsNotAskedFor() {
        trusted = true
        let model = makeModel()
        reachLessons(model)
        model.go(to: .desktops)
        follow(model, through: .desktops)
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(prompts, 0)
    }

    func testLeavingEarlyStillAsksForThePermission() {
        let model = makeModel()
        model.primary()
        model.escape()
        XCTAssertTrue(model.skipArmed)
        XCTAssertEqual(model.step, .open, "one press only asks")
        model.escape()
        XCTAssertEqual(model.step, .permission)
        flush()
        model.escape()
        model.escape()
        flush()
        XCTAssertEqual(closed, false)
    }

    func testALessonWithoutItsShortcutsIsLeftOut() throws {
        let text = """
        [bindings]
        option-h = ""
        option-1 = ""
        """
        let (config, _) = try Config.load(text)
        let model = makeModel(config)
        XCTAssertEqual(model.lessons, [.open, .move, .resize, .stack])
        reachLessons(model)
        XCTAssertEqual(model.step, .move)
    }

    func testShortcutsOfTheUsersOwnAreTheOnesShown() throws {
        let text = """
        [bindings]
        option-h = ""
        option-j = ""
        option-k = ""
        option-l = ""
        ctrl-option-left = "focus left"
        ctrl-option-down = "focus down"
        ctrl-option-up = "focus up"
        ctrl-option-right = "focus right"
        """
        let (config, _) = try Config.load(text)
        let model = makeModel(config)
        let keys = try XCTUnwrap(model.keys(for: .focus))
        XCTAssertEqual(keys.modifiers, [.ctrl, .option])
        XCTAssertEqual(keys.keys.map(\.label), ["←", "↓", "↑", "→"])
    }

    // MARK: Stacks

    /// The windows of the first desktop that lie over another one: the windows of a stack.
    private func stacked(_ model: TourModel) -> [TourTile] {
        let tiles = model.tiles.filter { $0.desktop == 0 }
        return tiles.filter { tile in
            tiles.contains { $0.id != tile.id && $0.rect.insetBy(dx: 1, dy: 1).intersects(tile.rect) }
        }
    }

    func testTheStackLessonFollowsResizeAndStartsFromACrowdedColumn() throws {
        let model = makeModel()
        reachLessons(model)
        model.go(to: .resize)
        let before = Set(model.tiles.map(\.id))
        follow(model, through: .resize)
        XCTAssertEqual(model.step, .stack)
        XCTAssertEqual(model.lessons, [.open, .focus, .move, .resize, .stack, .desktops])

        // One tile beside a column of three. The windows that were there are still there, and
        // the one that opened has the focus and is in the column.
        let tiles = model.tiles
        XCTAssertEqual(tiles.count, 4)
        XCTAssertTrue(before.isSubset(of: Set(tiles.map(\.id))))
        let focused = try XCTUnwrap(tiles.first { $0.focused })
        XCTAssertFalse(before.contains(focused.id))
        let column = tiles.filter { $0.rect.minX == focused.rect.minX }
        XCTAssertEqual(column.count, 3)
        XCTAssertEqual(tiles.filter { $0.rect.height > focused.rect.height * 2 }.count, 1)
        XCTAssertTrue(stacked(model).isEmpty)

        XCTAssertEqual(model.stackGoal, .press)
        XCTAssertEqual(model.suggested, .stack)
        XCTAssertEqual(model.deck?.modifiers, [.option])
        XCTAssertEqual(model.deck?.keys.map(\.label), ["S"])
    }

    func testTheColumnFormsOnTheSideOfTheWindowThatHadTheFocus() throws {
        let model = makeModel()
        reachLessons(model)
        follow(model, through: .focus)
        follow(model, through: .move)
        XCTAssertEqual(model.step, .resize)
        // The move lesson has taken this window to one side of the desktop.
        let held = try XCTUnwrap(model.focusedWindow)
        follow(model, through: .resize)
        XCTAssertEqual(model.step, .stack)
        let middle = TourModel.stage.width / 2
        let side = try XCTUnwrap(model.tiles.first { $0.id == held }).rect.midX < middle
        let tiles = model.tiles
        let column = tiles.filter { ($0.rect.midX < middle) == side }
        XCTAssertEqual(column.count, 3)
        XCTAssertTrue(column.contains { $0.focused })
        XCTAssertNotEqual(model.focusedWindow, held, "the window that opens takes the focus")
        XCTAssertEqual(column.sorted { $0.rect.minY < $1.rect.minY }.last?.id, model.focusedWindow)
        follow(model, through: .stack)
        XCTAssertEqual(model.step, .desktops)
    }

    func testTheStackShortcutMakesAStackAndAStepThroughItEndsTheLesson() throws {
        let model = makeModel()
        reachLessons(model)
        model.go(to: .stack)
        let front = try XCTUnwrap(model.focusedWindow)
        cues = []
        XCTAssertNotNil(model.handle(.stack))
        flush()
        XCTAssertEqual(cues, [.move])
        XCTAssertEqual(model.step, .stack, "the stack still has to be stepped through")
        XCTAssertEqual(model.stackGoal, .step)

        // The column is a stack as the window manager lays one out: the windows overlap, each
        // starts one strip after the one before it, and the focused one is in front.
        let pile = stacked(model).sorted { $0.rect.minY < $1.rect.minY }
        XCTAssertEqual(pile.count, 3)
        XCTAssertEqual(pile[1].rect.minY - pile[0].rect.minY, model.peek, accuracy: 0.5)
        XCTAssertEqual(pile[2].rect.minY - pile[1].rect.minY, model.peek, accuracy: 0.5)
        XCTAssertEqual(Set(pile.map(\.rect.height)).count, 1)
        XCTAssertEqual(pile.max { $0.layer < $1.layer }?.id, front)
        XCTAssertEqual(pile.map(\.id).last, front)
        // Nearer the front window is further forward, so no window is covered whole.
        XCTAssertGreaterThan(pile[1].layer, pile[0].layer)

        // The call is for a window behind, on the strip of it that shows.
        let calling = try XCTUnwrap(model.beacon)
        XCTAssertEqual(calling, pile[1].id)
        let spot = try XCTUnwrap(model.beaconSpot)
        XCTAssertTrue(pile[1].rect.contains(spot))
        XCTAssertFalse(pile[2].rect.contains(spot))
        XCTAssertEqual(model.suggested, .focus(.up))
        XCTAssertEqual(model.deck, model.keys(for: .focus))

        XCTAssertNotNil(model.handle(.focus(.up)))
        XCTAssertEqual(model.focusedWindow, calling)
        XCTAssertEqual(stacked(model).max { $0.layer < $1.layer }?.id, calling, "the window stepped to comes to the front")
        flush()
        XCTAssertEqual(model.step, .desktops)
        XCTAssertTrue(cues.contains(.success))
    }

    func testUnstackingBringsBackTheFirstHalfOfTheLesson() {
        let model = makeModel()
        reachLessons(model)
        model.go(to: .stack)
        let before = model.tiles
        _ = model.handle(.stack)
        _ = model.handle(.stack)
        flush()
        XCTAssertEqual(model.step, .stack)
        XCTAssertEqual(model.stackGoal, .press)
        XCTAssertEqual(model.tiles.map(\.rect), before.map(\.rect))
        XCTAssertNotNil(model.ghost)
        XCTAssertNil(model.beacon)
        XCTAssertEqual(model.suggested, .stack)
    }

    func testFromOutsideTheStackTheWayLeadsThroughItsFrontWindow() throws {
        let model = makeModel()
        reachLessons(model)
        model.go(to: .stack)
        let front = try XCTUnwrap(model.focusedWindow)
        _ = model.handle(.stack)
        // Off to the tile beside the stack: that is no step through it.
        _ = model.handle(.focus(.left))
        flush()
        XCTAssertNotEqual(model.focusedWindow, front)
        XCTAssertEqual(model.step, .stack)
        XCTAssertEqual(model.beacon, front)
        XCTAssertEqual(model.suggested, .focus(.right))
        follow(model, through: .stack)
        XCTAssertEqual(model.step, .desktops)
    }

    func testWithoutFocusKeysTheStackAloneEndsTheLesson() throws {
        let (config, _) = try Config.load("""
        [bindings]
        option-k = ""
        """)
        let model = makeModel(config)
        XCTAssertEqual(model.lessons, [.open, .move, .resize, .stack, .desktops])
        model.go(to: .stack)
        follow(model, through: .stack)
        XCTAssertEqual(model.step, .desktops)
        XCTAssertEqual(stacked(model).count, 3)
    }

    func testAVisitorWithoutTheStackShortcutSkipsTheLesson() throws {
        let (config, _) = try Config.load("""
        [bindings]
        option-s = ""
        """)
        let model = makeModel(config)
        XCTAssertEqual(model.lessons, [.open, .focus, .move, .resize, .desktops])
        XCTAssertNil(model.keys(for: .stack))
        reachLessons(model)
        model.go(to: .resize)
        follow(model, through: .resize)
        XCTAssertEqual(model.step, .desktops)
        XCTAssertEqual(model.tiles.filter { $0.desktop == 0 }.count, 3, "no window opens for a lesson that is left out")
    }

    func testAStackShortcutOfTheUsersOwnIsTheOneShown() throws {
        let (config, _) = try Config.load("""
        [bindings]
        option-s = ""
        ctrl-option-t = "stack"
        """)
        let model = makeModel(config)
        let keys = try XCTUnwrap(model.keys(for: .stack))
        XCTAssertEqual(keys.modifiers, [.ctrl, .option])
        XCTAssertEqual(keys.keys.map(\.label), ["T"])
        XCTAssertEqual(keys.keys.map(\.command), [.stack])
    }

    func testTheDesktopsLessonCarriesOnFromAStack() throws {
        trusted = true
        let model = makeModel()
        reachLessons(model)
        model.go(to: .stack)
        follow(model, through: .stack)
        XCTAssertEqual(model.step, .desktops)
        // Seen from further away the stack is still a stack, with a strip of each window.
        let pile = stacked(model).sorted { $0.rect.minY < $1.rect.minY }
        XCTAssertEqual(pile.count, 3)
        XCTAssertEqual(pile[1].rect.minY - pile[0].rect.minY, model.peek, accuracy: 0.5)

        // A window carried away leaves the stack, and the two that stay are still one.
        let carried = try XCTUnwrap(model.focusedWindow)
        XCTAssertNotNil(model.handle(.moveToSpace(.index(3), follow: false)))
        XCTAssertEqual(model.tiles.first { $0.id == carried }?.desktop, 2)
        XCTAssertEqual(stacked(model).count, 2)
        flush()
        XCTAssertEqual(model.step, .done)
    }
}
