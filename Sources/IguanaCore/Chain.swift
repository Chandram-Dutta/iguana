import Foundation

/// One shortcut or one command line can run several commands: `flip; balance`.
extension Command {
    /// The commands of `text`, split at each `;`. Empty parts are left out, so a trailing `;`
    /// does no harm, and a single part is just that command.
    static func chain(_ text: String) throws -> Command {
        let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return try parse(parts.first ?? "") }
        var commands: [Command] = []
        for (i, part) in parts.enumerated() {
            let words = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.lowercased() }
            // A chain has one reply, so it cannot hold a document.
            if words.contains("--json") { throw CommandError("'--json' cannot be used in a chain") }
            let command = try parse(part)
            let last = i == parts.count - 1
            switch command {
            // A report has nowhere to go in the middle of a chain, and nothing runs after `quit`.
            case .listWindows, .listSpaces, .tree, .status, .quit:
                throw CommandError("'\(words[0])' cannot be part of a chain")
            // macOS finishes switching desktops after the command has returned, so the next
            // command would act on the desktop being left.
            case .space where !last, .moveToSpace where !last:
                throw CommandError("'\(words[0])' must come last in a chain")
            default:
                commands.append(command)
            }
        }
        return .sequence(commands)
    }

    /// Run the commands of a chain in order, each as if it were alone. The first reply that is
    /// an error stops the chain and is its reply; otherwise the last command answers.
    public static func runChain(_ commands: [Command], _ run: (Command) -> String) -> String {
        var reply = "ok"
        for command in commands {
            reply = run(command)
            if reply.hasPrefix("error") { break }
        }
        return reply
    }
}
