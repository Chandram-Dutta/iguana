import CoreGraphics
import XCTest
@testable import IguanaCore

final class TreeTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func frames(_ t: Tree, visible: Set<WindowID>? = nil, gap: CGFloat = 0, mins: [WindowID: CGSize] = [:]) -> [WindowID: CGRect] {
        computeLayout(t, in: screen, gap: gap, visible: visible, minSizes: mins)
    }

    func testFlatInsertSharesTheRowEqually() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1)
        t.insert(3, after: 1)
        XCTAssertEqual(t.windows, [1, 3, 2])
        let f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 333, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 333, y: 0, width: 334, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 667, y: 0, width: 333, height: 600))
    }

    func testDwindleSplitsTheFocusedWindow() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)
        let f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    func testSplitOfLoneWindowTurnsTheRoot() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .vertical)
        XCTAssertEqual(t.root.orientation, .vertical)
        XCTAssertEqual(frames(t)[2], CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    func testRemoveCollapsesContainers() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)
        t.remove(3)
        XCTAssertEqual(t.root.children.count, 2)
        XCTAssertTrue(t.root.children.allSatisfy { $0.windowID != nil })
        XCTAssertEqual(frames(t)[2], CGRect(x: 500, y: 0, width: 500, height: 600))
        t.remove(1)
        t.remove(2)
        XCTAssertTrue(t.isEmpty)
        XCTAssertTrue(frames(t).isEmpty)
    }

    func testMoveSwapsWithNeighbourWindow() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.move(1, .right))
        XCTAssertEqual(t.windows, [2, 1, 3])
        XCTAssertTrue(t.move(1, .right))
        XCTAssertEqual(t.windows, [2, 3, 1])
        XCTAssertFalse(t.move(1, .right), "already at the right edge")
    }

    func testMovePerpendicularWrapsTheRoot() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.move(2, .down))
        XCTAssertEqual(t.root.orientation, .vertical)
        let f = frames(t)
        XCTAssertEqual(f[2], CGRect(x: 0, y: 300, width: 1000, height: 300))
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 300))
    }

    func testMoveIntoAndOutOfAContainer() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)   // 1 | (2 / 3)
        XCTAssertTrue(t.move(1, .right))           // 1 joins the stack
        XCTAssertEqual(t.root.orientation, .vertical)
        XCTAssertEqual(Set(t.windows), [1, 2, 3])
        XCTAssertEqual(frames(t)[1]?.width, 1000)

        XCTAssertTrue(t.move(1, .left))            // 1 leaves the stack to the left
        let f = frames(t)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2]?.minX, 500)
        XCTAssertEqual(f[3]?.minX, 500)
    }

    func testMoveOutOfNestedContainerLandsBesideIt() {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)   // 1 | (2 / 3)
        XCTAssertTrue(t.move(3, .left))            // 1 | 3 | 2
        XCTAssertEqual(t.windows, [1, 3, 2])
        XCTAssertEqual(t.root.children.count, 3)
    }

    func testMoveSkipsHiddenWindows() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.move(1, .right, visible: [1, 3]))
        XCTAssertEqual(t.windows, [3, 2, 1])
        XCTAssertFalse(t.move(1, .right, visible: [1, 3]))
    }

    func testLoneVisibleWindowDoesNotMove() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        XCTAssertFalse(t.move(1, .down, visible: [1]))
        XCTAssertFalse(t.move(1, .right, visible: [1]))
    }

    func testJoinStacksTwoWindows() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.join(1, with: .right))
        let f = frames(t)
        XCTAssertEqual(f[2], CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[1], CGRect(x: 0, y: 300, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertFalse(t.join(3, with: .right))
    }

    func testFlipTurnsTheContainer() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        XCTAssertTrue(t.flip(1))
        XCTAssertEqual(frames(t)[2], CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    func testSwap() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        XCTAssertTrue(t.swap(1, 3))
        XCTAssertEqual(t.windows, [3, 2, 1])
        XCTAssertFalse(t.swap(1, 9))
    }

    func testChangeShareByDeltaAndRatio() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        XCTAssertTrue(t.changeShare(of: 1, .delta(0.1)))
        XCTAssertEqual(frames(t)[1]!.width, 600, accuracy: 1)
        XCTAssertTrue(t.changeShare(of: 1, .ratio(0.5)))
        XCTAssertEqual(frames(t)[1]!.width, 300, accuracy: 1)
        t.balance()
        XCTAssertEqual(frames(t)[1]!.width, 500, accuracy: 1)
        XCTAssertFalse(t.changeShare(of: 1, along: .vertical, .delta(0.1)), "nothing to resize against vertically")
    }

    func testShareIsClamped() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        for _ in 0..<40 { t.changeShare(of: 1, .delta(0.1)) }
        let w = frames(t)[2]!.width
        XCTAssertGreaterThan(w, 50)
        XCTAssertLessThan(w, 120)
    }

    func testHiddenWindowsKeepTheirSlotButTakeNoSpace() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        let f = frames(t, visible: [1, 3])
        XCTAssertNil(f[2])
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(frames(t)[2]?.minX, 333, "the slot is still there when it comes back")
    }

    func testSameSlotInsertReplacesOnScreen() {
        let t = Tree()
        [1, 2].forEach { t.insert($0) }
        t.changeShare(of: 1, .delta(0.2))
        let before = frames(t)[1]
        t.insert(7, after: 1, sameSlot: true)          // window 7 is a tab that replaced window 1
        XCTAssertEqual(frames(t, visible: [7, 2])[7], before)
        XCTAssertEqual(frames(t, visible: [1, 2])[1], before)
    }

    func testGapsAndMinimumSizes() {
        let t = Tree()
        [1, 2, 3].forEach { t.insert($0) }
        let f = frames(t, gap: 10)
        XCTAssertEqual(f[1]!.maxX + 10, f[2]!.minX)
        XCTAssertEqual(f[2]!.maxX + 10, f[3]!.minX)
        XCTAssertEqual(f[3]!.maxX, 1000)

        let m = frames(t, mins: [1: CGSize(width: 600, height: 0)])
        XCTAssertEqual(m[1]!.width, 600)
        XCTAssertEqual(m[3]!.width, 200)
        XCTAssertEqual(m[2]!.width, 200)
    }

    func testMinimumSizesThatDoNotFitAreScaled() {
        XCTAssertEqual(distribute(total: 100, weights: [1, 1], mins: [80, 80]), [50, 50])
        XCTAssertEqual(distribute(total: 100, weights: [1, 3], mins: [0, 0]), [25, 75])
    }

    func testSnapshotRoundTrip() throws {
        let t = Tree()
        t.insert(1)
        t.insert(2, after: 1, split: .horizontal)
        t.insert(3, after: 2, split: .vertical)
        t.changeShare(of: 1, .delta(0.1))
        let data = try JSONEncoder().encode(t.snapshot)
        let back = Tree(snapshot: try JSONDecoder().decode(NodeSnapshot.self, from: data))
        XCTAssertEqual(frames(back), frames(t))
        back.prune { $0 != 3 }
        XCTAssertEqual(back.windows, [1, 2])
    }

    func testSnapshotWithDuplicateIdsIsRepaired() {
        let dup = NodeSnapshot(window: nil, orientation: .horizontal, weight: 1, children: [
            NodeSnapshot(window: 1, orientation: nil, weight: 1, children: nil),
            NodeSnapshot(window: 1, orientation: nil, weight: 1, children: nil),
        ])
        XCTAssertEqual(Tree(snapshot: dup).windows, [1])
    }

    func testRandomOperationsKeepTheTreeConsistent() {
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let t = Tree()
        var alive = Set<WindowID>()
        var nextID: WindowID = 1
        for _ in 0..<3000 {
            let ids = alive.sorted()
            let pick = ids.isEmpty ? nil : ids[next(ids.count)]
            let dir = Direction.allCases[next(4)]
            switch next(8) {
            case 0, 1:
                t.insert(nextID, after: pick, split: [nil, .horizontal, .vertical][next(3)])
                alive.insert(nextID)
                nextID += 1
            case 2:
                if let pick, alive.count > 1 {
                    t.remove(pick)
                    alive.remove(pick)
                }
            case 3: if let pick { t.move(pick, dir) }
            case 4: if let pick { t.join(pick, with: dir) }
            case 5: if let pick { t.flip(pick) }
            case 6: if let pick { t.changeShare(of: pick, .delta(Double(next(5) - 2) * 0.05)) }
            default: if let pick, let other = ids.last { t.swap(pick, other) }
            }
            XCTAssertEqual(Set(t.windows), alive)
            XCTAssertEqual(t.windows.count, alive.count, "no window appears twice")
            assertCanonical(t.root, isRoot: true)
            let f = frames(t)
            XCTAssertEqual(f.count, alive.count)
            let area = f.values.reduce(0) { $0 + $1.width * $1.height }
            if !alive.isEmpty { XCTAssertEqual(area, screen.width * screen.height, accuracy: 1, "windows cover the screen exactly") }
        }
    }

    func assertCanonical(_ n: Node, isRoot: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard let o = n.orientation else { return }
        if !isRoot { XCTAssertGreaterThan(n.children.count, 1, "container with fewer than two children", file: file, line: line) }
        for c in n.children {
            XCTAssertTrue(c.parent === n, file: file, line: line)
            XCTAssertNotEqual(c.orientation, o, "nested container splits the same way as its parent", file: file, line: line)
            XCTAssertGreaterThan(c.weight, 0, file: file, line: line)
            assertCanonical(c, isRoot: false, file: file, line: line)
        }
    }
}

