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
        alt-h = ""
        alt-1 = ""
        """
        let (config, _) = try Config.load(text)
        let model = makeModel(config)
        XCTAssertEqual(model.lessons, [.open, .move, .resize])
        reachLessons(model)
        XCTAssertEqual(model.step, .move)
    }

    func testShortcutsOfTheUsersOwnAreTheOnesShown() throws {
        let text = """
        [bindings]
        alt-h = ""
        alt-j = ""
        alt-k = ""
        alt-l = ""
        ctrl-alt-left = "focus left"
        ctrl-alt-down = "focus down"
        ctrl-alt-up = "focus up"
        ctrl-alt-right = "focus right"
        """
        let (config, _) = try Config.load(text)
        let model = makeModel(config)
        let keys = try XCTUnwrap(model.keys(for: .focus))
        XCTAssertEqual(keys.modifiers, [.ctrl, .alt])
        XCTAssertEqual(keys.keys.map(\.label), ["←", "↓", "↑", "→"])
    }
}
