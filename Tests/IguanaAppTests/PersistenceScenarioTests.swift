import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// A test whose windows are known by the name of their app and their title, as the reports
/// and the saved layouts know them.
class NamedWindowsTestCase: ScenarioTestCase {
    /// Open a window of the app with this name, starting the app if it is not running, and
    /// let the window manager place it.
    @discardableResult
    func open(_ app: String, _ title: String, frame: CGRect? = nil, on space: FakeSpace? = nil) -> FakeWindow {
        let running = mac.system.apps.first { $0.localizedName == app } ?? mac.system.launch(app)
        let window = mac.system.open(running, title: title, frame: frame, on: space)
        mac.settle()
        return window
    }

    /// A window that is left alone because of what it is: it opens as a dialog.
    @discardableResult
    func openDialog(_ app: String, _ title: String, frame: CGRect) -> FakeWindow {
        let running = mac.system.apps.first { $0.localizedName == app } ?? mac.system.launch(app)
        let window = mac.system.open(running, title: title, frame: frame)
        window.subrole = kAXDialogSubrole
        mac.settle()
        return window
    }

    /// Somewhere on the second display of `addStudio()`.
    let onStudio = CGRect(x: 1700, y: 300, width: 600, height: 400)

    /// A second display to the right of the first, with two desktops of its own. Mission
    /// Control counts them on from the first display's: they are desktops 2 and 3.
    @discardableResult
    func addStudio() -> FakeDisplay {
        let studio = mac.system.addDisplay("Studio Display", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), desktops: 2)
        mac.settle()
        return studio
    }

    /// The key of a desktop's layout: the key of its Space, then its display. Without a Space,
    /// the one the display is showing.
    func key(_ space: FakeSpace? = nil, on display: FakeDisplay? = nil) -> String {
        let display = display ?? mac.system.displayList[0]
        return "\((space ?? display.currentSpace).uuid)|\(display.uuid)"
    }
}

/// A test that looks at the file of saved layouts, or has Iguana or the Mac start again.
class SavedLayoutTestCase: NamedWindowsTestCase {
    /// What is in the file of saved layouts right now. Nil when there is no file.
    var saved: SavedState? { StateStore(url: mac.stateURL, bootTime: { 0 }).load() }

    /// The windows of a desktop's layout in the file, in the order of the layout.
    func savedLayout(_ key: String? = nil) -> [CGWindowID]? {
        saved?.trees[key ?? self.key()].map { Tree(snapshot: $0).windows }
    }

    /// What the file says a window is.
    func savedDescription(of window: FakeWindow) -> WindowDescriptor? {
        saved?.windows?["\(window.id)"]
    }

    /// The Mac restarts. Iguana saves as it quits, every app quits and takes its windows
    /// along, and Iguana starts again before any app has a window. An app that is opened
    /// afterwards is a new process, and its windows have new ids.
    ///
    /// `Scenario.relaunch()` saves once more for the Iguana that has gone, and would do so
    /// under the new boot time, which makes the file look like one from this boot. So that
    /// Iguana is marked as no longer running, and what it wrote as it quit is what is found.
    func restartMac(after seconds: Double = 3600) {
        mac.save()
        mac.wm.started = false
        for app in mac.system.apps { mac.system.quit(app) }
        mac.bootTime += seconds
        mac.relaunch()
    }

    /// Start Iguana again on a file that some other run left, in place of what this one would
    /// write as it quits.
    func relaunch(finding state: SavedState) {
        mac.wm.started = false
        StateStore(url: mac.stateURL, bootTime: { 0 }).save(state)
        mac.relaunch()
    }
}

/// What is written to the file of saved layouts, and Iguana starting again on the same boot:
/// the windows have kept their ids, so everything is as it was left.
final class PersistenceScenarioTests: SavedLayoutTestCase {
    // MARK: Saving

