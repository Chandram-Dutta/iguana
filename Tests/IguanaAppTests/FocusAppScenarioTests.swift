import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// `focus-app NAME`: one key that brings an app forward, or opens it.
final class FocusAppScenarioTests: FocusScenarioTestCase {
    func testFocusAppFindsARunningAppByNameOrBundleID() {
        let safari = open("Safari", bundleID: "com.apple.Safari")
        let notes = open("Notes")

        XCTAssertEqual(mac.run("focus-app Safari"), "ok")
        XCTAssertEqual(mac.focused, safari.id)
        XCTAssertTrue(keyWindow === safari)
        XCTAssertEqual(mac.system.focusRequests, [safari.id])

        mac.system.click(notes)
        mac.settle()
        XCTAssertEqual(mac.run("focus-app com.apple.Safari"), "ok")
        XCTAssertEqual(mac.focused, safari.id)

        mac.system.click(notes)
        mac.settle()
        XCTAssertEqual(mac.run("focus-app saf"), "ok", "the start of the name is enough")
        XCTAssertTrue(keyWindow === safari)

        // Visual Studio Code calls itself Code. The name of its bundle finds it too.
        let code = mac.system.launch("Code", bundleID: "com.microsoft.VSCode")
        code.bundleURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let editor = mac.system.open(code)
        mac.settle()
        mac.system.click(notes)
        mac.settle()
        XCTAssertEqual(mac.run("focus-app Visual Studio Code"), "ok")
        XCTAssertEqual(mac.focused, editor.id)
        XCTAssertTrue(mac.system.opened.isEmpty, "nothing was opened: the apps are running")
    }

    func testOfTwoAppsTheTextNamesEquallyWellTheOneUsedLastWins() {
        let safari = open("Safari")
        let preview = open("Safari Technology Preview")
        let notes = open("Notes")

        XCTAssertEqual(mac.run("focus-app saf"), "ok")
        XCTAssertEqual(mac.focused, preview.id, "it had the focus after Safari did")

        mac.system.click(safari)
        mac.settle()
        mac.system.click(notes)
        mac.settle()
        XCTAssertEqual(mac.run("focus-app saf"), "ok")
        XCTAssertEqual(mac.focused, safari.id)
    }

    func testFocusAppGoesToTheWindowOfTheAppThatHadTheFocusLast() {
        let safari = mac.system.launch("Safari")
        let remembered = mac.system.open(safari, title: "Docs")
        mac.settle()
        let other = mac.system.open(safari, title: "Downloads")
        mac.settle()
        mac.system.click(remembered)
        mac.settle()
        open("Notes")
        // Safari's other window comes to the front of Safari's windows without taking the keyboard.
        other.perform(kAXRaiseAction)
        XCTAssertLessThan(mac.system.order.firstIndex { $0 === other }!, mac.system.order.firstIndex { $0 === remembered }!)

        XCTAssertEqual(mac.run("focus-app safari"), "ok")
        XCTAssertEqual(mac.focused, remembered.id, "not the one that happens to be in front")

        // With that window in the Dock, the one that can be seen is taken.
        open("Mail")
        mac.system.minimise(remembered)
        mac.settle()
        XCTAssertEqual(mac.run("focus-app safari"), "ok")
        XCTAssertEqual(mac.focused, other.id)
        XCTAssertTrue(remembered.minimised)
    }

    func testFocusAppGoesRoundTheWindowsOfTheAppThatHasTheFocus() {
        let safari = mac.system.launch("Safari")
        let windows = (1...3).map { n -> FakeWindow in
            let window = mac.system.open(safari, title: "Tab \(n)")
            mac.settle()
            return window
        }
        XCTAssertEqual(mac.focused, windows[2].id)

        // Always the same way round, whichever window is in front.
        for next in [0, 1, 2, 0] {
            XCTAssertEqual(mac.run("focus-app safari"), "ok")
            XCTAssertEqual(mac.focused, windows[next].id)
            XCTAssertTrue(keyWindow === windows[next])
        }
    }

    func testFocusAppStaysOnAnOnlyWindowThatHasTheFocus() {
        open("Notes")
        let safari = open("Safari")

        XCTAssertEqual(mac.run("focus-app safari"), "ok")

        XCTAssertEqual(mac.focused, safari.id)
        XCTAssertTrue(mac.system.focusRequests.isEmpty, "there was nothing to do")
        XCTAssertEqual(safari.raises, 0)
    }

    func testFocusAppBringsBackAMinimisedWindow() {
        let safari = mac.system.launch("Safari")
        let older = mac.system.open(safari, title: "Older")
        mac.settle()
        let newer = mac.system.open(safari, title: "Newer")
        mac.settle()
        let notes = open("Notes")
        mac.system.minimise(older)
        mac.system.minimise(newer)
        mac.settle()
        XCTAssertFrame(notes.rect, mac.usable(), "alone on the desktop")

        XCTAssertEqual(mac.run("focus-app safari"), "ok: brought back a minimised window")

        XCTAssertFalse(newer.minimised, "the one that had the focus last comes out of the Dock")
        XCTAssertTrue(older.minimised, "the other stays there")
        XCTAssertEqual(mac.focused, newer.id)
        XCTAssertTrue(keyWindow === newer)
        XCTAssertEqual(mac.tiles.count, 2, "and it has its tile again")
    }

