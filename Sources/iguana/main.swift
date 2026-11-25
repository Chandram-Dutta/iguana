import Foundation
import IguanaCore

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    Iguana \(WindowManager.version), a tiling window manager for macOS.

    usage:
      iguana daemon                 run the window manager (this is what Iguana.app does)
      iguana config init            write the default config to \(WindowManager.configURL.path)
      iguana config path            print where the config file lives
      iguana config check [file]    check a config file and list every problem in it
      iguana settings               open the settings window
      iguana tour                   show the welcome tour again
      iguana <command>              send a command to the running window manager

    commands:
    \(Command.usage.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
    """)
}

switch arguments.first {
case nil:
    // Launched as an app (no terminal attached): be the window manager.
    if isatty(STDIN_FILENO) == 0 { Daemon.run() }
    printUsage()
case "daemon":
    Daemon.run()
case "help", "-h", "--help":
    printUsage()
case "version", "--version":
    print(WindowManager.version)
case "config":
    switch arguments.dropFirst().first {
    case "path":
        print(WindowManager.configURL.path)
    case "init":
        if let message = ConfigFile.createIfMissing() {
            print(message)
            exit(message.hasPrefix("error") ? 1 : 0)
        }
        print("\(WindowManager.configURL.path) already exists, left untouched")
    case "check":
        let url = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : WindowManager.configURL
        let (report, ok) = ConfigFile.check(url)
        print(report.joined(separator: "\n"))
        exit(ok ? 0 : 1)
    default:
        print("usage: iguana config init | iguana config path | iguana config check [file]")
        exit(2)
    }
case "debug-snapshot":
    guard arguments.count > 1 else {
        print("usage: iguana debug-snapshot <folder> [config file to show]")
        exit(2)
    }
    let sample = arguments.count > 2 ? try? String(contentsOfFile: arguments[2], encoding: .utf8) : nil
    SettingsSnapshot.run(folder: arguments[1], sampleConfig: sample)
case "debug-desk":
    guard arguments.count > 1 else {
        print("usage: iguana debug-desk <folder>")
        exit(2)
    }
    DeskSnapshot.run(folder: arguments[1])
case "debug-switcher":
    guard arguments.count > 1 else {
        print("usage: iguana debug-switcher <folder>")
        exit(2)
    }
    SwitcherSnapshot.run(folder: arguments[1])
case "debug-tour":
    guard arguments.count > 1 else {
        print("usage: iguana debug-tour <folder> [scene]")
        exit(2)
    }
    TourSnapshot.run(folder: arguments[1], only: arguments.count > 2 ? arguments[2] : nil)
default:
    let line = arguments.joined(separator: " ")
    do {
        _ = try Command.parseRequest(line)
    } catch {
        FileHandle.standardError.write(Data("iguana: \(error)\nRun `iguana help` for the list of commands.\n".utf8))
        exit(2)
    }
    guard let reply = IPC.send(line) else {
        FileHandle.standardError.write(Data("iguana: the window manager is not running (open Iguana.app or run `iguana daemon`)\n".utf8))
        exit(1)
    }
    print(reply, terminator: reply.hasSuffix("\n") ? "" : "\n")
    exit(reply.hasPrefix("error") ? 1 : 0)
}
