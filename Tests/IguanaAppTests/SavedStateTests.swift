import XCTest
import IguanaCore
@testable import iguana

/// The saved state's format, in memory only: the real state file is never read or written here.
final class SavedStateTests: XCTestCase {
    typealias SavedState = WindowManager.SavedState

    func testAFileFromBeforeWindowsWereDescribedStillLoads() throws {
        let old = """
        {"boot":1700000000,"trees":{"space-1|display-1":{"orientation":"horizontal","weight":1,"children":[
          {"window":41,"weight":1},{"orientation":"vertical","weight":1,"stacked":true,"children":[{"window":42,"weight":1},{"window":43,"weight":1}]}]}},
         "floating":[44],"minSizes":{"41":[600,400]}}
        """
        let saved = try JSONDecoder().decode(SavedState.self, from: Data(old.utf8))
        XCTAssertEqual(saved.boot, 1_700_000_000)
        XCTAssertEqual(saved.floating, [44])
        XCTAssertEqual(saved.minSizes?["41"], [600, 400])
        XCTAssertNil(saved.windows)
        XCTAssertEqual(saved.trees["space-1|display-1"].map { Tree(snapshot: $0).windows }, [41, 42, 43])

        // Older still: no minimum sizes either.
        let older = try JSONDecoder().decode(SavedState.self, from: Data(#"{"boot":1,"trees":{},"floating":[]}"#.utf8))
        XCTAssertNil(older.minSizes)
        XCTAssertNil(older.windows)

        // After a restart of the Mac such a file has nothing to know its windows by.
        let session = RestoreSession(trees: saved.trees, floating: saved.floating, windows: [:], from: Date())
        XCTAssertEqual(session.waiting, [])
    }

    func testWindowDescriptionsGoThereAndBack() throws {
        let tree = Tree()
        tree.insert(41)
        tree.insert(42, after: 41, split: .vertical)
        let safari = WindowDescriptor(bundleID: "com.apple.Safari", app: "Safari", title: "Docs — Iguana", frame: CGRect(x: 0, y: 38, width: 720, height: 862))
        let notes = WindowDescriptor(bundleID: "com.apple.Notes", app: "Notes", title: nil, frame: CGRect(x: 720, y: 38, width: 720, height: 431))
        let floating = WindowDescriptor(bundleID: "com.apple.Music", app: "Music", title: "Music", frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let state = SavedState(boot: 1_700_000_000, trees: ["space-1|display-1": tree.snapshot], floating: [44],
                               minSizes: ["41": [600, 400]], windows: ["41": safari, "42": notes, "44": floating])
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(SavedState.self, from: data)
        XCTAssertEqual(back.boot, state.boot)
        XCTAssertEqual(back.trees, state.trees)
        XCTAssertEqual(back.floating, [44])
        XCTAssertEqual(back.minSizes?["41"], [600, 400])
        XCTAssertEqual(back.windows, state.windows)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"title\":null"), "a window without a title has no title written")

        // After a restart of the Mac, the layout waits for windows like these.
        var session = RestoreSession(trees: back.trees, floating: back.floating,
                                     windows: Dictionary(uniqueKeysWithValues: (back.windows ?? [:]).map { (CGWindowID($0.key)!, $0.value) }), from: Date())
        XCTAssertEqual(session.waiting, ["space-1|display-1"])
        XCTAssertTrue(session.mayFloat("com.apple.Music", at: Date()))
        let rebuilt = session.rebuild("space-1|display-1", windows: [7: safari, 8: notes], kept: [], at: Date())
        XCTAssertEqual(rebuilt?.windows, [7, 8])
        XCTAssertEqual(rebuilt?.root.orientation, tree.root.orientation)
    }
}
