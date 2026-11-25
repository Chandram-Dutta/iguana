import ApplicationServices
import XCTest
import IguanaCore
@testable import iguana

/// What the app shell reads from the window manager: the facts behind the reports and the
/// hooks, the desktops the menu bar draws, the miniature in the settings window, and the log.
final class ShellFactsScenarioTests: NamedWindowsTestCase {
    // MARK: Facts

    func testTheFactsAreWhatTheLastLookSaw() {
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        mac.system.minimise(zsh)
        let player = open("Music", "Player")
        XCTAssertEqual(mac.run("float"), "ok: floating")
        let everything = Set([docs.id, todo.id, zsh.id, player.id])

        var facts = mac.wm.facts()
        XCTAssertEqual(Set(facts.windows.keys), everything)
        XCTAssertEqual(facts.existing, everything, "every window there is, on screen or not")
        XCTAssertEqual(facts.tiled, [docs.id, todo.id], "the windows that have a tile on screen")
        XCTAssertEqual(facts.visible, [docs.id, todo.id])
        XCTAssertEqual(facts.apps.values.compactMap(\.app.localizedName).sorted(), ["Music", "Notes", "Safari", "Terminal"])
        XCTAssertEqual(facts.trees.keys.sorted(), [key()])
        XCTAssertEqual(facts.trees[key()]?.windows, [docs.id, todo.id, zsh.id], "the minimised window keeps its place, the floating one has none")
        XCTAssertEqual(facts.activeDisplay?.name, "Built-in Display")
        XCTAssertEqual(facts.zoomed, [:])
        XCTAssertEqual(facts.windows[player.id]?.floating, true)
        XCTAssertEqual(mac.wm.tiledWindowCount, 2)

        // A zoomed window fills the desktop and is said to be zoomed, by desktop.
        XCTAssertEqual(mac.run("zoom --window \(docs.id)"), "ok")
        facts = mac.wm.facts()
        XCTAssertEqual(facts.zoomed, [key(): docs.id])
        XCTAssertEqual(facts.tiled, [docs.id, todo.id])
        XCTAssertFrame(docs.rect, mac.usable())
        XCTAssertEqual(mac.wm.tiledWindowCount, 2)
    }

    func testAFreshLookSeesWhatHasChangedSince() {
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        XCTAssertEqual(mac.focused, todo.id)

        // A click, and a display plugged in: the window manager has not looked since.
        mac.system.click(docs)
        mac.system.addDisplay("Studio Display", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440))
        _ = mac.wm.facts()
        XCTAssertEqual(mac.focused, todo.id, "the facts are those of the last look")
        XCTAssertEqual(mac.wm.displays.map(\.name), ["Built-in Display"])

        _ = mac.wm.facts(fresh: true)
        XCTAssertEqual(mac.focused, docs.id, "a fresh look asks which window has the focus")
        XCTAssertEqual(mac.wm.displays.map(\.name), ["Built-in Display", "Studio Display"], "and which displays there are")

