import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// After a restart of the Mac every window comes back with a new id. For three minutes the
/// saved layouts wait for windows that look like theirs, and each takes its place as it appears.
final class RestoreScenarioTests: SavedLayoutTestCase {
    /// The lines of the log about a desktop getting windows back, oldest first.
    var restored: [String] { mac.logged("back in its saved layout") }

    /// Safari on the left, made wider by hand; Notes above Terminal on the right.
    @discardableResult
    func arrangeThree() -> (docs: CGRect, todo: CGRect, zsh: CGRect) {
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        XCTAssertEqual(mac.run("resize grow width --window \(docs.id)"), "ok")
        XCTAssertEqual(mac.run("resize grow width --window \(docs.id)"), "ok")
        XCTAssertEqual(mac.tiledInReadingOrder, [docs.id, todo.id, zsh.id])
        XCTAssertGreaterThan(docs.rect.width, 800)
        return (docs.rect, todo.rect, zsh.rect)
    }

    func testWindowsThatComeBackTakeTheirPlacesInTheSavedLayout() {
        let before = arrangeThree()
        restartMac()
        XCTAssertTrue(mac.tiles.isEmpty)
        XCTAssertEqual(mac.logged("restore:"), ["restore: the Mac has restarted; for 3 minutes, windows that come back take their places in 1 saved layout(s)"])

        // The apps reopen their windows in an order of their own, and wherever they like.
        let zsh = open("Terminal", "zsh", frame: CGRect(x: 100, y: 100, width: 500, height: 300))
        XCTAssertFrame(zsh.rect, mac.usable(), "alone so far, it has the desktop")
        XCTAssertEqual(restored, ["restore: desktop 1 has 1 window(s) back in its saved layout"])

        let todo = open("Notes", "Todo", frame: CGRect(x: 300, y: 200, width: 500, height: 300))
        XCTAssertEqual(todo.rect.minX, zsh.rect.minX, accuracy: 1, "above Terminal as before, where a new window would have opened beside it")
        XCTAssertEqual(todo.rect.maxY + 8, zsh.rect.minY, accuracy: 1)
        XCTAssertEqual(todo.rect.width, mac.usable().width, accuracy: 1, "the two share the desktop until Safari is back")

        let docs = open("Safari", "Docs", frame: CGRect(x: 600, y: 300, width: 500, height: 300))
        XCTAssertFrame(docs.rect, before.docs, "on the left, as wide as it was made")
        XCTAssertFrame(todo.rect, before.todo)
        XCTAssertFrame(zsh.rect, before.zsh)
        XCTAssertEqual(restored, [
            "restore: desktop 1 has 1 window(s) back in its saved layout",
            "restore: desktop 1 has 2 window(s) back in its saved layout",
            "restore: desktop 1 has 3 window(s) back in its saved layout, which is complete",
        ])

        // The layout is complete: the next window is a new window.
        let scan = open("Preview", "Scan")
        XCTAssertNotNil(mac.tiles[scan.id])
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(saved?.boot, mac.bootTime, "the file is of this boot now")
        XCTAssertEqual(savedLayout().map(Set.init), [docs.id, todo.id, zsh.id, scan.id], "with the windows under their new ids")
    }