    func testNothingIsWrittenBeforeTilingStarts() {
        replaceScenario(Scenario(start: false))
        mac.system.open(mac.system.launch("Notes"), title: "Todo")
        mac.settle()
        mac.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac.stateURL.path), "quitting before tiling started writes no file")

        // What an earlier run kept is still there afterwards.
        let tree = Tree()
        tree.insert(41)
        StateStore(url: mac.stateURL, bootTime: { 0 }).save(SavedState(boot: mac.bootTime, trees: ["space-uuid-1|display-1": tree.snapshot], floating: [44]))
        mac.save()
        XCTAssertEqual(savedLayout("space-uuid-1|display-1"), [41])
        XCTAssertEqual(saved?.floating, [44])
    }

    func testASaveFollowsAChangeAfterOneSecondOfQuiet() {
        XCTAssertEqual(saved?.trees, [:], "tiling has started, and there is nothing to lay out yet")
        let app = mac.system.launch("Terminal")
        mac.settle()

        let window = mac.system.open(app, title: "zsh")
        mac.scheduler.advance(by: 0.9)
        XCTAssertFrame(window.rect, mac.usable(), "the window has its tile")
        XCTAssertEqual(saved?.trees, [:], "and the file is not written yet")

        mac.scheduler.advance(by: 0.2)
        XCTAssertEqual(savedLayout(), [window.id], "a second after the change it is")

        // Quitting does not wait for the second to pass.
        let second = mac.system.open(app, title: "vim")
        mac.scheduler.advance(by: 0.1)
        XCTAssertEqual(savedLayout(), [window.id])
        mac.save()
        XCTAssertEqual(savedLayout(), [window.id, second.id])
    }

    func testOnlyTheLastOfARunOfChangesIsWritten() {
        let app = mac.system.launch("Terminal")
        mac.settle()

        let one = mac.system.open(app, title: "One")
        mac.scheduler.advance(by: 0.6)
        let two = mac.system.open(app, title: "Two")
        mac.scheduler.advance(by: 0.6)
        XCTAssertEqual(mac.tiles.count, 2)
        XCTAssertEqual(saved?.trees, [:], "more than a second after the first window opened, nothing is written: the second one came in between")

        mac.scheduler.advance(by: 0.3)
        XCTAssertEqual(saved?.trees, [:], "still within a second of the last change")

        mac.scheduler.advance(by: 0.2)
        XCTAssertEqual(savedLayout(), [one.id, two.id], "one write, with both")
    }

    func testTheFileHoldsTheLayoutOfEveryDesktopAndWhatEachWindowIs() throws {
        let display = mac.system.displayList[0]
        let second = mac.system.addDesktop(to: display)
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        mac.system.show(second, on: display)
        mac.settle()
        let zsh = open("Terminal", "zsh")

        let file = try XCTUnwrap(saved)
        XCTAssertEqual(file.boot, mac.bootTime, "when this Mac started")
        XCTAssertEqual(file.trees.keys.sorted(), ["space-uuid-1|display-1", "space-uuid-2|display-1"], "a layout for each desktop, by Space and display")
        XCTAssertEqual(savedLayout("space-uuid-1|display-1"), [docs.id, todo.id])
        XCTAssertEqual(savedLayout("space-uuid-2|display-1"), [zsh.id])
        XCTAssertEqual(file.trees["space-uuid-1|display-1"]?.orientation, .horizontal, "side by side")
        XCTAssertEqual(file.floating, [])
        XCTAssertEqual(file.minSizes, [:])

        // A description for every window in a layout: the app, the title and the tile.
        XCTAssertEqual(file.windows?.keys.sorted(), ["\(docs.id)", "\(todo.id)", "\(zsh.id)"])
        XCTAssertEqual(savedDescription(of: docs), WindowDescriptor(bundleID: "com.example.safari", app: "Safari", title: "Docs",
                                                                    frame: CGRect(x: 8, y: 33, width: 708, height: 859)))
        XCTAssertEqual(savedDescription(of: todo), WindowDescriptor(bundleID: "com.example.notes", app: "Notes", title: "Todo",
                                                                    frame: CGRect(x: 724, y: 33, width: 708, height: 859)))
        XCTAssertEqual(savedDescription(of: zsh), WindowDescriptor(bundleID: "com.example.terminal", app: "Terminal", title: "zsh",
                                                                   frame: mac.usable()))
    }

    func testAHandFloatedWindowAndALearnedMinimumSizeAreInTheFile() throws {
        let wide = open("Xcode", "Project")
        wide.minSize = CGSize(width: 900, height: 300)
        let notes = open("Notes", "Todo")
        let player = open("Music", "Player")
        XCTAssertEqual(mac.run("float"), "ok: floating")

        let file = try XCTUnwrap(saved)
        XCTAssertEqual(file.floating, [player.id], "the window floated by hand")
        XCTAssertEqual(savedLayout(), [wide.id, notes.id], "which is in no layout")
        XCTAssertEqual(file.minSizes, ["\(wide.id)": [900, 0]], "the width the window would not go under; its height was never in the way")
        XCTAssertEqual(file.windows?.keys.sorted(), ["\(wide.id)", "\(notes.id)", "\(player.id)"].sorted(), "the floating window is described too")
        XCTAssertEqual(savedDescription(of: player)?.bundleID, "com.example.music")
        XCTAssertEqual(savedDescription(of: player)?.title, "Player")

        // A window that closes takes everything about it out of the file.
        mac.system.close(player)
        mac.system.close(wide)
        mac.settle()
        XCTAssertEqual(saved?.floating, [])
        XCTAssertEqual(saved?.minSizes, [:])
        XCTAssertEqual(saved?.windows?.keys.sorted(), ["\(notes.id)"])
        mac.system.close(notes)
        mac.settle()
        XCTAssertEqual(saved?.trees, [:], "an empty desktop has no layout to keep")
        XCTAssertEqual(saved?.windows, [:])
    }

    func testAWindowThatIsNotOnScreenKeepsItsLastDescription() {
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let tile = CGRect(x: 8, y: 33, width: 708, height: 859)
        XCTAssertEqual(savedDescription(of: docs)?.frame, tile)

        mac.system.minimise(docs)
        mac.settle()
        docs.title = "Release notes"
        mac.save()
        XCTAssertEqual(savedLayout(), [docs.id, todo.id], "a minimised window keeps its place in the layout")
        XCTAssertEqual(savedDescription(of: docs), WindowDescriptor(bundleID: "com.example.safari", app: "Safari", title: "Docs", frame: tile),
                       "as it was when it was last on screen: its app is not asked")
        XCTAssertEqual(savedDescription(of: todo)?.frame, mac.usable(), "the window on screen is described as it is now")

        mac.system.unminimise(docs)
        mac.settle()
        XCTAssertEqual(savedDescription(of: docs)?.title, "Release notes", "back on screen, it is looked at again")
    }

    // MARK: Iguana starts again on the same boot

    func testAHandMadeArrangementComesBackExactlyWhenIguanaStartsAgain() {
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        let mail = open("Mail", "Inbox")
        // By hand: the newest window goes to the far left, is made wider, and the two windows
        // on the right become a stack.
        XCTAssertEqual(mac.run("move left"), "ok")
        XCTAssertEqual(mac.run("move left"), "ok")
        XCTAssertEqual(mac.run("move left"), "ok")
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        XCTAssertEqual(mac.run("stack --window \(zsh.id)"), "ok: stacked")
        let windows = [docs, todo, zsh, mail]
        let tiles = mac.tiles, frames = windows.map(\.rect), tree = mac.run("tree")
        XCTAssertEqual(tiles.count, 4)
        XCTAssertTrue(tree.contains("stack"), tree)
        XCTAssertEqual(mac.tiledInReadingOrder.first, mail.id)
        XCTAssertGreaterThan(mail.rect.width, 500, "wider than a third of the desktop")

        mac.mover.clearRecord()
        mac.relaunch()

        XCTAssertEqual(mac.tiles, tiles, "every window has the tile it had")
        XCTAssertEqual(windows.map(\.rect), frames)
        XCTAssertEqual(mac.run("tree"), tree, "the same shape, the same shares, the same stack")
        XCTAssertEqual(mac.mover.moves, [], "no window was moved to get there")
    }

    func testAHandFloatedWindowFloatsAgainWhenIguanaStartsAgain() {
        let docs = open("Safari", "Docs")
        let player = open("Music", "Player")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        player.rect = CGRect(x: 900, y: 500, width: 420, height: 300)
        mac.settle()
        XCTAssertFrame(docs.rect, mac.usable())

        mac.relaunch()

        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id], "the floating window was given no tile")
        XCTAssertEqual(player.rect, CGRect(x: 900, y: 500, width: 420, height: 300), "it is where the user left it")
        XCTAssertFrame(docs.rect, mac.usable())
        XCTAssertTrue(mac.run("list-windows").contains("\(player.id)\tfloating\tMusic\tPlayer"))
        XCTAssertEqual(saved?.floating, [player.id], "and it is still in the file for the next time")

        // Tiling it by hand is remembered just the same.
        XCTAssertEqual(mac.run("float --window \(player.id)"), "ok: tiled")
        mac.relaunch()
        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id, player.id])
    }

    func testARememberedMinimumSizeIsUsedAndCheckedOnceWhenIguanaStartsAgain() {
        let wide = open("Xcode", "Project")
        wide.minSize = CGSize(width: 900, height: 300)
        let notes = open("Notes", "Todo")
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1, "learned: it does not get as narrow as half the desktop")
        let frames = [wide.rect, notes.rect]
        let asked = wide.sizesAsked.count

        mac.mover.clearRecord()
        mac.relaunch()

        XCTAssertEqual([wide.rect, notes.rect], frames)
        XCTAssertEqual(mac.mover.moves, [], "the layout was right at once: the other window was not sent to a half it could not have")
        // The minimum was something seen in the last run. The window is asked once whether it still holds.
        XCTAssertEqual(wide.sizesAsked.count, asked + 1)
        XCTAssertEqual(wide.sizesAsked.last?.width ?? 0, 708, accuracy: 1, "asked for the half it would have without a minimum")

        // Once checked, it is believed: later layouts do not ask again.
        let third = open("Terminal", "zsh")
        mac.system.close(third)
        mac.settle()
        XCTAssertEqual(wide.sizesAsked.count, asked + 1)
        XCTAssertEqual([wide.rect, notes.rect], frames)
    }

    func testARememberedMinimumSizeThatNoLongerHoldsIsForgotten() {
        let wide = open("Xcode", "Project")
        wide.minSize = CGSize(width: 900, height: 300)
        let notes = open("Notes", "Todo")
        XCTAssertEqual(wide.rect.width, 900, accuracy: 1)
        XCTAssertEqual(saved?.minSizes, ["\(wide.id)": [900, 0]])

        // The app has changed its mind while Iguana was not running.
        mac.save()
        wide.minSize = .zero
        mac.relaunch()

        XCTAssertFrame(wide.rect, CGRect(x: 8, y: 33, width: 708, height: 859), "it takes its half now")
        XCTAssertFrame(notes.rect, CGRect(x: 724, y: 33, width: 708, height: 859))
        XCTAssertEqual(saved?.minSizes, [:], "and the minimum is gone from the file")
    }

    func testTheLayoutOfADesktopThatIsNotBeingShownSurvives() {
        let display = mac.system.displayList[0]
        mac.system.addDesktop(to: display)
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        XCTAssertEqual(mac.run("move left"), "ok")
        XCTAssertEqual(mac.run("resize grow width"), "ok")
        let tiles = mac.tiles, frames = [docs.rect, todo.rect, zsh.rect]

        mac.system.showDesktop(2)
        mac.settle()
        let scan = open("Preview", "Scan")
        mac.relaunch()

        XCTAssertEqual(mac.tiles.keys.sorted(), [scan.id], "only the desktop being shown is laid out")
        XCTAssertEqual(mac.run("tree"), """
        Built-in Display, desktop 2
          horizontal  [weight 1.00]
            - Preview: Scan #\(scan.id)  [weight 1.00]
        1 other Space(s) have a remembered layout
        """)
        XCTAssertEqual(saved?.trees.count, 2, "both layouts are in the file again")

        mac.mover.clearRecord()
        mac.system.showDesktop(1)
        mac.settle()
        XCTAssertEqual(mac.tiles, tiles, "the first desktop is as it was arranged")
        XCTAssertEqual([docs.rect, todo.rect, zsh.rect], frames)
        XCTAssertEqual(mac.mover.moves, [], "nothing had to move")
    }

    func testAWindowThatClosedWhileIguanaWasNotRunningLeavesNoGap() {
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        mac.save()
        mac.system.close(todo)
        mac.relaunch()

        XCTAssertFrame(docs.rect, mac.usable(), "the window that is left has the whole desktop")
        XCTAssertEqual(savedLayout(), [docs.id])
        XCTAssertEqual(saved?.windows?.keys.sorted(), ["\(docs.id)"], "the window that is gone is no longer described")
    }

    func testAWindowTiledByHandAgainstARuleStaysTiledWhenIguanaStartsAgain() {
        replaceScenario(Scenario(config: "[[rule]]\napp = \"Calculator\"\nfloat = true\n"))
        let docs = open("Safari", "Docs")
        let sums = open("Calculator", "Sums")
        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id], "the rule floats the calculator")
        XCTAssertEqual(mac.run("float"), "ok: tiled")
        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id, sums.id], "the user's choice wins over the rule")

        mac.relaunch()

        XCTExpectFailure("only windows floated by hand are saved, so a window tiled by hand against a rule floats again") {
            XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id, sums.id])
        }
    }

    func testAHandFloatedWindowOfAnAppThatWasBusyStillFloatsTheRunAfter() {
        let docs = open("Safari", "Docs")
        let player = open("Music", "Player")
        XCTAssertEqual(mac.run("float"), "ok: floating")

        // Iguana starts again while Music is too busy to say what windows it has, and is quit
        // before Music answers.
        player.app.answers = false
        mac.relaunch()
        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id])
        player.app.answers = true
        mac.relaunch()

        XCTExpectFailure("a save writes only the floating windows looked at in this run, and drops the ones still waiting from the last") {
            XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id])
        }
    }
}
