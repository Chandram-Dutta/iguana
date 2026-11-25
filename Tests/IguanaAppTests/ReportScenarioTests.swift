import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// What `status`, `list-windows`, `list-spaces` and `tree` say about a Mac with windows on
/// it, as text and as the documents of `--json`.
final class ReportScenarioTests: NamedWindowsTestCase {
    /// Two displays with a window of every kind: tiled on each display, floating by hand, a
    /// dialog, and one tiled on a desktop that is not being shown. Safari has the focus.
    @discardableResult
    func populate() -> (docs: FakeWindow, sums: FakeWindow, todo: FakeWindow, player: FakeWindow, zsh: FakeWindow) {
        addStudio()
        mac.system.showDesktop(3)
        mac.settle()
        let zsh = open("Terminal", "zsh", frame: onStudio)
        mac.system.showDesktop(2)
        mac.settle()
        let todo = open("Notes", "Todo", frame: onStudio)
        let player = open("Music", "Player", frame: onStudio)
        XCTAssertEqual(mac.run("float"), "ok: floating")
        let sums = openDialog("Calculator", "Sums", frame: CGRect(x: 500, y: 300, width: 300, height: 200))
        let docs = open("Safari", "Docs")
        return (docs, sums, todo, player, zsh)
    }

    /// A report as `--json` gives it, read back with the types that document its shape.
    func document<T: Decodable>(_ command: Command, _ type: T.Type = T.self, shortcuts: Report.Shortcuts = Report.Shortcuts(active: 40, warnings: []),
                                tourShowing: Bool = false, lastShortcut: Report.LastShortcut? = nil, update: Report.Update? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let text = mac.wm.jsonReport(command, shortcuts: shortcuts, tourShowing: tourShowing, lastShortcut: lastShortcut, update: update)
        XCTAssertFalse(text.hasPrefix("error"), text, file: file, line: line)
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    // MARK: status

    func testStatusSaysWhatIguanaIsDoing() {
        open("Safari", "Docs")
        open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        mac.system.minimise(zsh)
        mac.settle()

        XCTAssertEqual(mac.run("status"), """
        Iguana \(Iguana.version): tiling
        config: built-in defaults
        windows: 2 tiled on screen, 3 known, 3 apps watched
        stage manager: off
        Display 1, Built-in Display: showing desktop 1 of 1; this display has 1 desktop(s)
        """)

        XCTAssertEqual(mac.run("pause"), "ok: paused")
        XCTAssertEqual(mac.run("status").components(separatedBy: "\n").first, "Iguana \(Iguana.version): paused")
    }

    func testStatusNamesTheConfigFileItsWarningsTheModeAndWhatTheShellAdds() {
        let reply = mac.writeConfig("""
        [gaps]
        inner = 4
        wibble = 3

        [mode.resize]
        h = "resize shrink width"
        esc = "mode default"
        """)
        XCTAssertEqual(reply, "ok: loaded \(mac.configURL.path) with warnings:\n  - unknown key 'wibble' in [gaps]")
        XCTAssertEqual(mac.run("mode resize"), "ok")
        mac.wm.statusExtras = { ["shortcuts: 2 active", "last shortcut: h, 3 s ago: ok"] }

        XCTAssertEqual(mac.run("status"), """
        Iguana \(Iguana.version): tiling
        config: \(mac.configURL.path)
          warning: unknown key 'wibble' in [gaps]
        windows: 0 tiled on screen, 0 known, 0 apps watched
        stage manager: off
        Display 1, Built-in Display: showing desktop 1 of 1; this display has 1 desktop(s)
        mode: resize
        shortcuts: 2 active
        last shortcut: h, 3 s ago: ok
        """)

        XCTAssertEqual(mac.run("mode default"), "ok")
        XCTAssertFalse(mac.run("status").contains("mode:"), "the shortcuts of [bindings] are not a mode worth a line")
    }

    func testStatusSaysHowMuchRoomTheStageManagerStripGets() {
        let docs = open("Safari", "Docs")
        mac.system.stageManager = StageManager.State(isOn: true)
        XCTAssertTrue(mac.run("status").contains("\nstage manager: on, leaving 150 pt for the strip\n"))
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertFrame(docs.rect, CGRect(x: 158, y: 33, width: 1274, height: 859), "at the next look the window makes room for the strip")

        // "Show recent apps" is off: the strip only appears at the screen's edge, and gets no room.
        mac.system.stageManager = StageManager.State(isOn: true, stripAutoHides: true)
        XCTAssertTrue(mac.run("status").contains("\nstage manager: on\n"))
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertFrame(docs.rect, CGRect(x: 8, y: 33, width: 1424, height: 859))

        // A number of points in the config file is left free whenever Stage Manager is on.
        mac.writeConfig("[stage-manager]\nreserve-strip = 220\n")
        XCTAssertTrue(mac.run("status").contains("\nstage manager: on, leaving 220 pt for the strip\n"))
        mac.system.stageManager = StageManager.State()
        XCTAssertTrue(mac.run("status").contains("\nstage manager: off\n"))
    }

    // MARK: list-windows

    func testListWindowsSaysHowEachWindowIsTreated() {
        mac.system.launch("Finder")
        mac.settle()
        XCTAssertEqual(mac.run("list-windows"), "no windows on this Space", "an app without a window is no row")

        let second = mac.system.addDesktop(to: mac.system.displayList[0])
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        mac.system.minimise(zsh)
        let player = open("Music", "Player")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        let sums = openDialog("Calculator", "Sums", frame: CGRect(x: 500, y: 300, width: 300, height: 200))
        let scan = open("Preview", "Scan", on: second)
        mac.system.click(todo)
        mac.settle()

        XCTAssertEqual(mac.run("list-windows"), """
          \(docs.id)\ttiled\tSafari\tDocs
        * \(todo.id)\ttiled\tNotes\tTodo
          \(zsh.id)\tnot on screen\tTerminal\tzsh
          \(player.id)\tfloating\tMusic\tPlayer
          \(sums.id)\tunmanaged\tCalculator\tSums
          \(scan.id)\tnot on screen\tPreview\tScan
        """)

        // A window that opens while tiling is paused is one Iguana tiles, though it has no tile yet.
        XCTAssertEqual(mac.run("pause"), "ok: paused")
        let inbox = open("Mail", "Inbox", frame: CGRect(x: 300, y: 200, width: 500, height: 400))
        XCTAssertEqual(inbox.rect, CGRect(x: 300, y: 200, width: 500, height: 400))
        XCTAssertEqual(mac.run("list-windows").components(separatedBy: "\n").last, "* \(inbox.id)\ttiled\tMail\tInbox")
    }

    // MARK: list-spaces

    func testListSpacesSaysWhatEachDisplayIsShowing() {
        XCTAssertEqual(mac.run("list-spaces"), "Display 1, Built-in Display: showing desktop 1 of 1; this display has 1 desktop(s)")

        let studio = addStudio()
        XCTAssertEqual(mac.run("list-spaces"), """
        Display 1, Built-in Display: showing desktop 1 of 3; this display has 1 desktop(s)
        Display 2, Studio Display: showing desktop 2 of 3; this display has 2 desktop(s)
        """)

        mac.system.showDesktop(3)
        mac.system.show(mac.system.addFullscreenSpace(to: mac.system.displayList[0]), on: mac.system.displayList[0])
        XCTAssertEqual(mac.run("list-spaces"), """
        Display 1, Built-in Display: showing a fullscreen Space; this display has 1 desktop(s)
        Display 2, Studio Display: showing desktop 3 of 3; this display has 2 desktop(s)
        """, "asked afresh each time: nothing had to settle first")
        _ = studio
    }

    // MARK: tree

    func testTreeShowsTheLayoutOfEachDisplay() {
        addStudio()
        let docs = open("Safari", "Docs")
        let long = String(repeating: "A very long title. ", count: 4)
        let todo = open("Notes", long)
        let zsh = open("Terminal", "zsh")

        XCTAssertEqual(mac.run("tree"), """
        Built-in Display, desktop 1
          horizontal  [weight 1.00]
            - Safari: Docs #\(docs.id)  [weight 1.00]
            vertical  [weight 1.00]
              - Notes: \(long.prefix(50)) #\(todo.id)  [weight 1.00]
              - Terminal: zsh #\(zsh.id)  [weight 1.00]
        Studio Display, desktop 2
          (no tiled windows)
        """)
    }

    func testTreeMentionsWindowsThatAreNotOnScreenAndLayoutsThatAreNotShown() {
        let studio = addStudio()
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh", frame: onStudio)
        mac.system.minimise(todo)
        mac.settle()

        // The second display goes to an app in fullscreen. Its desktop keeps its layout.
        mac.system.show(mac.system.addFullscreenSpace(to: studio), on: studio)
        mac.settle()
        XCTAssertEqual(mac.run("tree"), """
        Built-in Display, desktop 1
          horizontal  [weight 1.00]
            - Safari: Docs #\(docs.id)  [weight 1.00]
            - Notes: Todo #\(todo.id)  (not on screen)  [weight 1.00]
        Studio Display, fullscreen Space (not managed)
        1 other Space(s) have a remembered layout
        """)
        _ = zsh
    }

    func testAWindowIguanaHasNotLookedAtYetIsInTheTreeByItsNumber() throws {
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")

        // Iguana starts again while Notes is too busy to say what windows it has.
        todo.app.answers = false
        mac.relaunch()
        XCTAssertEqual(mac.run("tree"), """
        Built-in Display, desktop 1
          horizontal  [weight 1.00]
            - Safari: Docs #\(docs.id)  [weight 1.00]
            - window \(todo.id) (not seen yet)  [weight 1.00]
        """, "its place in the saved layout is kept")

        let layout = try XCTUnwrap(document(.tree, Report.Trees.self).displays[0].layout)
        XCTAssertEqual(layout.children?.map(\.id), [docs.id, todo.id])
        XCTAssertEqual(layout.children?.map(\.app), ["Safari", nil], "no app and no title are made up for it")
        XCTAssertEqual(layout.children?.map(\.title), ["Docs", nil])
        XCTAssertEqual(layout.children?.map(\.onScreen), [true, false])
        XCTAssertEqual(try document(.listWindows, Report.Windows.self).windows.map(\.id), [docs.id])

        // Notes answers again, and is asked again the next time it comes to the front.
        todo.app.answers = true
        mac.system.click(docs)
        mac.settle()
        mac.system.click(todo)
        mac.settle()
        XCTAssertTrue(mac.run("tree").contains("- Notes: Todo #\(todo.id)  [weight 1.00]"))
        XCTAssertFrame(todo.rect, CGRect(x: 724, y: 33, width: 708, height: 859))
    }

    // MARK: The documents of --json

    func testTheWindowsDocumentSaysWhatAndWhereEachWindowIs() throws {
        let w = populate()
        let report = try document(.listWindows, Report.Windows.self)

        XCTAssertEqual(report.windows, [
            Report.Window(id: w.zsh.id, app: "Terminal", bundleId: "com.example.terminal", title: "zsh", state: .notOnScreen, focused: false,
                          desktop: 3, display: "Studio Display", frame: nil),
            Report.Window(id: w.todo.id, app: "Notes", bundleId: "com.example.notes", title: "Todo", state: .tiled, focused: false,
                          desktop: 2, display: "Studio Display", frame: Report.Frame(CGRect(x: 1448, y: 33, width: 2544, height: 1399))),
            Report.Window(id: w.player.id, app: "Music", bundleId: "com.example.music", title: "Player", state: .floating, focused: false,
                          desktop: 2, display: "Studio Display", frame: Report.Frame(w.player.rect)),
            Report.Window(id: w.sums.id, app: "Calculator", bundleId: "com.example.calculator", title: "Sums", state: .unmanaged, focused: false,
                          desktop: 1, display: "Built-in Display", frame: Report.Frame(CGRect(x: 500, y: 300, width: 300, height: 200))),
            Report.Window(id: w.docs.id, app: "Safari", bundleId: "com.example.safari", title: "Docs", state: .tiled, focused: true,
                          desktop: 1, display: "Built-in Display", frame: Report.Frame(CGRect(x: 8, y: 33, width: 1424, height: 859))),
        ])

        // The document is asked for afresh: a click a moment ago shows.
        mac.system.click(w.todo)
        let after = try document(.listWindows, Report.Windows.self)
        XCTAssertEqual(after.windows.filter(\.focused).map(\.id), [w.todo.id])
    }

    func testTheSpacesDocumentSaysWhichDesktopEachWindowIsOn() throws {
        let w = populate()
        var report = try document(.listSpaces, Report.Spaces.self)

        XCTAssertEqual(report.desktops, [
            Report.Desktop(number: 1, display: "Built-in Display", showing: true, active: true, windows: [w.sums.id, w.docs.id]),
            Report.Desktop(number: 2, display: "Studio Display", showing: true, active: false, windows: [w.todo.id, w.player.id]),
            Report.Desktop(number: 3, display: "Studio Display", showing: false, active: false, windows: [w.zsh.id]),
        ])
        XCTAssertEqual(report.displays, [
            Report.Display(name: "Built-in Display", number: 1, desktop: 1, desktopCount: 1, main: true),
            Report.Display(name: "Studio Display", number: 2, desktop: 2, desktopCount: 2, main: false),
        ])

        // The desktop in use is the one with the focused window on it.
        mac.system.click(w.todo)
        report = try document(.listSpaces, Report.Spaces.self)
        XCTAssertEqual(report.desktops.map(\.active), [false, true, false])

        // A display that shows an app in fullscreen shows none of its desktops.
        let studio = mac.system.displayList[1]
        mac.system.show(mac.system.addFullscreenSpace(to: studio), on: studio)
        mac.settle()
        report = try document(.listSpaces, Report.Spaces.self)
        XCTAssertEqual(report.desktops.map(\.showing), [true, false, false])
        XCTAssertEqual(report.displays.map(\.desktop), [1, nil])
    }

    func testTheTreesDocumentHoldsTheLayoutOfEachDisplay() throws {
        let w = populate()
        let scan = open("Preview", "Scan")
        mac.system.minimise(scan)
        mac.settle()
        let report = try document(.tree, Report.Trees.self)

        XCTAssertEqual(report.otherLayouts, 1, "desktop 3 has a layout and is not being shown")
        XCTAssertEqual(report.displays.map(\.display), ["Built-in Display", "Studio Display"])
        XCTAssertEqual(report.displays.map(\.desktop), [1, 2])

        let builtIn = try XCTUnwrap(report.displays[0].layout)
        XCTAssertEqual(builtIn.type, .container)
        XCTAssertEqual(builtIn.orientation, .horizontal)
        XCTAssertEqual(builtIn.stacked, false)
        XCTAssertEqual(builtIn.children?.map(\.type), [.window, .window])
        XCTAssertEqual(builtIn.children?.map(\.id), [w.docs.id, scan.id])
        XCTAssertEqual(builtIn.children?.map(\.app), ["Safari", "Preview"])
        XCTAssertEqual(builtIn.children?.map(\.title), ["Docs", "Scan"])
        XCTAssertEqual(builtIn.children?.map(\.onScreen), [true, false], "the minimised window keeps its place")
        XCTAssertEqual(builtIn.children?.map(\.weight), [1, 1])

        let studio = try XCTUnwrap(report.displays[1].layout)
        XCTAssertEqual(studio.children?.map(\.id), [w.todo.id], "the floating window is in no layout")

        // With its only tiled window gone, a display has no layout: null, not an empty one.
        mac.system.close(w.todo)
        mac.settle()
        let after = try document(.tree, Report.Trees.self)
        XCTAssertNil(after.displays[1].layout)
        XCTAssertEqual(after.displays[1].desktop, 2)
    }

    func testTheStatusDocumentSaysWhatTheTextSays() throws {
        populate()
        let last = Report.LastShortcut(keys: "option-l", secondsAgo: 4, reply: "ok")
        var status = try document(.status, Report.Status.self, shortcuts: Report.Shortcuts(active: 38, warnings: ["option-f: taken"]),
                                  tourShowing: true, lastShortcut: last, update: Report.Update(version: "9.9.9", url: "https://example.com/9.9.9"))

        XCTAssertEqual(status.version, Iguana.version)
        XCTAssertTrue(status.permission)
        XCTAssertFalse(status.paused)
        XCTAssertEqual(status.configPath, mac.configURL.path)
        XCTAssertFalse(status.configExists, "the built-in defaults are in use")
        XCTAssertEqual(status.configWarnings, [])
        XCTAssertEqual(status.windows, Report.WindowCounts(tiled: 2, known: 5, apps: 5))
        XCTAssertEqual(status.stageManager, Report.StageManager(on: false, reserved: 0))
        XCTAssertEqual(status.displays, [
            Report.Display(name: "Built-in Display", number: 1, desktop: 1, desktopCount: 1, main: true),
            Report.Display(name: "Studio Display", number: 2, desktop: 2, desktopCount: 2, main: false),
        ])
        XCTAssertNil(status.mode)
        // What the app shell hands over is passed on as it is.
        XCTAssertEqual(status.shortcuts, Report.Shortcuts(active: 38, warnings: ["option-f: taken"]))
        XCTAssertTrue(status.tourShowing)
        XCTAssertEqual(status.lastShortcut, last)
        XCTAssertEqual(status.update, Report.Update(version: "9.9.9", url: "https://example.com/9.9.9"))

        // The same Mac with a config file, a mode on, Stage Manager on and tiling paused.
        mac.writeConfig("[gaps]\nwibble = 3\n\n[mode.resize]\nh = \"resize shrink width\"\n")
        mac.system.stageManager = StageManager.State(isOn: true)
        XCTAssertEqual(mac.run("mode resize"), "ok")
        XCTAssertEqual(mac.run("pause"), "ok: paused")
        status = try document(.status, Report.Status.self)
        XCTAssertTrue(status.paused)
        XCTAssertTrue(status.configExists)
        XCTAssertEqual(status.configWarnings, ["unknown key 'wibble' in [gaps]"])
        XCTAssertEqual(status.stageManager, Report.StageManager(on: true, reserved: 150))
        XCTAssertEqual(status.mode, "resize")
        XCTAssertNil(status.lastShortcut)
        XCTAssertNil(status.update)
        XCTAssertFalse(status.tourShowing)
    }

    func testOnlyStatusAnswersWithoutThePermission() throws {
        open("Safari", "Docs")
        mac.system.isTrusted = false
        let needsPermission = "error: Iguana needs Accessibility permission (System Settings > Privacy & Security > Accessibility)"

        for command in [Command.listWindows, .listSpaces, .tree] {
            let text = mac.wm.jsonReport(command, shortcuts: Report.Shortcuts(active: 0, warnings: []), tourShowing: false, lastShortcut: nil)
            XCTAssertEqual(text, needsPermission, "the same answer as without --json")
        }
        XCTAssertEqual(mac.run("list-windows"), needsPermission)
        XCTAssertEqual(mac.run("list-spaces"), needsPermission)
        XCTAssertEqual(mac.run("tree"), needsPermission)

        // `status` is how the user finds out what is wrong.
        let status = try document(.status, Report.Status.self)
        XCTAssertFalse(status.permission)
        XCTAssertEqual(status.version, Iguana.version)
        XCTAssertEqual(mac.run("status"), """
        Iguana \(Iguana.version): waiting for Accessibility permission
        (System Settings > Privacy & Security > Accessibility, switch on Iguana)
        """)
    }

    func testACommandWithoutADocumentSaysSoAndIsNotRun() {
        let docs = open("Safari", "Docs")
        for command in [Command.pause, .float, .close, .reload] {
            let text = mac.wm.jsonReport(command, shortcuts: Report.Shortcuts(active: 0, warnings: []), tourShowing: false, lastShortcut: nil)
            XCTAssertEqual(text, "error: this command has no --json form")
        }
        mac.settle()
        XCTAssertEqual(mac.run("status").components(separatedBy: "\n").first, "Iguana \(Iguana.version): tiling", "not paused")
        XCTAssertFrame(docs.rect, mac.usable(), "the window is still there, and still tiled")
    }
}
