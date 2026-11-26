import CoreGraphics
import XCTest
@testable import IguanaCore

/// Layouts that survive a restart of the Mac: knowing windows again by their app, title and
/// place, building a saved layout with the windows that are back, floating windows again, and
/// how long all this goes on.
final class RestoreTests: XCTestCase {
    typealias Seen = [WindowID: WindowDescriptor]
    let left = CGRect(x: 0, y: 0, width: 500, height: 600)
    let right = CGRect(x: 500, y: 0, width: 500, height: 600)
    let start = Date(timeIntervalSince1970: 1_000_000)

    func window(_ app: String?, _ title: String?, _ frame: CGRect) -> WindowDescriptor {
        WindowDescriptor(bundleID: app, app: app.map { $0.components(separatedBy: ".").last! }, title: title, frame: frame)
    }

    func win(_ id: WindowID, _ weight: Double = 1) -> NodeSnapshot { NodeSnapshot(window: id, orientation: nil, weight: weight, children: nil) }
    func split(_ o: Orientation, _ weight: Double = 1, _ kids: NodeSnapshot...) -> NodeSnapshot {
        NodeSnapshot(window: nil, orientation: o, weight: weight, children: kids)
    }
    func stack(_ o: Orientation, _ weight: Double = 1, _ kids: NodeSnapshot...) -> NodeSnapshot {
        NodeSnapshot(window: nil, orientation: o, weight: weight, children: kids, stacked: true)
    }

    // MARK: Matching

    func testTheSameTitleWinsOverTheNearestPlace() {
        let saved: Seen = [10: window("com.apple.Safari", "Docs", left), 11: window("com.apple.Safari", "Mail", right)]
        let now: Seen = [1: window("com.apple.Safari", "Mail", left), 2: window("com.apple.Safari", "Docs", right)]
        XCTAssertEqual(Restore.match(now, to: saved), [1: 11, 2: 10], "the windows swapped places while the Mac was off")
    }

    func testWindowsWithTheSameTitleAreToldApartByPlace() {
        let saved: Seen = [10: window("com.apple.Terminal", "zsh", left), 11: window("com.apple.Terminal", "zsh", right)]
        let now: Seen = [1: window("com.apple.Terminal", "zsh", right.offsetBy(dx: 20, dy: 10)), 2: window("com.apple.Terminal", "zsh", left)]
        XCTAssertEqual(Restore.match(now, to: saved), [1: 11, 2: 10])
    }

    func testAChangedTitleFallsBackToPlace() {
        let saved: Seen = [10: window("com.apple.mail", "Inbox (3)", left), 11: window("com.apple.mail", "Drafts", right)]
        let now: Seen = [1: window("com.apple.mail", "Inbox (4)", left.offsetBy(dx: 30, dy: 0)), 2: window("com.apple.mail", nil, right)]
        XCTAssertEqual(Restore.match(now, to: saved), [1: 10, 2: 11])

        // A title match takes its saved window first, even from a window that is nearer to it.
        let saved2: Seen = [10: window("com.apple.mail", "Inbox", left), 11: window("com.apple.mail", "Drafts", right)]
        let now2: Seen = [1: window("com.apple.mail", "Loading…", left), 2: window("com.apple.mail", "Inbox", right)]
        XCTAssertEqual(Restore.match(now2, to: saved2), [2: 10, 1: 11])

        // An empty title is no title.
        let saved3: Seen = [10: window("com.apple.mail", "", left), 11: window("com.apple.mail", "", right)]
        let now3: Seen = [1: window("com.apple.mail", "", right), 2: window("com.apple.mail", "", left)]
        XCTAssertEqual(Restore.match(now3, to: saved3), [1: 11, 2: 10])
    }

    func testWindowsOfOtherAppsNeverMatch() {
        let saved: Seen = [10: window("com.apple.Safari", "Docs", left), 11: window(nil, "Docs", right)]
        let now: Seen = [1: window("com.apple.Notes", "Docs", left), 2: window(nil, "Docs", right), 3: window("com.apple.Safari", "Docs", right)]
        XCTAssertEqual(Restore.match(now, to: saved), [3: 10], "only a window of the same app, and only an app that has a bundle id")
        XCTAssertEqual(Restore.match([1: window("com.apple.Notes", "Docs", left)], to: saved), [:])
        XCTAssertEqual(Restore.match([:], to: saved), [:])
        XCTAssertEqual(Restore.match(now, to: [:]), [:])
    }