    func testFocusAppShowsAnAppThatIsHidden() {
        let safari = open("Safari")
        open("Notes")
        mac.system.hide(safari.app)
        mac.settle()
        XCTAssertNil(mac.tiles[safari.id])

        XCTAssertEqual(mac.run("focus-app safari"), "ok: activated Safari")

        XCTAssertFalse(safari.app.isHidden)
        XCTAssertEqual(safari.app.activations, 1)
        XCTAssertTrue(mac.system.frontmost === safari.app)
        XCTAssertEqual(mac.focused, safari.id)
        XCTAssertNotNil(mac.tiles[safari.id])
    }

    func testFocusAppActivatesAnAppWhoseWindowsAreOnAnotherDesktop() {
        let second = mac.system.addDesktop(to: mac.system.displayList[0])
        let safari = mac.system.launch("Safari")
        let elsewhere = mac.system.open(safari, on: second)
        let notes = open("Notes")
        XCTAssertEqual(mac.focused, notes.id)

        XCTAssertEqual(mac.run("focus-app safari"), "ok: activated Safari")

        // Which window to show, and whether to change desktop for it, is left to macOS.
        XCTAssertEqual(safari.activations, 1)
        XCTAssertTrue(mac.system.frontmost === safari)
        XCTAssertTrue(mac.system.focusRequests.isEmpty)
        XCTAssertEqual(elsewhere.raises, 0)
        XCTAssertTrue(mac.system.pressed.isEmpty, "Iguana does not switch desktop itself")
    }

    func testAnAppActivatedJustAfterAFocusCommandKeepsTheKeyboard() {
        let second = mac.system.addDesktop(to: mac.system.displayList[0])
        let mail = mac.system.launch("Mail")
        mac.system.open(mail, on: second)
        let (left, _) = sideBySide()

        // One shortcut bound to a chain: the second command follows the first at once.
        XCTAssertEqual(mac.run("focus left; focus-app mail"), "ok: activated Mail")

        XCTAssertTrue(mac.system.frontmost === mail, "the check of the first command did not take the keyboard back")
        XCTAssertEqual(left.app.activations, 0)
        XCTAssertEqual(left.raises, 1)
        XCTAssertEqual(mac.system.focusRequests, [left.id])
    }

    func testActivatingAnAppEndsTheWaitForAnEarlierFocus() {
        let second = mac.system.addDesktop(to: mac.system.displayList[0])
        let mail = mac.system.launch("Mail")
        mac.system.open(mail, on: second)
        let (left, right) = sideBySide()
        // Nothing takes on this Mac, so the keyboard is still where it was when the check comes.
        mac.system.focusSticks = false

        XCTAssertEqual(mac.run("focus left; focus-app mail"), "ok: activated Mail")

        XCTAssertEqual(mail.activations, 1)
        XCTAssertEqual(left.app.activations, 0, "the first command is not tried again: the user has asked for something else since")
        XCTAssertEqual(left.raises, 1)
        XCTAssertTrue(keyWindow === right)
    }

    func testFocusAppOpensAnAppThatIsNotRunningOrSaysThereIsNone() {
        open("Notes")
        mac.system.installed["com.apple.mail"] = URL(fileURLWithPath: "/System/Applications/Mail.app")
        mac.system.folders["/Applications"] = ["Safari.app", "Xcode.app", "notes.txt"]
        mac.system.folders["/Users/test/Applications"] = ["Zed.app", "Xcode.app"]
        // Zed has just quit, and Iguana has not been told yet. It is opened afresh like any other.
        mac.system.launch("Zed").isTerminated = true

        XCTAssertEqual(mac.run("focus-app com.apple.mail"), "ok: opening Mail", "by bundle id, wherever it is installed")
        XCTAssertEqual(mac.run("focus-app zed"), "ok: opening Zed", "by the name of its bundle, in the user's own folder too")
        XCTAssertEqual(mac.run("focus-app XCODE"), "ok: opening Xcode")
        XCTAssertEqual(mac.system.opened.map(\.path), ["/System/Applications/Mail.app", "/Users/test/Applications/Zed.app", "/Applications/Xcode.app"],
                       "of two with the same name, the one in /Applications")

        // Part of a name is not enough to open something.
        XCTAssertEqual(mac.run("focus-app xc"), "error: no app called 'xc'")
        XCTAssertEqual(mac.run("focus-app notes.txt"), "error: no app called 'notes.txt'")
        XCTAssertEqual(mac.run("focus-app nonesuch"), "error: no app called 'nonesuch'")
        XCTAssertEqual(mac.system.opened.count, 3)
        XCTAssertTrue(mac.system.focusRequests.isEmpty, "the app that is running was left alone")
        XCTAssertTrue(mac.logged("focus-app").isEmpty)
    }

    func testAnAppThatWillNotOpenIsLogged() {
        mac.system.folders["/Applications"] = ["Zed.app"]
        mac.system.openFailure = "the app is damaged"

        // The command has answered before macOS says it could not.
        XCTAssertEqual(mac.run("focus-app zed"), "ok: opening Zed")

        XCTAssertEqual(mac.logged("focus-app: could not open /Applications/Zed.app: the app is damaged").count, 1)
    }
}
