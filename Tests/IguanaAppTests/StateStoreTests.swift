import XCTest
import IguanaCore
@testable import iguana

/// Reading and writing the file of saved layouts, in a folder of the test's own.
final class StateStoreTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iguana-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func store(_ name: String = "state.json") -> StateStore {
        StateStore(url: folder.appendingPathComponent(name), bootTime: { 1_700_000_000 })
    }

    /// Two windows side by side, one floating window and one learned minimum size.
    func example(boot: Double = 1_700_000_000) -> SavedState {
        let tree = Tree()
        tree.insert(41)
        tree.insert(42, after: 41, split: .horizontal)
        let safari = WindowDescriptor(bundleID: "com.apple.Safari", app: "Safari", title: "Docs", frame: CGRect(x: 8, y: 33, width: 708, height: 859))
        let notes = WindowDescriptor(bundleID: "com.apple.Notes", app: "Notes", title: "Todo", frame: CGRect(x: 724, y: 33, width: 708, height: 859))
        let music = WindowDescriptor(bundleID: "com.apple.Music", app: "Music", title: "Music", frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        return SavedState(boot: boot, trees: ["space-1|display-1": tree.snapshot], floating: [44],
                          minSizes: ["41": [600, 400]], windows: ["41": safari, "42": notes, "44": music])
    }

    func testWhatIsSavedComesBackTheSame() throws {
        let state = example()
        store().save(state)

        let back = try XCTUnwrap(store().load())
        XCTAssertEqual(back.boot, 1_700_000_000)
        XCTAssertEqual(back.trees, state.trees)
        XCTAssertEqual(back.floating, [44])
        XCTAssertEqual(back.minSizes, ["41": [600, 400]])
        XCTAssertEqual(back.windows, state.windows)

        // Saving again replaces what was there.
        store().save(SavedState(boot: 1_700_000_500, trees: [:], floating: [], minSizes: nil, windows: nil))
        let later = try XCTUnwrap(store().load())
        XCTAssertEqual(later.boot, 1_700_000_500)
        XCTAssertEqual(later.trees, [:])
        XCTAssertEqual(later.floating, [])
        XCTAssertNil(later.minSizes)
        XCTAssertNil(later.windows)
    }

    func testWithNoFileNothingIsSaved() {
        XCTAssertNil(store().load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store().url.path), "looking does not make a file")
    }

    func testAFileThatCannotBeReadCountsAsNothingSaved() throws {
        try Data("{\"boot\":17000, \"trees\": {".utf8).write(to: store().url)
        XCTAssertNil(store().load(), "cut off in the middle")

        try Data("[1, 2, 3]".utf8).write(to: store().url)
        XCTAssertNil(store().load(), "JSON, but not saved layouts")

        try Data().write(to: store().url)
        XCTAssertNil(store().load(), "empty")
    }

    func testSavingMakesTheFolder() {
        let deep = StateStore(url: folder.appendingPathComponent("Application Support/Iguana/state.json"), bootTime: { 1 })
        deep.save(example(boot: 1))

        XCTAssertEqual(deep.load()?.boot, 1)
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: deep.url.deletingLastPathComponent().path), ["state.json"],
                       "the file, and nothing left over from writing it")
    }

    func testTheStandardStoreOfATestRunIsInTheTemporaryFolder() {
        let url = StateStore.standard.url.standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path

        XCTAssertTrue(Iguana.isUnderTest)
        XCTAssertEqual(url.lastPathComponent, "state.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "iguana-tests-\(getpid())", "a folder of this test run alone")
        XCTAssertTrue(url.path.hasPrefix(temporary), "\(url.path) is not under \(temporary)")
        XCTAssertFalse(url.path.contains("Application Support"), "never the layouts of the Iguana in use")
        XCTAssertFalse(url.path.hasPrefix(Iguana.supportDirectory.path))
    }

    func testTheMacSaysWhenItStarted() {
        let boot = StateStore.systemBootTime
        XCTAssertGreaterThan(boot, 1_500_000_000, "a date, in seconds since 1970")
        XCTAssertLessThanOrEqual(boot, Date().timeIntervalSince1970, "and not in the future")
        XCTAssertEqual(boot, boot.rounded(), "whole seconds, so that it compares equal from one run to the next")
        XCTAssertEqual(StateStore.standard.bootTime(), boot, "the standard store asks the Mac")
        XCTAssertEqual(StateStore.systemBootTime, boot, "the same answer every time")
    }
}