    func testMoreWindowsThanSavedOnes() {
        let saved: Seen = [10: window("com.apple.Safari", nil, left), 11: window("com.apple.Safari", nil, right)]
        let now: Seen = [1: window("com.apple.Safari", nil, CGRect(x: 250, y: 0, width: 500, height: 600)),
                   2: window("com.apple.Safari", nil, right), 3: window("com.apple.Safari", nil, left)]
        XCTAssertEqual(Restore.match(now, to: saved), [2: 11, 3: 10], "the window in between is new")
    }

    func testFewerWindowsThanSavedOnes() {
        let saved: Seen = [10: window("com.apple.Safari", nil, left), 11: window("com.apple.Safari", nil, right),
                     12: window("com.apple.Safari", "Docs", left)]
        XCTAssertEqual(Restore.match([1: window("com.apple.Safari", "News", right)], to: saved), [1: 11])
        XCTAssertEqual(Restore.match([1: window("com.apple.Safari", "Docs", right)], to: saved), [1: 12])
    }

    func testMatchingAlwaysComesOutTheSame() {
        // Every window is as far from every saved window: the lowest ids pair first.
        var saved: [WindowID: WindowDescriptor] = [:]
        var now: [WindowID: WindowDescriptor] = [:]
        for id in WindowID(10)...15 { saved[id] = window("com.apple.Terminal", "zsh", left) }
        for id in WindowID(1)...4 { now[id] = window("com.apple.Terminal", "zsh", left) }
        let expected: [WindowID: WindowID] = [1: 10, 2: 11, 3: 12, 4: 13]
        for _ in 0..<20 {
            XCTAssertEqual(Restore.match(now, to: saved), expected)
            // The same entries, put in in another order.
            let shuffledNow = Dictionary(uniqueKeysWithValues: now.shuffled().map { ($0.key, $0.value) })
            let shuffledSaved = Dictionary(uniqueKeysWithValues: saved.shuffled().map { ($0.key, $0.value) })
            XCTAssertEqual(Restore.match(shuffledNow, to: shuffledSaved), expected)
        }
    }

    // MARK: Building

    func testAllWindowsBackGiveTheSavedLayout() {
        let layout = split(.horizontal, 1, win(10, 2), stack(.vertical, 1, win(11), win(12)), split(.vertical, 0.5, win(13, 3), win(14)))
        let tree = Restore.tree(from: layout, matched: [1: 10, 2: 11, 3: 12, 4: 13, 5: 14])
        XCTAssertEqual(tree.snapshot, split(.horizontal, 1, win(1, 2), stack(.vertical, 1, win(2), win(3)), split(.vertical, 0.5, win(4, 3), win(5))),
                       "directions, shares and stacks as they were")
        XCTAssertEqual(tree.windows, [1, 2, 3, 4, 5])
    }

    func testSavedWindowsThatAreNotBackAreLeftOut() {
        let layout = split(.horizontal, 1, win(10, 2), stack(.vertical, 1, win(11), win(12)), split(.vertical, 1, win(13, 3), win(14)))
        let tree = Restore.tree(from: layout, matched: [1: 10, 2: 11, 4: 13])
        XCTAssertEqual(tree.snapshot, split(.horizontal, 1, win(1, 2), win(2), win(4)),
                       "a container with one window left is that window, with the container's share")
        let frames = computeLayout(tree, in: CGRect(x: 0, y: 0, width: 1000, height: 600), gap: 0)
        XCTAssertEqual(frames[1]?.width, 500)

        // A container left with one container in it that splits the same way as its parent
        // becomes part of the parent.
        let nested = split(.horizontal, 1, win(10), split(.vertical, 1, win(11), split(.horizontal, 1, win(12), win(13))))
        XCTAssertEqual(Restore.tree(from: nested, matched: [1: 10, 3: 12, 4: 13]).snapshot,
                       split(.horizontal, 1, win(1), win(3, 0.5), win(4, 0.5)))

        // A stack with a single window back is an ordinary tile again.
        let stacked = Restore.tree(from: stack(.horizontal, 1, win(10), win(11)), matched: [1: 11])
        XCTAssertEqual(stacked.snapshot, split(.horizontal, 1, win(1)))
        XCTAssertFalse(stacked.root.stacked)

        // A stack with two windows back stays a stack, here one that fills the desktop.
        let pair = Restore.tree(from: split(.horizontal, 1, win(9), stack(.vertical, 1, win(10), win(11), win(12))), matched: [1: 10, 2: 12])
        XCTAssertEqual(pair.snapshot, stack(.vertical, 1, win(1), win(2)))
    }