        // Without the permission a fresh look still sees the displays, and leaves the focus alone.
        mac.system.isTrusted = false
        mac.system.click(todo)
        mac.system.removeDisplay(mac.system.displayList[1])
        _ = mac.wm.facts(fresh: true)
        XCTAssertEqual(mac.focused, docs.id)
        XCTAssertEqual(mac.wm.displays.map(\.name), ["Built-in Display"])
    }

    // MARK: The desktops in the menu bar

    func testTheDesksAreEveryDesktopInMissionControlOrder() {
        addStudio()
        mac.system.showDesktop(3)
        mac.settle()
        let zsh = open("Terminal", "zsh", frame: onStudio)
        mac.system.showDesktop(2)
        mac.settle()
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")

        let (desks, owners) = mac.wm.desks()
        XCTAssertEqual(desks.map(\.number), [1, 2, 3])
        XCTAssertEqual(desks.map(\.isActive), [true, false, false], "the desktop with the focused window on it")
        XCTAssertEqual(desks.map(\.display.name), ["Built-in Display", "Studio Display", "Studio Display"])
        XCTAssertEqual(desks.map(\.windows), [[docs.id, todo.id], [], [zsh.id]])
        XCTAssertEqual(desks.map(\.focused), [todo.id, nil, zsh.id], "the focused window, or the one last focused there")
        XCTAssertEqual(desks.map { Tree(snapshot: $0.layout).windows }, [[docs.id, todo.id], [], [zsh.id]])
        XCTAssertEqual(desks.map(\.screen), [CGSize(width: 1440, height: 900), CGSize(width: 2560, height: 1440), CGSize(width: 2560, height: 1440)])
        XCTAssertEqual(desks.map(\.usable), [CGRect(x: 0, y: 25, width: 1440, height: 875), CGRect(x: 0, y: 25, width: 2560, height: 1415),
                                             CGRect(x: 0, y: 25, width: 2560, height: 1415)], "under the menu bar, measured from the corner of its own display")
        XCTAssertEqual(owners, [docs.id: docs.pid, todo.id: todo.pid, zsh.id: zsh.pid], "whose icon to draw in each tile")

        // The pointer goes to the other display and the desktop there is clicked: no window has the focus.
        mac.system.pointerLocation = CGPoint(x: 2000, y: 700)
        mac.system.hide(docs.app)
        mac.system.hide(todo.app)
        mac.settle()
        XCTAssertEqual(mac.wm.desks().desks.map(\.isActive), [false, true, false], "the desktop under the pointer")

        // With every display unplugged there is nothing to draw.
        for display in mac.system.displayList { mac.system.removeDisplay(display) }
        mac.settle()
        XCTAssertTrue(mac.wm.desks().desks.isEmpty)
        XCTAssertTrue(mac.wm.desks().owners.isEmpty)
        XCTAssertNil(mac.wm.desktopPreview())
        XCTAssertEqual(mac.wm.menuBarTitle, "")
        XCTAssertEqual(mac.wm.tiledWindowCount, 0)
    }

    func testADesktopBeingShownDrawsOnlyWhatIsOnScreen() {
        mac.system.addDesktop(to: mac.system.displayList[0])
        let docs = open("Safari", "Docs")
        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        mac.system.minimise(zsh)
        mac.settle()

        var (desks, owners) = mac.wm.desks()
        XCTAssertEqual(desks.map(\.windows), [[docs.id, todo.id], []], "the minimised window is not drawn")
        XCTAssertEqual(Tree(snapshot: desks[0].layout).windows, [docs.id, todo.id, zsh.id], "though it has its place in the layout")
        XCTAssertEqual(owners.keys.sorted(), [docs.id, todo.id])

        // Of a desktop that is not being shown, nothing is on screen: every window it has is drawn.
        mac.system.showDesktop(2)
        mac.settle()
        (desks, owners) = mac.wm.desks()
        XCTAssertEqual(desks.map(\.isActive), [false, true])
        XCTAssertEqual(desks.map(\.windows), [[docs.id, todo.id, zsh.id], []])
        XCTAssertEqual(owners.keys.sorted(), [docs.id, todo.id, zsh.id])

        // A window that has closed since is not.
        mac.system.close(docs)
        XCTAssertEqual(mac.wm.desks().desks.map(\.windows), [[todo.id, zsh.id], []], "even before the next look")
    }

    func testTheMenuBarShowsTheNumberOfTheDesktopInUse() {
        XCTAssertEqual(mac.wm.menuBarTitle, "1")

        let studio = addStudio()
        let todo = open("Notes", "Todo", frame: onStudio)
        XCTAssertEqual(mac.wm.menuBarTitle, "2", "the desktop the focused window is on")

        // No window on the desktop being shown: the display under the pointer counts.
        mac.system.showDesktop(3)
        mac.settle()
        XCTAssertEqual(mac.wm.menuBarTitle, "1")
        mac.system.pointerLocation = CGPoint(x: 2000, y: 700)
        XCTAssertEqual(mac.wm.menuBarTitle, "3")

        // A fullscreen Space is not a desktop and has no number.
        mac.system.show(mac.system.addFullscreenSpace(to: studio), on: studio)
        mac.settle()
        XCTAssertEqual(mac.wm.menuBarTitle, "")
        _ = todo
    }

    // MARK: The miniature in the settings window

    func testThePreviewIsTheDesktopInUseOnceItHasTwoTiledWindows() throws {
        XCTAssertNil(mac.wm.desktopPreview(), "an empty desktop")
        let docs = open("Safari", "Docs")
        XCTAssertNil(mac.wm.desktopPreview(), "one window is not much of a layout")
        XCTAssertEqual(mac.wm.tiledWindowCount, 1)

        let todo = open("Notes", "Todo")
        let zsh = open("Terminal", "zsh")
        mac.system.minimise(zsh)
        mac.settle()
        let preview = try XCTUnwrap(mac.wm.desktopPreview())
        XCTAssertEqual(Tree(snapshot: preview.layout).windows, [docs.id, todo.id, zsh.id])
        XCTAssertEqual(preview.visible, [docs.id, todo.id], "the windows to draw")
        XCTAssertEqual(preview.owners, [docs.id: docs.pid, todo.id: todo.pid])
        XCTAssertEqual(preview.focused, todo.id)
        XCTAssertEqual(preview.screen, CGSize(width: 1440, height: 900))
        XCTAssertEqual(preview.usable, CGRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(preview.display.name, "Built-in Display")
        XCTAssertEqual(mac.wm.tiledWindowCount, 2)

        // With the focus on a window that has no tile, the tile last used is the one marked.
        let sums = openDialog("Calculator", "Sums", frame: CGRect(x: 500, y: 300, width: 300, height: 200))
        XCTAssertEqual(mac.focused, sums.id)
        XCTAssertEqual(mac.wm.desktopPreview()?.focused, todo.id)
        XCTAssertEqual(mac.wm.desktopPreview()?.visible, [docs.id, todo.id])

        mac.system.minimise(todo)
        mac.settle()
        XCTAssertNil(mac.wm.desktopPreview(), "one tiled window on screen again")
    }

    // MARK: Where a window is

    func testWhereAWindowIs() {
        let studio = addStudio()
        mac.system.showDesktop(3)
        mac.settle()
        let zsh = open("Terminal", "zsh", frame: onStudio)
        mac.system.showDesktop(2)
        mac.settle()
        let todo = open("Notes", "Todo", frame: onStudio)
        let docs = open("Safari", "Docs")

        func place(_ window: FakeWindow, frame: CGRect?) -> String {
            let place = mac.wm.place(of: window.id, frame: frame)
            return "\(place.desktop.map(String.init) ?? "-") \(place.display ?? "-")"
        }
        XCTAssertEqual(place(docs, frame: docs.rect), "1 Built-in Display")
        XCTAssertEqual(place(todo, frame: todo.rect), "2 Studio Display")
        XCTAssertEqual(place(zsh, frame: nil), "3 Studio Display", "not on screen: its desktop says which display")
        XCTAssertEqual(place(docs, frame: nil), "1 Built-in Display")
        XCTAssertEqual(mac.wm.place(of: 9999, frame: nil).desktop, nil, "a window nobody knows is nowhere")
        XCTAssertEqual(mac.wm.place(of: 9999, frame: nil).display, nil)

        // A window assigned to all desktops is on the one being shown.
        todo.spaces = Set(studio.spaces.map(\.id))
        XCTAssertEqual(place(todo, frame: todo.rect), "2 Studio Display")
        mac.system.showDesktop(3)
        mac.settle()
        XCTAssertEqual(place(todo, frame: todo.rect), "3 Studio Display")

        // A window in native fullscreen is on a Space that is not a desktop.
        let fullscreen = mac.system.addFullscreenSpace(to: studio)
        mac.system.put(zsh, on: fullscreen)
        mac.system.show(fullscreen, on: studio)
        mac.settle()
        XCTAssertEqual(place(zsh, frame: nil), "- Studio Display")
    }

    func testAWindowOnItsWayHasADestination() {
        let docs = open("Safari", "Docs")
        XCTAssertNil(mac.wm.motion(of: docs.id), "at rest")

        // Tiling resumes with a second window open: the layout is applied there and then.
        XCTAssertEqual(mac.run("pause"), "ok: paused")
        let todo = open("Notes", "Todo")
        XCTAssertEqual(mac.wm.run(.pause), "ok: tiling")

        let left = CGRect(x: 8, y: 33, width: 708, height: 859), right = CGRect(x: 724, y: 33, width: 708, height: 859)
        XCTAssertEqual(mac.wm.motion(of: docs.id)?.to, left, "where the focus ring should go to meet it")
        XCTAssertEqual(mac.wm.motion(of: todo.id)?.to, right)
        XCTAssertEqual(mac.wm.motion(of: docs.id)?.gliding, false)
        XCTAssertNil(mac.wm.motion(of: 9999))

        mac.settle()
        XCTAssertNil(mac.wm.motion(of: docs.id), "arrived")
        XCTAssertNil(mac.wm.motion(of: todo.id))
        XCTAssertFrame(docs.rect, left)
    }

    // MARK: The log

    func testWhatIsLoggedGoesToTheSinkAndNowhereElse() throws {
        XCTAssertEqual(mac.log, ["config: ok: no config file at \(mac.configURL.path), using the built-in defaults (`iguana config init` writes one)"],
                       "what starting up had to say")

        Log.write("a line from a test")
        XCTAssertEqual(mac.log.last, "a line from a test", "the line as it was written, without a date")
        XCTAssertEqual(mac.logged("from a test").count, 1)

        // The window manager logs through the same door.
        mac.writeConfig("[gaps]\ninner = 4\n")
        XCTAssertEqual(mac.log.last, "config: ok: loaded \(mac.configURL.path)")
        mac.writeConfig("[gaps]\ninner = 4\n")
        XCTAssertEqual(mac.log.count, 3, "the same answer twice in a row is logged once")

        // Without a sink, a test run writes nowhere.
        XCTAssertTrue(Iguana.isUnderTest)
        XCTAssertEqual(Log.url.lastPathComponent, "Iguana.log")
        let marker = "iguana-test-\(UUID().uuidString)"

        // The log file belongs to the Iguana in use, and so does what goes to standard error
        // with it. Catch standard error for a moment: the two are written together or not at all.
        let pipe = Pipe()
        let stderrCopy = dup(STDERR_FILENO)
        fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        Log.sink = nil
        Log.write(marker)
        fflush(stderr)
        dup2(stderrCopy, STDERR_FILENO)
        close(stderrCopy)
        try pipe.fileHandleForWriting.close()
        let caught = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertFalse(caught.contains(marker), "the line went nowhere")
        XCTAssertEqual(mac.log.count, 3)
    }
}

