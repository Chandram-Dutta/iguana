import Foundation

/// What Iguana is and where it keeps its files.
enum Iguana {
    static let version = "0.3.0"

    static var configURL: URL {
        // Only an absolute path counts, as the XDG specification says; anything else would
        // depend on the folder the command happened to be run from.
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("iguana/iguana.toml")
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Iguana")
    }

    /// Whether this process is the test suite. The tests run on a Mac that is in use, often
    /// with an Iguana of its own running, so they must never write to that Iguana's log or to
    /// its saved layouts, even when a test forgets to say where its own go.
    static let isUnderTest = NSClassFromString("XCTestCase") != nil
}