    func testNoWindowBackGivesAnEmptyLayout() {
        let layout = split(.vertical, 1, win(10), win(11))
        XCTAssertTrue(Restore.tree(from: layout, matched: [:]).isEmpty)
        XCTAssertTrue(Restore.tree(from: layout, matched: [1: 99]).isEmpty, "a saved window that is not in the layout places nothing")
        XCTAssertTrue(Restore.tree(from: win(10), matched: [1: 10]).isEmpty, "a layout is a container, never a single window")
    }

    // MARK: Floating

    func testAHandFloatedWindowFloatsAgain() {
        let saved = [window("com.apple.Notes", "Groceries", left), window("com.apple.Notes", "Ideas", right), window("com.apple.Music", nil, left)]
        // Notes had both its windows floating; Music had the one.
        let had = ["com.apple.Notes": 2, "com.apple.Music": 1]
        func floating(_ windows: Seen, _ appWindows: [String: Int]) -> [WindowID: Int] {
            Restore.floating(windows, appWindows: appWindows, savedAppWindows: had, saved: saved)
        }
        // The same app and title.
        XCTAssertEqual(floating([1: window("com.apple.Notes", "Ideas", left)], ["com.apple.Notes": 3]), [1: 1])
        // Another title, and the app has two saved floating windows: no way to tell.
        XCTAssertEqual(floating([1: window("com.apple.Notes", "Recipes", left)], ["com.apple.Notes": 1]), [:])
        // The app's only window, and its only saved window: whatever the title.
        XCTAssertEqual(floating([1: window("com.apple.Music", "Music", right)], ["com.apple.Music": 1]), [1: 2])
        // The app has another window too.
        XCTAssertEqual(floating([1: window("com.apple.Music", "Music", right)], ["com.apple.Music": 2]), [:])
        // Each saved window is taken once, by the lowest id.
        let twins: Seen = [1: window("com.apple.Notes", "Ideas", left), 2: window("com.apple.Notes", "Ideas", right), 3: window("com.apple.Notes", "Groceries", left)]
        XCTAssertEqual(floating(twins, ["com.apple.Notes": 3]), [1: 1, 3: 0])
        // Never a window of another app, nor one without a bundle id.
        XCTAssertEqual(floating([1: window("com.apple.Safari", "Ideas", left), 2: window(nil, "Ideas", left)], ["com.apple.Safari": 1]), [:])
        XCTAssertEqual(Restore.floating([1: window(nil, "x", left)], appWindows: [:], savedAppWindows: [:], saved: [window(nil, "x", left)]), [:])
    }

    func testTheOnlyWindowOfAnAppIsItsFloatingOneOnlyWhenTheAppHadOneWindow() {
        let saved = [window("com.apple.Music", "Equaliser", left)]
        let player: Seen = [1: window("com.apple.Music", "Player", right)]
        let now = ["com.apple.Music": 1]
        // Music had a tiled window as well. The first of the two to come back can be either.
        XCTAssertEqual(Restore.floating(player, appWindows: now, savedAppWindows: ["com.apple.Music": 2], saved: saved), [:])
        // Music had this window and no other.
        XCTAssertEqual(Restore.floating(player, appWindows: now, savedAppWindows: ["com.apple.Music": 1], saved: saved), [1: 0])
        // Nothing is known of how many windows the app had: no guess.
        XCTAssertEqual(Restore.floating(player, appWindows: now, savedAppWindows: [:], saved: saved), [:])
        // The title still tells, however many windows the app had or has.
        let equaliser: Seen = [2: window("com.apple.Music", "Equaliser", right)]
        XCTAssertEqual(Restore.floating(equaliser, appWindows: ["com.apple.Music": 2], savedAppWindows: ["com.apple.Music": 2], saved: saved), [2: 0])
        // The app's only window took the saved one by its title: nothing is left to guess at.
        XCTAssertEqual(Restore.floating(equaliser, appWindows: now, savedAppWindows: ["com.apple.Music": 1], saved: saved), [2: 0])
        // Two windows at once with other titles, where one was saved: no way to tell which it is.
        let strangers: Seen = [1: window("com.apple.Music", "Player", right), 2: window("com.apple.Music", "Lyrics", right)]
        XCTAssertEqual(Restore.floating(strangers, appWindows: ["com.apple.Music": 2], savedAppWindows: ["com.apple.Music": 1], saved: saved), [:])
    }

