import CoreGraphics
import IguanaCore

/// Answers the lines that arrive on the command socket. It decides who answers each one: the
/// JSON reports, the welcome tour, the update check or the window manager.
struct RequestHandler {
    /// Runs a command in the window manager, on the window named or the focused one.
    let run: (Command, CGWindowID?) -> String
    /// The tour's answer while it has the keyboard, and nil when the command is not for it.
    let tourReply: (Command, CGWindowID?) -> String?
    /// A report as a JSON document (`--json`).
    let jsonReport: (Command) -> String
    /// Asks GitHub now, and calls back on the main thread with what it found.
    let checkForUpdate: (@escaping (UpdateCheck.Outcome) -> Void) -> Void
    var version = Iguana.version

    /// The reply to a line that can be answered at once.
    func reply(to line: String) -> String {
        do {
            let request = try Command.parseRequest(line)
            if request.json { return jsonReport(request.command) }
            return tourReply(request.command, request.window) ?? run(request.command, request.window)
        } catch {
            return "error: \(error)"
        }
    }

    /// A command from the command line. Every command answers at once except `update`, which
    /// answers when GitHub has answered.
    func handle(_ line: String, reply: @escaping (String) -> Void) {
        guard (try? Command.parseRequest(line))?.command == .update else { return reply(self.reply(to: line)) }
        let version = version
        checkForUpdate { reply($0.reply(running: version)) }
    }
}
