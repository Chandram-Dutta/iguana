import AppKit
import XCTest
import IguanaCore
@testable import iguana

/// The window manager, running against a made-up Mac.
///
/// A test arranges the Mac through `system` (displays, apps, windows, the pointer), lets time
/// pass with `settle()`, sends commands with `run(_:)`, and then looks at where the windows
/// are. Nothing here touches the real screen, the real config file, the saved layouts or the
/// log of the Iguana that may be running on the same Mac.
final class Scenario {
    let scheduler: FakeScheduler
    let system: FakeWindowSystem
    let mover: ImmediateMover
    /// A folder of its own for the config file and the saved layouts.
    let folder: URL
    private(set) var wm: WindowManager!
    private static var listening: ObjectIdentifier?
    /// Every line written to the log, oldest first.
    private(set) var log: [String] = []
    /// When this Mac started. Another value stands for a restart of the Mac.
    var bootTime = 1_700_000_000.0

    var configURL: URL { folder.appendingPathComponent("iguana.toml") }
    var stateURL: URL { folder.appendingPathComponent("state.json") }

    /// - Parameters:
    ///   - display: false to start with no display at all, for a test that adds its own.
    ///   - config: the text of the config file. Nil for no file, which is the built-in defaults.
    ///   - start: false to leave tiling stopped, as before the permission is granted.
    init(display: Bool = true, config: String? = nil, start: Bool = true) {
        scheduler = FakeScheduler()
        system = FakeWindowSystem(scheduler: scheduler)
        mover = ImmediateMover(scheduler: scheduler)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iguana-scenario-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if display { system.addDisplay() }
        if let config { try? Data(config.utf8).write(to: folder.appendingPathComponent("iguana.toml")) }
        wm = makeManager()
        // The log goes to the scenario made last, which is the one the test is looking at.
        Self.listening = ObjectIdentifier(self)
        Log.sink = { [weak self] line in self?.log.append(line) }
        wm.reloadConfig()
        if start {
            wm.start()
            settle()
        }
    }

    /// Call from `tearDown`.
    func finish() {
        // Not when another scenario has taken the log over since (`replaceScenario`).
        if Self.listening == ObjectIdentifier(self) {
            Log.sink = nil
            Self.listening = nil
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeManager() -> WindowManager {
        WindowManager(system: system, mover: mover, scheduler: scheduler,
                      store: StateStore(url: stateURL, bootTime: { [unowned self] in bootTime }),
                      configURL: { [unowned self] in configURL })
    }

    // MARK: Time

    /// Let the window manager finish everything it has put off: the refresh that follows an
    /// event, the checks a moment later, the saving of the layouts.
    func settle(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scheduler.runUntilIdle(), "the window manager never came to rest", file: file, line: line)
    }

    // MARK: Commands and config

    /// Send a command as the command line does, then let things settle. `--window ID` works.
    /// With `settle` false nothing that the command put off has run yet, for a test that
    /// steps through it with `scheduler.advance(by:)`.
    @discardableResult
    func run(_ text: String, settle: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> String {
        let reply: String
        do {
            let request = try Command.parseRequest(text)
            reply = wm.run(request.command, window: request.window)
        } catch {
            reply = "error: \(error)"
        }
        if settle { self.settle(file: file, line: line) }
        return reply
    }

    /// Replace the config file and read it, as saving it does.
    @discardableResult
    func writeConfig(_ text: String) -> String {
        try? Data(text.utf8).write(to: configURL)
        let reply = wm.reloadConfig()
        settle()
        return reply
    }

    // MARK: Iguana quitting and starting again

    /// Quit Iguana and start it again on the same Mac. The windows keep their ids.
    func relaunch() {
        wm.saveState()
        wm = makeManager()
        wm.reloadConfig()
        wm.start()
        settle()
    }

    /// Save, as quitting does, without starting again.
    func save() {
        wm.saveState()
    }

    // MARK: Looking

    /// Where each tiled window on screen has its tile.
    var tiles: [CGWindowID: CGRect] { wm.tileFrames }

    /// The windows that are tiled on screen, left to right and then top to bottom.
    var tiledInReadingOrder: [CGWindowID] {
        tiles.sorted { ($0.value.minX, $0.value.minY) < ($1.value.minX, $1.value.minY) }.map(\.key)
    }

    var focused: CGWindowID? { wm.focusedWindow }

    /// The area windows are tiled into on a display.
    func usable(_ display: FakeDisplay? = nil) -> CGRect {
        let uuid = (display ?? system.displayList[0]).uuid
        return system.displays().first { $0.uuid == uuid }!.usableFrame(wm.config)
    }

    /// The lines of the log that contain `text`.
    func logged(_ text: String) -> [String] {
        log.filter { $0.contains(text) }
    }
}

/// A test case with a `Scenario` ready: one display of 1440 by 900 with one desktop, the
/// built-in settings, tiling started.
class ScenarioTestCase: XCTestCase {
    private(set) var mac: Scenario!

    /// Override to start from something else.
    func makeScenario() -> Scenario { Scenario() }

    override func setUp() {
        super.setUp()
        mac = makeScenario()
    }

    override func tearDown() {
        mac.finish()
        mac = nil
        super.tearDown()
    }

    /// Start over with another scenario in the middle of a test.
    func replaceScenario(_ scenario: Scenario) {
        mac.finish()
        mac = scenario
    }
}

/// Two frames are the same to within a point, which is as exact as windows get.
func XCTAssertFrame(_ actual: CGRect?, _ expected: CGRect, accuracy: CGFloat = 1, _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("no frame, expected \(expected). \(message())", file: file, line: line) }
    let same = abs(actual.minX - expected.minX) <= accuracy && abs(actual.minY - expected.minY) <= accuracy
        && abs(actual.width - expected.width) <= accuracy && abs(actual.height - expected.height) <= accuracy
    XCTAssertTrue(same, "\(actual) is not \(expected). \(message())", file: file, line: line)
}