    func testWindowsAreKnownByAppAndTitle() {
        let saved = [window("com.apple.Notes", "Ideas", left), window("com.apple.Notes", "Ideas", right), window("com.apple.Music", "", left),
                     window("com.apple.Music", nil, left)]
        let now: Seen = [3: window("com.apple.Notes", "Ideas", .zero), 1: window("com.apple.Notes", "Ideas", .zero), 2: window("com.apple.Notes", "Ideas", .zero),
                         4: window("com.apple.Safari", "Ideas", .zero), 5: window("com.apple.Music", "", .zero), 6: window("com.apple.Music", nil, .zero),
                         7: window(nil, "Ideas", .zero)]
        XCTAssertEqual(Restore.sameTitle(now, saved: saved), [1: 0, 2: 1], "each saved window once, the lowest ids first; no title is no match")
        XCTAssertEqual(Restore.sameTitle(now, saved: []), [:])
        XCTAssertEqual(Restore.sameTitle([:], saved: saved), [:])
    }

    // MARK: The session

    func session(_ trees: [String: NodeSnapshot], floating: [WindowID] = [], tiled: [WindowID] = [], _ windows: [WindowID: WindowDescriptor]) -> RestoreSession {
        RestoreSession(trees: trees, floating: floating, tiled: tiled, windows: windows, from: start)
    }

    func testADesktopTakesItsShapeAsItsWindowsComeBack() {
        let layout = split(.horizontal, 1, win(10, 2), split(.vertical, 1, win(11), win(12)))
        var s = session(["d1": layout], [10: window("com.apple.Safari", "Docs", left),
                                          11: window("com.apple.Terminal", "zsh", right), 12: window("com.apple.Terminal", "zsh", right.offsetBy(dx: 0, dy: 300))])
        XCTAssertEqual(s.waiting, ["d1"])
        XCTAssertEqual(s.apps(waitingOn: "d1", at: start), ["com.apple.Safari", "com.apple.Terminal"])
        XCTAssertEqual(s.apps(waitingOn: "d2", at: start), [])

        // Nothing of this desktop's yet.
        XCTAssertNil(s.rebuild("d1", windows: [1: window("com.apple.Notes", nil, left)], kept: [], at: start))

        let first = s.rebuild("d1", windows: [2: window("com.apple.Terminal", "zsh", right)], kept: [], at: start.addingTimeInterval(5))
        XCTAssertEqual(first?.snapshot, split(.horizontal, 1, win(2)))
        XCTAssertEqual(s.apps(waitingOn: "d1", at: start), ["com.apple.Safari", "com.apple.Terminal"])

        // The window that is back already is not looked at again, and keeps its place.
        let second = s.rebuild("d1", windows: [3: window("com.apple.Safari", "Docs", left)], kept: [2], at: start.addingTimeInterval(30))
        XCTAssertEqual(second?.snapshot, split(.horizontal, 1, win(3, 2), win(2)))
        XCTAssertEqual(s.apps(waitingOn: "d1", at: start), ["com.apple.Terminal"])

        // The same windows again change nothing.
        XCTAssertNil(s.rebuild("d1", windows: [2: window("com.apple.Terminal", "zsh", right), 3: window("com.apple.Safari", "Docs", left)], kept: [2, 3], at: start))

        let third = s.rebuild("d1", windows: [4: window("com.apple.Terminal", "zsh", .zero)], kept: [2, 3], at: start.addingTimeInterval(60))
        XCTAssertEqual(third?.snapshot, split(.horizontal, 1, win(3, 2), split(.vertical, 1, win(2), win(4))))
        XCTAssertEqual(s.waiting, [], "every window is back: the desktop is left to the user")
        XCTAssertNil(s.rebuild("d1", windows: [5: window("com.apple.Terminal", "zsh", right)], kept: [2, 3, 4], at: start))
    }

    func testAWindowThatLeftLeavesAGap() {
        let layout = split(.horizontal, 1, win(10), win(11), win(12))
        var s = session(["d1": layout], [10: window("com.apple.Safari", nil, left), 11: window("com.apple.Safari", nil, right),
                                          12: window("com.apple.Notes", nil, right)])
        XCTAssertEqual(s.rebuild("d1", windows: [1: window("com.apple.Safari", nil, left)], kept: [], at: start)?.windows, [1])
        // Window 1 has closed, or gone to another desktop.
        XCTAssertEqual(s.rebuild("d1", windows: [2: window("com.apple.Notes", nil, right)], kept: [], at: start)?.windows, [2])
        // It is kept for as long as it is in the desktop's layout, on screen or not.
        XCTAssertEqual(s.rebuild("d1", windows: [3: window("com.apple.Safari", nil, right)], kept: [1, 2], at: start)?.windows, [1, 3, 2])
    }