/// The other end of the connection of an `iguana subscribe` client: a pair of sockets inside
/// this process, so no command is run and nothing leaves the test.
private final class Listener {
    let subscriber: IPC.Subscriber
    private let fd: Int32
    private var buffer = ""

    init(_ events: Set<HookEvent> = Set(HookEvent.allCases)) {
        var pair: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        fd = pair[0]
        // A line that never comes fails the test instead of hanging it.
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        subscriber = IPC.subscribe(pair[1], to: events)
    }

    deinit { close(fd) }

    /// Every line the subscriber has been sent since the last call. The subscriber writes in
    /// the order it was told, so a line of the test's own marks the end: this waits for
    /// exactly that line and for no length of time.
    func heard() -> [String] {
        let end = EventStream.line(["IGUANA_EVENT": "that-is-all"])
        subscriber.send(subscriber.events.first!, ["IGUANA_EVENT": "that-is-all"])
        var lines: [String] = []
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line == end { return lines }
                lines.append(line)
            }
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else {
                XCTFail("the subscriber's connection ended or said nothing; heard \(lines)")
                return lines
            }
            buffer += String(decoding: bytes[..<count], as: UTF8.self)
        }
    }
}

/// The events of `[hooks]` as a subscriber hears them, with the real window manager making
/// them happen. No hook command is set, so no shell is ever started.
final class HookEventScenarioTests: NamedWindowsTestCase {
    private var hooks: Hooks!
    private var listener: Listener!