    func testAWindowThatWasNotThereBeforeGoesInAsANewWindow() {
        let before = arrangeThree()
        restartMac()

        // Things the saved layout knows nothing about are open first, one of them in the Dock.
        let hidden = open("Preview", "Receipt")
        mac.system.minimise(hidden)
        mac.settle()
        let scan = open("Preview", "Scan")
        XCTAssertFrame(scan.rect, mac.usable())
        XCTAssertEqual(restored, [])

        let docs = open("Safari", "Docs")
        XCTAssertEqual(mac.tiles.keys.sorted(), [scan.id, docs.id], "both have a tile")
        XCTAssertEqual(docs.rect.minX, before.docs.minX, accuracy: 1)

        let zsh = open("Terminal", "zsh")
        let todo = open("Notes", "Todo")
        XCTAssertEqual(mac.tiles.count, 4, "the newcomer keeps a tile among the windows that came back")
        XCTAssertEqual(mac.tiledInReadingOrder.first, docs.id, "Safari is on the left again")
        XCTAssertLessThan(todo.rect.minY, zsh.rect.minY, "and Notes is above Terminal again")
        XCTAssertEqual(restored.last, "restore: desktop 1 has 3 window(s) back in its saved layout, which is complete")

        // The window in the Dock was kept a place for when it comes out.
        mac.system.unminimise(hidden)
        mac.settle()
        XCTAssertEqual(mac.tiles.count, 5)
        XCTAssertEqual(mac.tiledInReadingOrder.first, docs.id)
    }

    func testEachDesktopTakesItsOwnLayoutBackWhenItIsShown() {
        let display = mac.system.displayList[0]
        let second = mac.system.addDesktop(to: display)
        open("Safari", "Docs")
        open("Notes", "Todo")
        XCTAssertEqual(mac.run("move left"), "ok")
        mac.system.showDesktop(2)
        mac.settle()
        open("Terminal", "zsh")
        open("Mail", "Inbox")
        XCTAssertEqual(mac.run("move left"), "ok")
        mac.system.showDesktop(1)
        mac.settle()

        restartMac()
        XCTAssertEqual(mac.logged("restore:"), ["restore: the Mac has restarted; for 3 minutes, windows that come back take their places in 2 saved layout(s)"])

        // macOS reopens each window on the desktop it was on.
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh", on: second)
        let inbox = open("Mail", "Inbox", on: second)
        XCTAssertEqual(mac.tiledInReadingOrder, [todo.id, docs.id], "Notes on the left, where it was moved")
        XCTAssertEqual(restored.last, "restore: desktop 1 has 2 window(s) back in its saved layout, which is complete")

        mac.system.showDesktop(2)
        mac.settle()
        XCTAssertEqual(mac.tiledInReadingOrder, [inbox.id, zsh.id], "the second desktop has its own layout back, Mail on the left")
        XCTAssertEqual(restored.last, "restore: desktop 2 has 2 window(s) back in its saved layout, which is complete")
    }

    func testWithNothingSavedARestartRestoresNothing() {
        restartMac()
        XCTAssertEqual(mac.logged("restore:"), [], "nothing to wait for, nothing to say")

        // A file written before windows were described has nothing to know its windows by.
        let tree = Tree()
        tree.insert(41)
        tree.insert(42, after: 41, split: .vertical)
        relaunch(finding: SavedState(boot: 1, trees: [key(): tree.snapshot], floating: [41]))
        XCTAssertEqual(mac.logged("restore:"), [])

        let first = open("Terminal", "One")
        let second = open("Terminal", "Two")
        XCTAssertEqual(mac.tiledInReadingOrder, [first.id, second.id], "side by side, as new windows open")
        XCTAssertEqual(first.rect.minY, second.rect.minY)
    }

    // MARK: Windows floated by hand

    func testAHandFloatedWindowFloatsAgainAfterARestart() {
        open("Safari", "Docs")
        open("Music", "Player")
        open("Music", "Equaliser")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        restartMac()

        let place = CGRect(x: 700, y: 400, width: 420, height: 300)
        let equaliser = open("Music", "Equaliser", frame: place)
        XCTAssertEqual(equaliser.rect, place, "known by its title, and left where it opened")
        XCTAssertTrue(mac.tiles.isEmpty)

        let player = open("Music", "Player")
        let docs = open("Safari", "Docs")
        XCTAssertEqual(mac.tiles.keys.sorted(), [player.id, docs.id].sorted(), "the other window of the app is tiled as it was")
        XCTAssertEqual(equaliser.rect, place)
        XCTAssertEqual(saved?.floating, [equaliser.id], "floating by hand under its new id")
    }