final class FocusTests: XCTestCase {
    func testNearestPrefersOverlapThenDistance() {
        let frames: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 500, height: 600),
            2: CGRect(x: 500, y: 0, width: 500, height: 300),
            3: CGRect(x: 500, y: 300, width: 500, height: 300),
        ]
        XCTAssertEqual(nearestWindow(from: frames[1]!, direction: .right, among: frames, excluding: 1), 2)
        XCTAssertEqual(nearestWindow(from: frames[3]!, direction: .left, among: frames, excluding: 3), 1)
        XCTAssertEqual(nearestWindow(from: frames[2]!, direction: .down, among: frames, excluding: 2), 3)
        XCTAssertNil(nearestWindow(from: frames[1]!, direction: .left, among: frames, excluding: 1))
        XCTAssertNil(nearestWindow(from: frames[2]!, direction: .up, among: frames, excluding: 2))
    }
}

final class ConfigTests: XCTestCase {
    func testTOMLBasics() throws {
        let doc = try TOML.parse("""
        # comment
        name = "a \\"b\\""   # trailing
        n = 1_000
        f = -0.5
        on = true
        list = [1, 2,
                3]
        point = { x = 1, y = 2 }
        a.b = 'lit'

        [t.sub]
        "quoted key" = 1

        [[item]]
        v = 1
        [[item]]
        v = 2
        """)
        XCTAssertEqual(doc["name"], .string("a \"b\""))
        XCTAssertEqual(doc["n"], .int(1000))
        XCTAssertEqual(doc["f"], .double(-0.5))
        XCTAssertEqual(doc["on"], .bool(true))
        XCTAssertEqual(doc["list"], .array([.int(1), .int(2), .int(3)]))
        XCTAssertEqual(doc["point"], .table(["x": .int(1), "y": .int(2)]))
        XCTAssertEqual(doc["a"], .table(["b": .string("lit")]))
        XCTAssertEqual(doc["t"], .table(["sub": .table(["quoted key": .int(1)])]))
        XCTAssertEqual(doc["item"], .array([.table(["v": .int(1)]), .table(["v": .int(2)])]))
    }

