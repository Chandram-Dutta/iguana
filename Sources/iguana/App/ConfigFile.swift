import Foundation
import IguanaCore

/// The config file on disk: writing it, checking it, and making the first one.
enum ConfigFile {
    /// Save a config file, creating its folder, and put the editor schema beside it.
    static func write(_ text: String, to url: URL) throws {
        // Write through a link to the file it points at, instead of replacing the link.
        let url = url.resolvingSymlinksInPath()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        let schema = folder.appendingPathComponent("iguana.schema.json")
        if (try? String(contentsOf: schema, encoding: .utf8)) != Config.jsonSchema + "\n" {
            try? Data((Config.jsonSchema + "\n").utf8).write(to: schema, options: .atomic)
        }
    }

    /// Check a file the way the app would load it. Returns the lines to print and whether it loads.
    static func check(_ url: URL) -> (report: [String], ok: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (["\(url.path): no file there, so the built-in settings apply"], true)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (["\(url.path): cannot be read"], false)
        }
        do {
            let (config, warnings) = try Config.load(text)
            if warnings.isEmpty {
                return (["\(url.path): no problems (\(config.bindings.count) shortcuts, \(config.rules.count) rules)"], true)
            }
            return (["\(url.path): loads, with \(warnings.count) problem\(warnings.count == 1 ? "" : "s"):"] + warnings.map { "  - \($0)" }, true)
        } catch {
            return (["\(url.path): cannot be loaded: \(error)", "Iguana keeps its previous settings until this is fixed."], false)
        }
    }

    /// Write the default config unless a file is already there. Returns a note about what happened.
    static func createIfMissing() -> String? {
        let url = Iguana.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try write(Config.defaultText + "\n", to: url)
            return "wrote the default config to \(url.path) (and iguana.schema.json beside it, for editor completion)"
        } catch {
            return "error: could not write \(url.path): \(error.localizedDescription)"
        }
    }
}