    func testTheOnlyWindowOfAnAppFloatsAgainWhateverItsTitle() {
        open("Safari", "Docs")
        open("Music", "Now playing: one song")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        restartMac()

        let place = CGRect(x: 700, y: 400, width: 420, height: 300)
        let player = open("Music", "Now playing: another song", frame: place)
        let docs = open("Safari", "Docs")

        XCTAssertEqual(player.rect, place)
        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id])
        XCTAssertFrame(docs.rect, mac.usable())
    }

    func testAHandFloatedWindowIsKnownByTheTitleItHadWhenTheMacWentDown() {
        open("Safari", "Docs")
        let player = open("Safari", "Radio: one song")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        // The title changes while the window floats, long before the restart.
        player.title = "Radio: another song"
        mac.system.click(player)
        mac.settle()
        restartMac()

        // Safari reopens both windows at once.
        let safari = mac.system.launch("Safari")
        let docs = mac.system.open(safari, title: "Docs")
        let radio = mac.system.open(safari, title: "Radio: another song", frame: CGRect(x: 700, y: 400, width: 420, height: 300))
        mac.settle()

        XCTAssertNotNil(mac.tiles[docs.id])
        XCTAssertNil(mac.tiles[radio.id], "the window that floated is the one with this title")
    }

    func testTheTiledWindowOfAnAppIsNotTakenForItsFloatingOne() {
        open("Safari", "Docs")
        open("Music", "Player")
        open("Music", "Equaliser")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        restartMac()

        // This time the window that was tiled is the first of the two to come back.
        let place = CGRect(x: 700, y: 400, width: 420, height: 300)
        let player = open("Music", "Player")
        let equaliser = open("Music", "Equaliser", frame: place)

        XCTAssertNotNil(mac.tiles[player.id], "the window that was tiled is tiled")
        XCTAssertNil(mac.tiles[equaliser.id], "and the one that floated floats")
        XCTAssertEqual(equaliser.rect, place)
        XCTAssertEqual(saved?.floating, [equaliser.id])
    }

    func testAFloatingWindowWithANewTitleIsNotKnownAgainWhenItsAppHadMoreWindows() {
        open("Safari", "Docs")
        open("Music", "Player")
        open("Music", "Now playing: one song")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        restartMac()

        // The app's only window so far, under a title that was not saved. With two windows
        // saved it could be either of them, so it is not floated on a guess.
        let playing = open("Music", "Now playing: another song")
        XCTAssertNotNil(mac.tiles[playing.id])
        XCTAssertEqual(saved?.floating, [])
    }

    func testAWindowARuleFloatsIsNotTakenForTheFloatingOne() {
        replaceScenario(Scenario(config: "[[rule]]\napp = \"Music\"\ntitle = \"Mini\"\nfloat = true\n"))
        let docs = open("Safari", "Docs")
        open("Music", "Mini")
        open("Music", "Now playing: one song")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        XCTAssertEqual(mac.tiles.keys.sorted(), [docs.id])
        restartMac()

        // The window the rule floats was not saved: the rule is all that floats it. It comes
        // back first and alone, and leaves the saved window to the one that was floated by hand.
        let mini = open("Music", "Mini")
        XCTAssertEqual(saved?.floating, [], "floating by its rule, not by hand")
        let place = CGRect(x: 700, y: 400, width: 420, height: 300)
        let player = open("Music", "Now playing: another song", frame: place)
        XCTAssertEqual(saved?.floating, [player.id], "the only window of the app that no rule floats, as when it was saved")
        XCTAssertEqual(player.rect, place)
        XCTAssertTrue(mac.tiles.isEmpty)
        XCTAssertNil(mac.tiles[mini.id])
    }

    func testTheFloatingWindowIsKnownAmongWindowsARuleFloats() {
        replaceScenario(Scenario(config: "[[rule]]\napp = \"Music\"\ntitle = \"Mini\"\nfloat = true\n"))
        open("Safari", "Docs")
        open("Music", "Mini")
        open("Music", "Now playing: one song")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        restartMac()

        // Music reopens both windows at once. Only one of them is a window that was saved.
        let music = mac.system.launch("Music")
        mac.system.open(music, title: "Mini")
        let player = mac.system.open(music, title: "Now playing: another song")
        mac.settle()
        XCTAssertEqual(saved?.floating, [player.id])
        XCTAssertTrue(mac.tiles.isEmpty)
    }

    // MARK: Windows tiled by hand

    func testAWindowTiledByHandAgainstARuleIsTiledAgainAfterARestart() {
        replaceScenario(Scenario(config: "[[rule]]\napp = \"Calculator\"\nfloat = true\n"))
        open("Calculator", "Sums")
        XCTAssertEqual(mac.run("float"), "ok: tiled")
        open("Safari", "Docs")
        open("Calculator", "Tape")
        XCTAssertEqual(mac.tiles.count, 2, "the rule floats the calculator's other window")
        let before = mac.tiles.values.map(\.minX).sorted()
        restartMac()

        // The window the rule alone decides for comes back first. It is not the one that was tiled.
        let tape = open("Calculator", "Tape")
        XCTAssertTrue(mac.tiles.isEmpty)
        let docs = open("Safari", "Docs")
        let sums = open("Calculator", "Sums")
        XCTAssertEqual(mac.tiledInReadingOrder, [sums.id, docs.id], "known by its title, tiled again, and on the left as it was")
        XCTAssertEqual(mac.tiles.values.map(\.minX).sorted(), before)
        XCTAssertNil(mac.tiles[tape.id])
        XCTAssertEqual(saved?.tiled, [sums.id], "tiled by hand under its new id")
        XCTAssertEqual(restored.last, "restore: desktop 1 has 2 window(s) back in its saved layout, which is complete")
    }

    func testAWindowTiledByHandIsNotKnownAgainByAnotherTitle() {
        replaceScenario(Scenario(config: "[[rule]]\napp = \"Calculator\"\nfloat = true\n"))
        open("Calculator", "Sums")
        XCTAssertEqual(mac.run("float"), "ok: tiled")
        restartMac()

        // The calculator's only window, as before, but the rule floats others that were not
        // saved: without its title there is no telling that this is the one.
        let tape = open("Calculator", "Tape")
        XCTAssertNil(mac.tiles[tape.id], "left to the rule")
        XCTAssertEqual(saved?.tiled, [])
    }

    // MARK: The user takes over

    func testMovingAWindowStopsTheRestoreForItsDesktop() {
        let before = arrangeThree()
        restartMac()
        let zsh = open("Terminal", "zsh")
        let todo = open("Notes", "Todo")
        XCTAssertLessThan(todo.rect.minY, zsh.rect.minY, "Notes above Terminal, as saved")

        // The user arranges the desktop another way. What they did stands.
        XCTAssertEqual(mac.run("move down"), "ok")
        XCTAssertLessThan(zsh.rect.minY, todo.rect.minY)

        let docs = open("Safari", "Docs")
        XCTAssertEqual(restored.count, 2, "nothing more is restored here")
        XCTAssertNotEqual(docs.rect.minX, before.docs.minX, "Safari opens as a new window, beside the focused one, not on the left")
        XCTAssertEqual(docs.rect.minY, todo.rect.minY, accuracy: 1)
        XCTAssertLessThan(zsh.rect.minY, todo.rect.minY, "and the user's order is kept")
    }

    func testFloatingAWindowStopsTheRestoreForItsDesktop() {
        arrangeThree()
        restartMac()
        let zsh = open("Terminal", "zsh")
        XCTAssertEqual(mac.run("float"), "ok: floating")

        let todo = open("Notes", "Todo")
        let docs = open("Safari", "Docs")
        XCTAssertNil(mac.tiles[zsh.id])
        XCTAssertEqual(mac.tiledInReadingOrder, [todo.id, docs.id], "side by side in the order they opened, not Safari on the left")
        XCTAssertEqual(todo.rect.width, docs.rect.width, accuracy: 1, "and at even shares")
        XCTAssertEqual(restored.count, 1)
    }

    func testDroppingAWindowOnAnotherStopsTheRestoreForItsDesktop() {
        let before = arrangeThree()
        restartMac()
        let zsh = open("Terminal", "zsh")
        let todo = open("Notes", "Todo")
        XCTAssertLessThan(todo.rect.minY, zsh.rect.minY)

        // Terminal is dragged by its title bar onto the middle of Notes, and let go: they trade places.
        mac.system.drag(zsh, to: CGPoint(x: 8, y: 200))
        mac.settle()
        mac.system.releaseMouse()
        mac.settle()
        XCTAssertLessThan(zsh.rect.minY, todo.rect.minY, "Terminal is above Notes now")

        let docs = open("Safari", "Docs")
        XCTAssertEqual(restored.count, 2, "nothing more is restored here")
        XCTAssertNotEqual(docs.rect.minX, before.docs.minX, "Safari opens as a new window")
        XCTAssertLessThan(zsh.rect.minY, todo.rect.minY, "and what the user did stands")
    }

    func testNothingIsRestoredWhileAWindowIsBeingDragged() {
        arrangeThree()
        restartMac()
        let zsh = open("Terminal", "zsh")

        // The user has hold of Terminal when Notes comes back.
        mac.system.drag(zsh, to: CGPoint(x: -400, y: 60))
        mac.settle()
        let todo = open("Notes", "Todo")
        XCTAssertEqual(restored.count, 1, "the saved layout does not take the desktop over under the user's hand")
        XCTAssertEqual(todo.rect.minX, 724, accuracy: 1, "Notes has opened beside Terminal's tile, as any new window does")
        XCTAssertEqual(zsh.rect.origin, CGPoint(x: -400, y: 60), "and the window in the hand was left alone")

        // Let go over its own tile: nothing was rearranged by hand, so the restore goes on.
        mac.system.releaseMouse()
        mac.settle()
        XCTAssertEqual(restored.last, "restore: desktop 1 has 2 window(s) back in its saved layout")
        XCTAssertEqual(todo.rect.minX, zsh.rect.minX, accuracy: 1)
        XCTAssertLessThan(todo.rect.minY, zsh.rect.minY, "Notes above Terminal, as saved")
    }

    // MARK: The grace period

    func testWindowsThatComeBackAfterTheGracePeriodAreNewWindows() {
        arrangeThree()
        let player = open("Music", "Player")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        XCTAssertNil(mac.tiles[player.id])
        restartMac()

        // Two and a half minutes on, a window still takes its place.
        mac.scheduler.advance(by: 150)
        let zsh = open("Terminal", "zsh")
        XCTAssertEqual(restored, ["restore: desktop 1 has 1 window(s) back in its saved layout"])

        // Past three minutes the saved layouts are forgotten.
        mac.scheduler.advance(by: RestoreSession.gracePeriod - 150)
        let todo = open("Notes", "Todo")
        let docs = open("Safari", "Docs")
        let music = open("Music", "Player")
        XCTAssertEqual(restored.count, 1, "nothing more is restored")
        XCTAssertEqual(todo.rect.minY, zsh.rect.minY, accuracy: 1, "Notes opens beside Terminal, not above it")
        XCTAssertGreaterThan(docs.rect.minX, zsh.rect.maxX, "Safari is on the right, not on the left")
        XCTAssertNotNil(mac.tiles[music.id], "and the window that floated is tiled like any new window")
    }
}
