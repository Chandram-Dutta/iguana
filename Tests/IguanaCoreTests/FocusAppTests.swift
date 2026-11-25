import XCTest
@testable import IguanaCore

/// `focus-app`: reading the command, which running app it names, which of the app's windows
/// gets the focus, and which bundle is opened when the app is not running.
final class FocusAppTests: XCTestCase {
    typealias App = FocusApp.App

    let xcode = App(pid: 10, bundleID: "com.apple.dt.Xcode", names: ["Xcode"], lastActive: 50)
    let code = App(pid: 11, bundleID: "com.microsoft.VSCode", names: ["Code", "Visual Studio Code"], lastActive: 20)
    let terminal = App(pid: 12, bundleID: "com.apple.Terminal", names: ["Terminal"], lastActive: 0)
    let safari = App(pid: 13, bundleID: "com.apple.Safari", names: ["Safari"], lastActive: 30)

    func chosen(_ text: String, _ apps: [App]) -> Int32? { FocusApp.choose(text, among: apps)?.pid }

    // MARK: Reading the command

    func testTheAppIsTheRestOfTheLine() throws {
        XCTAssertEqual(try Command.parse("focus-app safari"), .focusApp("safari"))
        XCTAssertEqual(try Command.parse("focus-app Safari"), .focusApp("safari"), "matching ignores case")
        XCTAssertEqual(try Command.parse("  FOCUS-APP   Visual\tStudio  Code "), .focusApp("visual studio code"))
        XCTAssertEqual(try Command.parse("focus-app com.apple.Terminal"), .focusApp("com.apple.terminal"))
        XCTAssertEqual(try Command.parseRequest("focus-app safari").command, .focusApp("safari"))
    }

    func testTheAppMustBeNamed() {
        XCTAssertThrowsError(try Command.parse("focus-app"))
        XCTAssertThrowsError(try Command.parse("focus-app   "))
        XCTAssertThrowsError(try Command.parseRequest("focus-app safari --json"), "only reports have a JSON form")
        XCTAssertTrue(Command.usage.contains("\nfocus-app NAME|BUNDLE-ID "))
    }

    // MARK: Which app

    func testAnExactNameBeatsAPartOfAName() {
        XCTAssertEqual(chosen("code", [xcode, code]), 11, "Code, not Xcode, though Xcode was used last")
        XCTAssertEqual(chosen("xcode", [xcode, code]), 10)
        XCTAssertEqual(chosen("cod", [xcode, code]), 11, "a name that starts with the text beats one that only contains it")
        XCTAssertEqual(chosen("ode", [code, xcode]), 10, "both only contain it: the one used last")
    }

    func testTheNameOfTheBundleCountsToo() {
        XCTAssertEqual(chosen("visual studio code", [xcode, code]), 11)
        XCTAssertEqual(chosen("visual", [xcode, code]), 11)
    }

    func testABundleIDMustMatchExactly() {
        XCTAssertEqual(chosen("com.apple.terminal", [safari, terminal]), 12, "ignoring case")
        XCTAssertNil(chosen("com.apple", [safari, terminal]), "a part of a bundle id is no match")
        XCTAssertNil(chosen("Terminal.app", [terminal]))
    }

    func testABundleIDBeatsANameThatHappensToMatch() {
        let odd = App(pid: 20, bundleID: "com.example.other", names: ["com.apple.safari helper"], lastActive: 99)
        XCTAssertEqual(chosen("com.apple.safari", [odd, safari]), 13)
    }

    func testTiesGoToTheAppUsedLast() {
        let old = App(pid: 30, bundleID: "org.example.notes.old", names: ["Notes"], lastActive: 5)
        let new = App(pid: 31, bundleID: "org.example.notes", names: ["Notes"], lastActive: 8)
        XCTAssertEqual(chosen("notes", [old, new]), 31)
        XCTAssertEqual(chosen("notes", [new, old]), 31, "whatever the order of the list")
        let never = App(pid: 32, bundleID: nil, names: ["Notes"], lastActive: 0)
        let neither = App(pid: 33, bundleID: nil, names: ["Notes"], lastActive: 0)
        XCTAssertEqual(chosen("notes", [never, neither]), 32, "never used: the first in the list")
    }

