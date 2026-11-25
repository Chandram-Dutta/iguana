import XCTest
@testable import iguana

/// Noticing that the config file was saved, against a file in a folder of the test's own.
final class ConfigWatcherTests: XCTestCase {
    var folder: URL!
    var file: URL { folder.appendingPathComponent("iguana.toml") }

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iguana-watcher-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Write a file and say when it was written, so that no test depends on how fast it runs.
    func write(_ text: String, to url: URL? = nil, at time: TimeInterval = 1_700_000_000) throws {
        let url = url ?? file
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
    }

    func testNoFileHasASignatureOfItsOwn() {
        XCTAssertEqual(ConfigWatcher.signature(of: file), "missing")
    }

    func testAFileThatWasMarkedIsNotAChange() throws {
        try write("a = 1\n")
        let watcher = ConfigWatcher { [unowned self] in file }
        XCTAssertTrue(watcher.changed(), "before anything was read, the file is news")
        XCTAssertFalse(watcher.changed(), "and it is news once")

        try write("a = 22\n")
        watcher.mark()
        XCTAssertFalse(watcher.changed(), "Iguana read this one itself")
    }

    func testAChangeOfSizeOrOfTimeIsNoticed() throws {
        try write("a = 1\n")
        let watcher = ConfigWatcher { [unowned self] in file }
        watcher.mark()
        XCTAssertFalse(watcher.changed())

        try write("a = 1\n", at: 1_700_000_100)
        XCTAssertTrue(watcher.changed(), "saved again with the same text")
        XCTAssertFalse(watcher.changed())

        try FileManager.default.removeItem(at: file)
        try write("a = 100\n", at: 1_700_000_100)
        XCTAssertTrue(watcher.changed(), "longer")
    }

    func testAnotherFileOfTheSameSizeAndTimeIsNoticed() throws {
        try write("a = 1\n")
        let watcher = ConfigWatcher { [unowned self] in file }
        watcher.mark()
        // As a dotfiles tool does it: the new file is written beside the old one and takes its name.
        let other = folder.appendingPathComponent("incoming.toml")
        try write("a = 2\n", to: other)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: other)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
        XCTAssertTrue(watcher.changed())
    }

    func testTheFileComingAndGoingIsNoticed() throws {
        let watcher = ConfigWatcher { [unowned self] in file }
        watcher.mark()
        XCTAssertFalse(watcher.changed(), "no file, and still no file")
        try write("a = 1\n")
        XCTAssertTrue(watcher.changed())
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(watcher.changed())
        XCTAssertFalse(watcher.changed())
    }

    func testALinkIsFollowedToTheFileItPointsAt() throws {
        let dotfiles = folder.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("iguana.toml")
        try write("a = 1\n", to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        XCTAssertEqual(ConfigWatcher.signature(of: file), ConfigWatcher.signature(of: real))

        let watcher = ConfigWatcher { [unowned self] in file }
        watcher.mark()
        try write("a = 1\n", to: real, at: 1_700_000_500)
        XCTAssertTrue(watcher.changed(), "the link is the same; the file behind it is not")
    }

    func testTheTimerTellsOncePerChange() throws {
        try write("a = 1\n")
        let watcher = ConfigWatcher { [unowned self] in file }
        watcher.mark()
        var told = 0
        watcher.start(every: 0.01) { told += 1 }
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        spin(0.1)
        XCTAssertEqual(told, 0, "nothing was saved")

        try write("a = 2\n", at: 1_700_000_100)
        let deadline = Date().addingTimeInterval(5)
        while told == 0, Date() < deadline { spin(0.01) }
        spin(0.1)
        XCTAssertEqual(told, 1)
    }

    func testAWatcherThatIsGoneStopsLooking() throws {
        try write("a = 1\n")
        var told = 0
        var watcher: ConfigWatcher? = ConfigWatcher { [unowned self] in file }
        watcher?.start(every: 0.01) { told += 1 }
        watcher = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(told, 0)
    }
}
