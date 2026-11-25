import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// The JSON reports of a window manager that has not started tiling: it watches nothing and
/// moves nothing, which is all a test may do on a Mac that is in use.
final class ReportsTests: XCTestCase {
    var folder: URL!
    var oldConfigHome: String?

    override func setUp() {
        // Look for the config file in a throwaway folder, not in the user's own.
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iguana-reports-\(UUID().uuidString)")
        oldConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", folder.path, 1)
    }

    override func tearDown() {
        if let oldConfigHome { setenv("XDG_CONFIG_HOME", oldConfigHome, 1) } else { unsetenv("XDG_CONFIG_HOME") }
    }

    func report(_ command: Command, last: Report.LastShortcut? = nil) -> String {
        WindowManager().jsonReport(command, shortcuts: Report.Shortcuts(active: 40, warnings: ["option-f: taken"]),
                                   tourShowing: true, lastShortcut: last)
    }

    func testStatusAnswersBeforeTilingStarts() throws {
        let text = report(.status, last: Report.LastShortcut(keys: "option-l", secondsAgo: 4, reply: "ok"))
        let status = try JSONDecoder().decode(Report.Status.self, from: Data(text.utf8))
        XCTAssertEqual(status.version, Iguana.version)
        XCTAssertEqual(status.permission, AXIsProcessTrusted())
        XCTAssertFalse(status.paused)
        XCTAssertEqual(status.configPath, folder.appendingPathComponent("iguana/iguana.toml").path)
        XCTAssertFalse(status.configExists, "the built-in defaults are in use")
        XCTAssertEqual(status.windows, Report.WindowCounts(tiled: 0, known: 0, apps: 0))
        XCTAssertEqual(status.shortcuts, Report.Shortcuts(active: 40, warnings: ["option-f: taken"]))
        XCTAssertTrue(status.tourShowing)
        XCTAssertEqual(status.lastShortcut?.keys, "option-l")
        XCTAssertFalse(text.hasPrefix("error"), "the command line reports success")
    }

    func testTheOtherReportsNeedThePermissionAndSayNothingTheyDoNotKnow() throws {
        for command in [Command.listWindows, .listSpaces, .tree] {
            let text = report(command)
            guard AXIsProcessTrusted() else {
                XCTAssertTrue(text.hasPrefix("error: Iguana needs Accessibility permission"), "the same answer as without --json")
                continue
            }
            switch command {
            case .listWindows:
                XCTAssertEqual(try JSONDecoder().decode(Report.Windows.self, from: Data(text.utf8)).windows, [], "nothing is watched yet")
            case .listSpaces:
                let spaces = try JSONDecoder().decode(Report.Spaces.self, from: Data(text.utf8))
                XCTAssertTrue(spaces.desktops.allSatisfy { $0.windows.isEmpty })
                XCTAssertEqual(spaces.desktops.map(\.number), Array(1..<spaces.desktops.count + 1), "numbered as Mission Control numbers them")
            default:
                let trees = try JSONDecoder().decode(Report.Trees.self, from: Data(text.utf8))
                XCTAssertTrue(trees.displays.allSatisfy { $0.layout == nil })
                XCTAssertEqual(trees.otherLayouts, 0)
            }
        }
        // Asked for something that has no document.
        XCTAssertTrue(report(.reload).hasPrefix("error"))
    }
}