    func testNothingMatches() {
        XCTAssertNil(chosen("mail", [xcode, code, terminal, safari]))
        XCTAssertNil(chosen("mail", []))
    }

    // MARK: Which window

    func testTheWindowThatHadTheFocusLast() {
        XCTAssertEqual(FocusApp.pick(showing: [7, 5, 9], remembered: 9, focused: 100), .window(9))
        XCTAssertEqual(FocusApp.pick(showing: [7, 5, 9], remembered: nil, focused: nil), .window(7), "never focused: the one in front")
        XCTAssertEqual(FocusApp.pick(showing: [7, 5], remembered: 9, focused: 100), .window(7),
                       "the one it remembers is on another desktop: the one in front of those shown")
    }

    func testPressingAgainGoesThroughTheAppsWindows() {
        // Front to back changes with every focus, the order of the ids does not.
        XCTAssertEqual(FocusApp.pick(showing: [5, 9, 7], remembered: 5, focused: 5), .window(7))
        XCTAssertEqual(FocusApp.pick(showing: [7, 5, 9], remembered: 7, focused: 7), .window(9))
        XCTAssertEqual(FocusApp.pick(showing: [9, 7, 5], remembered: 9, focused: 9), .window(5), "after the last, the first again")
    }

    func testAnAppWithOneWindowStays() {
        XCTAssertEqual(FocusApp.pick(showing: [5], remembered: 5, focused: 5), .stay)
        XCTAssertEqual(FocusApp.pick(showing: [5], remembered: nil, focused: 100), .window(5))
    }

    func testNoWindowOnScreenBringsTheAppForward() {
        XCTAssertEqual(FocusApp.pick(showing: [], remembered: 5, focused: 100), .activate)
        XCTAssertEqual(FocusApp.pick(showing: [], remembered: nil, focused: nil), .activate)
    }

    /// All of the app's windows minimised: the one focused most recently comes back.
    func testAMinimisedWindowToBringBack() {
        XCTAssertEqual(FocusApp.minimisedToBringBack([3, 7], history: [7, 9, 3]), 7)
        XCTAssertEqual(FocusApp.minimisedToBringBack([3, 7], history: [9]), 3, "none in the history: the lowest id")
        XCTAssertNil(FocusApp.minimisedToBringBack([], history: [9]))
    }

    // MARK: Opening an app that is not running

    let paths = [
        "/Applications/Safari.app", "/Applications/Visual Studio Code.app", "/Applications/Xcode.app", "/Applications/Utilities",
        "/Applications/Utilities/Activity Monitor.app", "/System/Applications/Notes.app",
        "/System/Applications/Utilities/Terminal.app", "/Users/me/Applications/Notes.app", "/Applications/Readme.txt",
    ]

    func testTheBundleIsFoundByItsWholeName() {
        XCTAssertEqual(FocusApp.bundle(named: "safari", among: paths), "/Applications/Safari.app")
        XCTAssertEqual(FocusApp.bundle(named: "visual studio code", among: paths), "/Applications/Visual Studio Code.app")
        XCTAssertEqual(FocusApp.bundle(named: "TERMINAL", among: paths), "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(FocusApp.bundle(named: "activity monitor", among: paths), "/Applications/Utilities/Activity Monitor.app")
    }

    func testAPartOfTheNameIsNotEnough() {
        XCTAssertNil(FocusApp.bundle(named: "code", among: paths), "Visual Studio Code is not opened as 'code', nor is Xcode")
        XCTAssertNil(FocusApp.bundle(named: "safari.app", among: paths))
        XCTAssertNil(FocusApp.bundle(named: "utilities", among: paths), "a folder is not an app")
        XCTAssertNil(FocusApp.bundle(named: "readme", among: paths))
    }

    func testTheFirstFolderWins() {
        XCTAssertEqual(FocusApp.bundle(named: "notes", among: paths), "/System/Applications/Notes.app")
        XCTAssertEqual(FocusApp.folders(home: "/Users/me"), [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", "/Users/me/Applications",
        ])
    }
}