    override func setUp() {
        super.setUp()
        hooks = Hooks()
        listener = Listener()
    }

    override func tearDown() {
        IPC.endSubscriptions()
        listener = nil
        hooks = nil
        super.tearDown()
    }

    /// Tell the hooks after every look, as the app does.
    func connect() {
        mac.wm.onChange = { [unowned self] in hooks.changed(mac.wm) }
    }

    func testASubscriberIsToldWhatIsTrueNow() {
        let docs = open("Safari", "Docs")
        hooks.greet(listener.subscriber, mac.wm)
        XCTAssertEqual(listener.heard(), [], "before the first look there is nothing to tell")

        // The first look: everyone who is waiting is told where things stand.
        hooks.changed(mac.wm)
        let now = [
            #"{"desktop":1,"display":"Built-in Display","event":"desktop-changed"}"#,
            #"{"desktop":1,"display":"Built-in Display","event":"layout-changed"}"#,
            #"{"event":"pause-changed","paused":false}"#,
            #"{"app":"Safari","desktop":1,"display":"Built-in Display","event":"focus-changed","title":"Docs","window-id":\#(docs.id)}"#,
        ]
        XCTAssertEqual(listener.heard(), now)

        // One who comes later is told the same, and only what it asked for.
        hooks.greet(listener.subscriber, mac.wm)
        XCTAssertEqual(listener.heard(), now)
        let focusOnly = Listener([.focusChanged])
        hooks.greet(focusOnly.subscriber, mac.wm)
        XCTAssertEqual(focusOnly.heard(), [now[3]])
    }