    func testTOMLErrorsCarryTheLine() {
        XCTAssertThrowsError(try TOML.parse("a = 1\nb = oops\n")) { e in
            XCTAssertEqual((e as? TOMLError)?.line, 2)
        }
        XCTAssertThrowsError(try TOML.parse("a = \"open\n"))
        XCTAssertThrowsError(try TOML.parse("a = 1 2\n"))
        XCTAssertThrowsError(try TOML.parse("a = 1\n[a]\n"))
        XCTAssertEqual(try TOML.parse("a = 1\r\nb = 2\r\n"), ["a": .int(1), "b": .int(2)], "Windows line endings")
    }

    func testOptionIsTheNameOfTheKeyAndTheOldSpellingIsStillRead() throws {
        let option = try KeyCombo.parse("option-shift-h")
        XCTAssertEqual(option.modifiers, [.option, .shift])
        XCTAssertEqual(try KeyCombo.parse("opt-shift-h"), option)
        XCTAssertEqual(try KeyCombo.parse("alt-shift-h"), option, "configs written for other window managers keep working")
        // The built-in shortcuts are written with the name Iguana uses.
        XCTAssertFalse(Config.defaultText.contains("alt-"))
        XCTAssertTrue(Config.default.bindings.allSatisfy { $0.source.hasPrefix("option-") })
    }