    func testAWindowTakesAPlaceOnOneDesktopOnly() {
        let one = split(.horizontal, 1, win(10), win(11))
        let two = split(.horizontal, 1, win(20))
        var s = session(["d1": one, "d2": two], [10: window("com.apple.Safari", nil, left), 11: window("com.apple.Notes", nil, right),
                                                 20: window("com.apple.Safari", nil, left)])
        XCTAssertEqual(s.rebuild("d1", windows: [1: window("com.apple.Safari", nil, left)], kept: [], at: start)?.windows, [1])
        // The user carries it to the other desktop in Mission Control.
        XCTAssertNil(s.rebuild("d2", windows: [1: window("com.apple.Safari", nil, left)], kept: [], at: start))
        XCTAssertEqual(s.rebuild("d2", windows: [1: window("com.apple.Safari", nil, left), 2: window("com.apple.Safari", nil, right)], kept: [], at: start)?.windows, [2])
    }

    func testWhatTheUserChangesStays() {
        let layout = split(.horizontal, 1, win(10), win(11))
        var s = session(["d1": layout, "d2": layout], [10: window("com.apple.Safari", nil, left), 11: window("com.apple.Safari", nil, right)])
        XCTAssertNotNil(s.rebuild("d1", windows: [1: window("com.apple.Safari", nil, left)], kept: [], at: start))
        s.stop("d1")
        XCTAssertEqual(s.waiting, ["d2"])
        XCTAssertEqual(s.apps(waitingOn: "d1", at: start), [])
        XCTAssertNil(s.rebuild("d1", windows: [2: window("com.apple.Safari", nil, right)], kept: [1], at: start))
        XCTAssertNotNil(s.rebuild("d2", windows: [3: window("com.apple.Safari", nil, right)], kept: [], at: start), "other desktops carry on")
    }

    func testEverythingEndsWithTheGracePeriod() {
        let layout = split(.horizontal, 1, win(10), win(11))
        let windows: Seen = [10: window("com.apple.Safari", nil, left), 11: window("com.apple.Notes", "Ideas", right)]
        var s = session(["d1": layout], floating: [11], windows)
        let late = start.addingTimeInterval(RestoreSession.gracePeriod + 1)
        XCTAssertEqual(RestoreSession.gracePeriod, 180)
        XCTAssertNotNil(s.rebuild("d1", windows: [1: window("com.apple.Safari", nil, left)], kept: [], at: start.addingTimeInterval(RestoreSession.gracePeriod)))
        XCTAssertTrue(s.mayFloat("com.apple.Notes", at: start.addingTimeInterval(170)))
        XCTAssertNil(s.rebuild("d1", windows: [2: window("com.apple.Safari", nil, right)], kept: [1], at: late))
        XCTAssertEqual(s.waiting, [])
        XCTAssertFalse(s.mayFloat("com.apple.Notes", at: late))
        XCTAssertEqual(s.refloat([3: window("com.apple.Notes", "Ideas", left)], appWindows: ["com.apple.Notes": 1], at: late), [])

        XCTAssertEqual(RestoreSession().waiting, [], "a session with nothing saved waits for nothing")
    }

    func testAStateWithoutDescriptionsRestoresNothing() {
        // Saved before Iguana described its windows, or by a window that is no longer there.
        let layout = split(.horizontal, 1, win(10), win(11))
        var s = session(["d1": layout, "d2": split(.vertical, 1, win(12))], floating: [12], [11: window(nil, "x", left)])
        XCTAssertEqual(s.waiting, [])
        XCTAssertFalse(s.mayFloat("com.apple.Notes", at: start))
        XCTAssertNil(s.rebuild("d1", windows: [1: window("com.apple.Safari", nil, left)], kept: [], at: start))
    }