    func testASubscriberIsToldWhereTheUserIsWhenNoWindowHasTheFocus() {
        let studio = mac.system.addDisplay("Studio Display", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440))
        mac.system.show(mac.system.addFullscreenSpace(to: studio), on: studio)
        mac.settle()
        XCTAssertEqual(mac.run("pause"), "ok: paused")
        hooks.changed(mac.wm)

        XCTAssertEqual(listener.heard(), [
            #"{"desktop":1,"display":"Built-in Display","event":"desktop-changed"}"#,
            #"{"desktop":null,"display":"Studio Display","event":"desktop-changed"}"#,
            #"{"desktop":1,"display":"Built-in Display","event":"layout-changed"}"#,
            #"{"event":"pause-changed","paused":true}"#,
            #"{"app":null,"desktop":1,"display":"Built-in Display","event":"focus-changed","title":null,"window-id":null}"#,
        ], "a fullscreen Space is no desktop and has no layout")
    }

    func testSubscribersHearWhatHappens() {
        mac.system.addDesktop(to: mac.system.displayList[0])
        let docs = open("Safari", "Docs")
        connect()
        hooks.changed(mac.wm)
        _ = listener.heard()

        let todo = open("Notes", "Todo")
        XCTAssertEqual(listener.heard(), [
            #"{"app":"Notes","desktop":1,"display":"Built-in Display","event":"window-created","title":"Todo","window-id":\#(todo.id)}"#,
            #"{"desktop":1,"display":"Built-in Display","event":"layout-changed"}"#,
            #"{"app":"Notes","desktop":1,"display":"Built-in Display","event":"focus-changed","title":"Todo","window-id":\#(todo.id)}"#,
        ], "a window opened, the desktop was arranged around it, and it has the focus")

        XCTAssertEqual(mac.run("move left"), "ok")
        XCTAssertEqual(listener.heard(), [#"{"desktop":1,"display":"Built-in Display","event":"layout-changed"}"#])

        XCTAssertEqual(mac.run("pause"), "ok: paused")
        XCTAssertEqual(listener.heard(), [#"{"event":"pause-changed","paused":true}"#])
        XCTAssertEqual(mac.run("pause"), "ok: tiling")
        XCTAssertEqual(listener.heard(), [
            #"{"event":"pause-changed","paused":false}"#,
            #"{"desktop":1,"display":"Built-in Display","event":"layout-changed"}"#,
        ], "resuming arranges the desktop again")

        // The title a closing window had when it was last looked at is the one that is told.
        todo.title = "Shopping"
        mac.wm.scheduleRefresh()
        mac.settle()
        XCTAssertEqual(listener.heard(), [])
        mac.system.close(todo)
        mac.settle()
        XCTAssertEqual(listener.heard(), [
            #"{"app":"Notes","desktop":1,"display":"Built-in Display","event":"window-closed","title":"Shopping","window-id":\#(todo.id)}"#,
            #"{"desktop":1,"display":"Built-in Display","event":"layout-changed"}"#,
            #"{"app":"Safari","desktop":1,"display":"Built-in Display","event":"focus-changed","title":"Docs","window-id":\#(docs.id)}"#,
        ])

        mac.system.showDesktop(2)
        mac.settle()
        XCTAssertEqual(listener.heard(), [
            #"{"desktop":2,"display":"Built-in Display","event":"desktop-changed"}"#,
            #"{"app":null,"desktop":2,"display":"Built-in Display","event":"focus-changed","title":null,"window-id":null}"#,
        ], "an empty desktop: no window has the focus, and that is said with where the user is")
    }
}