    func testMenuBarDesktopsIsOffUntilAskedFor() throws {
        XCTAssertEqual(Config.default.menuBarDesktops, .current)
        let (all, none) = try Config.load("[menu-bar]\ndesktops = \"all\"\n")
        XCTAssertEqual(all.menuBarDesktops, .all)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(try Config.load("[menu-bar]\ndesktops = \"occupied\"\n").0.menuBarDesktops, .occupied)

        let (kept, warnings) = try Config.load("[menu-bar]\ndesktops = \"some\"\nicons = true\n")
        XCTAssertEqual(kept.menuBarDesktops, .current)
        XCTAssertEqual(warnings.count, 2, "one for the value, one for the unknown key")

        // A click on a drawn desktop only switches when that is asked for as well.
        XCTAssertFalse(Config.default.menuBarClickSwitches)
        XCTAssertFalse(all.menuBarClickSwitches)
        XCTAssertTrue(try Config.load("[menu-bar]\ndesktops = \"all\"\nclick-to-switch = true\n").0.menuBarClickSwitches)
    }

    func testDefaultConfigLoadsCleanly() throws {
        let (c, warnings) = try Config.load(Config.defaultText)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.gapInner, 8)
        XCTAssertEqual(c.stripReserve, .auto)
        XCTAssertEqual(c.bindings.count, 36)
        XCTAssertEqual(c.rules.count, 3)
        XCTAssertTrue(c.bindings.contains { $0.source == "option-shift-3" && $0.command == .moveToSpace(.index(3), follow: true) })
        XCTAssertEqual(Config.default, c)
    }

    func testConfigOverridesAndWarnings() throws {
        let (c, warnings) = try Config.load("""
        [gaps]
        inner = 0
        outer = { top = 20 }
        bogus = 1
        [layout]
        auto-split = "yes"
        [stage-manager]
        reserve-strip = false
        [bindings]
        cmd-option-left = "focus left"
        option-q = "explode"
        hyper-x = "zoom"
        """)
        XCTAssertEqual(c.gapInner, 0)
        XCTAssertEqual(c.gapOuter.top, 20)
        XCTAssertEqual(c.gapOuter.left, 8)
        XCTAssertTrue(c.autoSplit)
        XCTAssertEqual(c.stripReserve, .off)
        XCTAssertEqual(c.bindings.count, 37, "the file's shortcut is added to the 36 built-in ones")
        XCTAssertTrue(c.bindings.contains { $0.source == "cmd-option-left" && $0.commandText == "focus left" })
        XCTAssertEqual(warnings.count, 4)
    }

    func testFileSettingsLayerOverTheDefaults() throws {
        let (c, warnings) = try Config.load("""
        [bindings]
        option-h = "focus right"    # replaces a built-in shortcut
        option-l = ""               # switches one off
        option-j = false            # also switches one off
        ctrl-option-z = "zoom"      # adds one

        [animation]
        enabled = false
        duration = 0.3
        easing = "linear"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.bindings.first { $0.source == "option-h" }?.command, .focus(.right))
        XCTAssertFalse(c.bindings.contains { $0.source == "option-l" || $0.source == "option-j" })
        XCTAssertTrue(c.bindings.contains { $0.source == "option-k" }, "untouched shortcuts stay")
        XCTAssertEqual(c.bindings.count, 36 - 2 + 1)
        XCTAssertEqual(c.rules, Config.default.rules, "no [[rule]] in the file keeps the built-in rules")
        XCTAssertFalse(c.animate)
        XCTAssertEqual(c.animationDuration, 0.3)
        XCTAssertEqual(c.animationEasing, .linear)

        let (withRules, _) = try Config.load("[[rule]]\napp = \"Preview\"\n")
        XCTAssertEqual(withRules.rules.map(\.app), ["Preview"], "a file with rules lists all of them")

        let (bad, problems) = try Config.load("[animation]\nduration = 9\neasing = \"bouncy\"\n")
        XCTAssertEqual(bad.animationDuration, Config.default.animationDuration)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(try Config.load("").config, Config.default, "an empty file is the defaults")
    }

    func testEasingAndInterpolation() {
        for e in Easing.allCases {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-9)
            XCTAssertEqual(e.apply(-3), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(7), 1, accuracy: 1e-9)
            var last = 0.0
            for i in 1...20 {
                let v = e.apply(Double(i) / 20)
                XCTAssertGreaterThanOrEqual(v, last, "\(e) never goes backwards")
                last = v
            }
        }
        XCTAssertGreaterThan(Easing.easeOut.apply(0.5), 0.5)
        let a = CGRect(x: 0, y: 0, width: 100, height: 100), b = CGRect(x: 100, y: 50, width: 300, height: 200)
        XCTAssertEqual(interpolate(a, b, 0), a)
        XCTAssertEqual(interpolate(a, b, 1), b)
        XCTAssertEqual(interpolate(a, b, 0.5), CGRect(x: 50, y: 25, width: 200, height: 150))
    }

    func testSchemaIsValidJSONAndCoversEveryKey() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let doc = try TOML.parse(Config.defaultText)
        XCTAssertEqual(Set(properties.keys), Set(doc.keys), "every top-level section of the default config is in the schema")
        for (section, value) in doc {
            guard section != "bindings", let table = value.tableValue else { continue }
            let described = try XCTUnwrap((properties[section] as? [String: Any])?["properties"] as? [String: Any], section)
            XCTAssertEqual(Set(described.keys), Set(table.keys), "keys of [\(section)]")
        }
        // The shortcut pattern accepts every built-in shortcut.
        let bindings = try XCTUnwrap(properties["bindings"] as? [String: Any])
        let pattern = try XCTUnwrap((bindings["patternProperties"] as? [String: Any])?.keys.first)
        let regex = try NSRegularExpression(pattern: pattern)
        for b in Config.default.bindings {
            XCTAssertNotNil(regex.firstMatch(in: b.source, range: NSRange(b.source.startIndex..., in: b.source)), b.source)
        }
    }

    func testRules() {
        let byID = Rule(app: "com.apple.calculator", title: nil, float: true)
        XCTAssertTrue(byID.matches(bundleID: "com.apple.calculator", appName: "Calculator", title: ""))
        XCTAssertFalse(byID.matches(bundleID: "com.apple.Safari", appName: "Safari", title: ""))
        let byTitle = Rule(app: "safari", title: "^Settings", float: true)
        XCTAssertTrue(byTitle.matches(bundleID: "com.apple.Safari", appName: "Safari", title: "Settings — General"))
        XCTAssertFalse(byTitle.matches(bundleID: "com.apple.Safari", appName: "Safari", title: "Apple"))
    }

    func testCommands() throws {
        XCTAssertEqual(try Command.parse("focus left"), .focus(.left))
        XCTAssertEqual(try Command.parse("  Move   DOWN "), .move(.down))
        XCTAssertEqual(try Command.parse("resize grow"), .resize(axis: nil, grow: 1))
        XCTAssertEqual(try Command.parse("resize height shrink"), .resize(axis: .vertical, grow: -1))
        XCTAssertEqual(try Command.parse("space prev"), .space(.prev))
        XCTAssertEqual(try Command.parse("move-to-space 4"), .moveToSpace(.index(4), follow: true))
        XCTAssertEqual(try Command.parse("move-to-space next --stay"), .moveToSpace(.next, follow: false))
        XCTAssertEqual(try Command.parse("move-to-space --stay 2"), .moveToSpace(.index(2), follow: false))
        XCTAssertEqual(try Command.parse("move-to-space 2 --follow"), .moveToSpace(.index(2), follow: true))
        XCTAssertThrowsError(try Command.parse("space 2 --stay"))
        XCTAssertThrowsError(try Command.parse("move-to-space --stay"))
        XCTAssertThrowsError(try Command.parse("move-to-space 2 --stay --follow"))
        for bad in ["", "focus", "focus north", "space 0", "space 99", "resize", "zoom now", "nope"] {
            XCTAssertThrowsError(try Command.parse(bad), bad)
        }
    }

    func testKeyCombos() throws {
        XCTAssertEqual(try KeyCombo.parse("option-shift-h"), KeyCombo(modifiers: [.option, .shift], key: "h"))
        XCTAssertEqual(try KeyCombo.parse("Cmd-Option-Left"), KeyCombo(modifiers: [.cmd, .option], key: "left"))
        XCTAssertEqual(try KeyCombo.parse("option--"), KeyCombo(modifiers: [.option], key: "minus"))
        XCTAssertThrowsError(try KeyCombo.parse("h"))
        XCTAssertThrowsError(try KeyCombo.parse("option-"))
        XCTAssertThrowsError(try KeyCombo.parse("meta-h"))
    }
}

final class TOMLEditorTests: XCTestCase {
    func testASettingWrittenAsItsOwnSectionIsReplacedNotDoubled() throws {
        let text = """
        [gaps]
        inner = 8

        # each edge by itself
        [gaps.outer]
        top = 4
        left = 6
        bottom = 4
        right = 6

        [layout]
        auto-split = true
        """
        // One number for all four edges: the section must go, or the file defines outer twice.
        var uniform = TOMLEditor(text)
        uniform.set(["gaps", "outer"], to: .int(12))
        XCTAssertFalse(uniform.text.contains("[gaps.outer]"))
        var (config, warnings) = try Config.load(uniform.text)
        XCTAssertEqual(config.gapOuter, Edges(all: 12))
        XCTAssertEqual(config.gapInner, 8)
        XCTAssertTrue(config.autoSplit)
        XCTAssertTrue(warnings.isEmpty)

        // Each edge again, now as an inline table: the old section must not win.
        var edges = TOMLEditor(text)
        edges.set(["gaps", "outer"], to: .table(["top": .int(1), "left": .int(2), "bottom": .int(3), "right": .int(4)]))
        (config, warnings) = try Config.load(edges.text)
        XCTAssertEqual(config.gapOuter.top, 1)
        XCTAssertEqual(config.gapOuter.right, 4)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(edges.text.contains("[layout]"), "the sections after it are untouched")
    }

    let original = """
    # my settings
    top = 1

    [gaps]
    inner = 8      # between windows
    outer = { top = 8, left = 8 }

    [bindings]
    option-h = "focus left"
    "option-shift-h" = "move left"   # quoted key

    # floating apps
    [[rule]]
    app = "Calculator"
    float = true

    [[rule]]
    app = "Music"
    """

    func parsed(_ e: TOMLEditor) throws -> [String: TOMLValue] { try TOML.parse(e.text) }

    func testChangingAValueKeepsEverythingElse() throws {
        var e = TOMLEditor(original)
        e.set(["gaps", "inner"], to: .int(12))
        XCTAssertTrue(e.text.contains("inner = 12      # between windows"), "the trailing comment and spacing survive")
        XCTAssertEqual(e.text.replacingOccurrences(of: "inner = 12", with: "inner = 8"), original, "nothing else changed")
        e.set(["bindings", "option-shift-h"], to: .string("move right"))
        XCTAssertTrue(e.text.contains("\"option-shift-h\" = \"move right\"   # quoted key"))
        e.set(["gaps", "outer"], to: .int(4))
        XCTAssertEqual(try parsed(e)["gaps"], .table(["inner": .int(12), "outer": .int(4)]))
    }

    func testAddingKeysAndTables() throws {
        var e = TOMLEditor(original)
        e.set(["gaps", "extra"], to: .bool(true))
        e.set(["bindings", "option-l"], to: .string("focus right"))
        e.set(["animation", "duration"], to: .double(0.25))
        e.set(["animation", "enabled"], to: .bool(false))
        e.set(["other"], to: .string("x"))
        let doc = try parsed(e)
        XCTAssertEqual(doc["gaps"]?.tableValue?["extra"], .bool(true))
        XCTAssertEqual(doc["bindings"]?.tableValue?.count, 3)
        XCTAssertEqual(doc["animation"], .table(["duration": .double(0.25), "enabled": .bool(false)]))
        XCTAssertEqual(doc["other"], .string("x"))
        XCTAssertEqual(doc["top"], .int(1))
        XCTAssertEqual(doc["rule"]?.arrayValue?.count, 2, "rules untouched")
        XCTAssertTrue(e.text.contains("# floating apps"))
        let lines = e.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.firstIndex(of: "extra = true"), lines.firstIndex { $0.hasPrefix("outer") }! + 1, "new key goes to the end of its table")
    }

    func testRemove() throws {
        var e = TOMLEditor(original)
        XCTAssertTrue(e.remove(["bindings", "option-h"]))
        XCTAssertFalse(e.remove(["bindings", "option-h"]))
        XCTAssertFalse(e.remove(["nope", "x"]))
        XCTAssertEqual(try parsed(e)["bindings"]?.tableValue?.keys.sorted(), ["option-shift-h"])
    }

    func testMultiLineValuesAndHashesInStrings() throws {
        var e = TOMLEditor("""
        list = [
          1,   # one
          2,
        ]
        title = "a # b"  # real comment
        after = true
        """)
        e.set(["title"], to: .string("c # d"))
        XCTAssertTrue(e.text.contains("title = \"c # d\"  # real comment"))
        e.set(["list"], to: .array([.int(9)]))
        XCTAssertEqual(try parsed(e), ["list": .array([.int(9)]), "title": .string("c # d"), "after": .bool(true)])
        XCTAssertTrue(e.remove(["title"]))
        XCTAssertEqual(try parsed(e).keys.sorted(), ["after", "list"])
    }

    func testReplacingRules() throws {
        var e = TOMLEditor(original)
        e.replaceArrayOfTables("rule", with: [[("app", .string("Preview")), ("title", .string("^Info")), ("float", .bool(true))]])
        let doc = try parsed(e)
        XCTAssertEqual(doc["rule"], .array([.table(["app": .string("Preview"), "title": .string("^Info"), "float": .bool(true)])]))
        XCTAssertTrue(e.text.contains("# floating apps"), "the comment above the rules stays")
        XCTAssertEqual(doc["bindings"]?.tableValue?.count, 2)
        e.replaceArrayOfTables("rule", with: [])
        XCTAssertNil(try parsed(e)["rule"])
        e.replaceArrayOfTables("rule", with: [[("app", .string("A"))], [("app", .string("B"))]])
        XCTAssertEqual(try parsed(e)["rule"]?.arrayValue?.count, 2)
    }

    func testEditingAnEmptyFileAndTheDefaultConfig() throws {
        var empty = TOMLEditor("")
        empty.set(["gaps", "inner"], to: .int(3))
        XCTAssertEqual(try parsed(empty), ["gaps": .table(["inner": .int(3)])])

        var e = TOMLEditor(Config.defaultText)
        e.set(["gaps", "inner"], to: .int(20))
        e.set(["animation", "duration"], to: .double(0.4))
        e.set(["bindings", "option-h"], to: .string(""))
        e.set(["stage-manager", "reserve-strip"], to: .bool(false))
        let (c, warnings) = try Config.load(e.text)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.gapInner, 20)
        XCTAssertEqual(c.animationDuration, 0.4)
        XCTAssertEqual(c.stripReserve, .off)
        XCTAssertFalse(c.bindings.contains { $0.source == "option-h" })
        XCTAssertEqual(e.text.components(separatedBy: "\n").count, Config.defaultText.components(separatedBy: "\n").count, "no lines added or lost")
    }

    func testFormatting() {
        XCTAssertEqual(TOMLEditor.format(.double(0.05)), "0.05")
        XCTAssertEqual(TOMLEditor.format(.double(2)), "2.0")
        XCTAssertEqual(TOMLEditor.format(.string("a\"b\\")), "\"a\\\"b\\\\\"")
        XCTAssertEqual(TOMLEditor.formatKey("option-shift-h"), "option-shift-h")
        XCTAssertEqual(TOMLEditor.formatKey("has space"), "\"has space\"")
    }
}