    func testHandFloatedWindowsFloatAgainOnce() {
        let windows: Seen = [10: window("com.apple.Notes", "Ideas", left), 11: window("com.apple.Notes", "Groceries", right)]
        var s = session(["d1": split(.horizontal, 1, win(12))], floating: [10, 11], windows)
        XCTAssertTrue(s.mayFloat("com.apple.Notes", at: start))
        XCTAssertFalse(s.mayFloat("com.apple.Safari", at: start))
        XCTAssertEqual(s.refloat([1: window("com.apple.Notes", "Ideas", left), 2: window("com.apple.Notes", "Recipes", left)],
                                 appWindows: ["com.apple.Notes": 2], at: start), [1])
        XCTAssertEqual(s.refloat([3: window("com.apple.Notes", "Ideas", left)], appWindows: ["com.apple.Notes": 3], at: start), [], "taken already")
        XCTAssertEqual(s.refloat([4: window("com.apple.Notes", "Groceries", left)], appWindows: ["com.apple.Notes": 4], at: start), [4])
        XCTAssertFalse(s.mayFloat("com.apple.Notes", at: start), "nothing left to float")
    }

    func testTheFirstWindowBackOfAnAppThatHadMoreIsNotItsFloatingOne() {
        // Music had the player in a layout and the equaliser floating. Notes had one window, floating.
        let windows: Seen = [10: window("com.apple.Music", "Player", left), 11: window("com.apple.Music", "Equaliser", right),
                             12: window("com.apple.Notes", "Ideas", right), 13: window(nil, "No app", left)]
        var s = session(["d1": split(.horizontal, 1, win(10), win(13))], floating: [11, 12], windows)
        XCTAssertEqual(s.refloat([1: window("com.apple.Music", "Player", .zero)], appWindows: ["com.apple.Music": 1], at: start), [],
                       "the player is back first and alone, and is not taken for the equaliser")
        XCTAssertTrue(s.mayFloat("com.apple.Music", at: start), "which is still waited for")
        XCTAssertEqual(s.refloat([2: window("com.apple.Music", "Equaliser", .zero)], appWindows: ["com.apple.Music": 2], at: start), [2])
        XCTAssertEqual(s.refloat([3: window("com.apple.Notes", "Recipes", .zero)], appWindows: ["com.apple.Notes": 1], at: start), [3],
                       "the only window of an app that had one")
    }

    func testAWindowTiledByHandIsTiledAgainOnce() {
        // A rule floats every window of the calculator. The user had tiled one of them.
        let windows: Seen = [10: window("com.apple.calculator", "Sums", left), 11: window("com.apple.Safari", "Docs", right)]
        var s = session(["d1": split(.horizontal, 1, win(10), win(11))], tiled: [10, 99], windows)
        XCTAssertTrue(s.mayTile("com.apple.calculator", at: start))
        XCTAssertFalse(s.mayTile("com.apple.Safari", at: start), "Safari was not tiled by hand")
        XCTAssertFalse(s.mayFloat("com.apple.calculator", at: start))

        // Its other windows were not saved, so the app's only window so far can be any of them.
        XCTAssertEqual(s.retile([1: window("com.apple.calculator", "Tape", .zero)], at: start), [], "another title: left to the rule")
        XCTAssertEqual(s.retile([2: window("com.apple.calculator", "Sums", .zero), 3: window("com.apple.calculator", "Sums", .zero)], at: start), [2])
        XCTAssertFalse(s.mayTile("com.apple.calculator", at: start), "taken")
        XCTAssertEqual(s.retile([4: window("com.apple.calculator", "Sums", .zero)], at: start), [])

        // Tiled again, it takes its place in the layout like any window that comes back.
        XCTAssertEqual(s.rebuild("d1", windows: [2: window("com.apple.calculator", "Sums", left)], kept: [], at: start)?.windows, [2])
    }

    func testWindowsTiledByHandAreForgottenWithTheGracePeriod() {
        let windows: Seen = [10: window("com.apple.calculator", "Sums", left)]
        var s = session(["d1": split(.horizontal, 1, win(10))], tiled: [10], windows)
        let late = start.addingTimeInterval(RestoreSession.gracePeriod + 1)
        XCTAssertTrue(s.mayTile("com.apple.calculator", at: start.addingTimeInterval(RestoreSession.gracePeriod)))
        XCTAssertFalse(s.mayTile("com.apple.calculator", at: late))
        XCTAssertEqual(s.retile([1: window("com.apple.calculator", "Sums", .zero)], at: late), [])

        var other = session(["d1": split(.horizontal, 1, win(10))], tiled: [10], windows)
        XCTAssertEqual(other.retile([1: window("com.apple.calculator", "Sums", .zero)], at: late), [], "without asking first, too")
    }
}
