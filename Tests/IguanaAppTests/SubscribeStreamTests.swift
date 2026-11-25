import XCTest
import IguanaCore
@testable import iguana

/// The stream of `iguana subscribe`, on a socket of the test's own: real connections, with the
/// events played by the test.
final class SubscribeStreamTests: XCTestCase {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ig-sub-\(getpid())")
    var joined: [IPC.Subscriber] = []
    /// What a new subscriber is sent first, as the app sends it the current state.
    var greet: (IPC.Subscriber) -> Void = { _ in }

    override func setUp() {
        // Never the socket of the Iguana that is running on this Mac.
        IPC.socketPathOverride = Self.folder.appendingPathComponent("test.sock").path
        joined = []
        greet = { _ in }
        XCTAssertTrue(IPC.listen({ line, reply in reply("ok: \(line)") }, subscribed: { [unowned self] subscriber in
            self.joined.append(subscriber)
            self.greet(subscriber)
        }))
    }

    override func tearDown() {
        IPC.stop()
        try? FileManager.default.removeItem(at: Self.folder)
    }

    /// The server works on the main queue, so waiting means letting the main run loop turn.
    @discardableResult
    func wait(_ seconds: TimeInterval = 5, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return done()
    }

    /// `iguana subscribe` as the command line runs it, on a thread of its own.
    final class Listener {
        private let lock = NSLock()
        private var got: [String] = []
        private var result: Bool?

        init(_ command: String) {
            Thread.detachNewThread { [self] in
                let connected = IPC.stream(command) { line in
                    lock.lock()
                    got.append(line)
                    lock.unlock()
                }
                lock.lock()
                result = connected
                lock.unlock()
            }
        }

        var lines: [String] { lock.lock(); defer { lock.unlock() }; return got }
        /// Nil while the stream goes on; then whether it was connected.
        var ended: Bool? { lock.lock(); defer { lock.unlock() }; return result }
    }

    func desktop(_ n: Int) -> [String: String] { HookEnvironment.variables(event: .desktopChanged, desktop: n, display: "Studio Display") }
    func focus(_ id: WindowID, title: String = "Notes") -> [String: String] {
        HookEnvironment.variables(event: .focusChanged, desktop: 1, display: "Studio Display", window: (id, "Notes", title))
    }

    /// A connection that asks to subscribe and then does nothing at all, not even read.
    func silentSubscriber() throws -> Int32 {
        let fd = try XCTUnwrap(IPC.connection())
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        XCTAssertTrue(IPC.writeAll(fd, "subscribe\n"))
        return fd
    }

    func testASubscriberHearsTheEventsItAskedForInOrderUntilIguanaQuits() {
        greet = { [unowned self] subscriber in
            subscriber.send(.desktopChanged, desktop(1))
            subscriber.send(.focusChanged, focus(0))
        }
        let everything = Listener("subscribe"), focusOnly = Listener("subscribe focus-changed")
        XCTAssertTrue(wait { joined.count == 2 }, "both joined")

        var all = [EventStream.line(desktop(1)), EventStream.line(focus(0))]
        var focusLines = [EventStream.line(focus(0))]
        for n in 1...100 {
            IPC.broadcast(.desktopChanged, desktop(n))
            IPC.broadcast(.focusChanged, focus(WindowID(n), title: "note \(n)"))
            all += [EventStream.line(desktop(n)), EventStream.line(focus(WindowID(n), title: "note \(n)"))]
            focusLines.append(EventStream.line(focus(WindowID(n), title: "note \(n)")))
        }
        XCTAssertTrue(wait { everything.lines.count >= all.count && focusOnly.lines.count >= focusLines.count })
        XCTAssertEqual(everything.lines, all, "the current state first, then every event as it came")
        XCTAssertEqual(focusOnly.lines, focusLines, "only the events asked for")
        XCTAssertNil(everything.ended, "still listening")

        IPC.stop()
        XCTAssertTrue(wait { everything.ended != nil && focusOnly.ended != nil }, "quitting ends every stream")
        XCTAssertEqual(everything.ended, true)
        XCTAssertTrue(IPC.subscribers.isEmpty)
    }

    func testASubscriberThatGoesIsDroppedAndCannotHurtIguana() throws {
        let first = try silentSubscriber()
        XCTAssertTrue(wait { joined.count == 1 })
        close(first)
        XCTAssertTrue(wait { IPC.subscribers.isEmpty }, "noticed without waiting for an event")

        // Over and over, so that some events reach a client that has just gone: with no
        // SO_NOSIGPIPE that would end this process.
        for round in 2...20 {
            let fd = try silentSubscriber()
            XCTAssertTrue(wait { joined.count == round })
            close(fd)
            for n in 1...5 { IPC.broadcast(.desktopChanged, desktop(n)) }
            XCTAssertTrue(wait { IPC.subscribers.isEmpty })
        }
        let started = Date()
        for n in 1...100 { IPC.broadcast(.focusChanged, focus(WindowID(n))) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)

        // The next one is served as if nothing had happened.
        let next = Listener("subscribe")
        XCTAssertTrue(wait { joined.count == 21 })
        IPC.broadcast(.desktopChanged, desktop(7))
        XCTAssertTrue(wait { next.lines == [EventStream.line(desktop(7))] })
    }

    func testASubscriberThatStopsReadingIsLetGoAndNeverHoldsIguanaUp() throws {
        let fd = try silentSubscriber()
        defer { close(fd) }
        XCTAssertTrue(wait { joined.count == 1 })

        // Long titles fill the socket at once, and the rest wait in the subscriber's backlog.
        let title = String(repeating: "x", count: 4000)
        let sent = IPC.Subscriber.backlog * 2
        let started = Date()
        for n in 1...sent { IPC.broadcast(.focusChanged, focus(WindowID(n), title: title)) }
        // Waiting for a subscriber that does not read would mean waiting for ever. The limit is
        // loose so that a Mac busy with something else does not fail this.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the main queue never waits for a subscriber")
        XCTAssertTrue(wait { IPC.subscribers.isEmpty }, "let go once its backlog was full")

        // What reached it before that, and then the end of the stream.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertLessThan(lines.count, sent)
        XCTAssertEqual(String(lines[0]), EventStream.line(focus(1, title: title)))
    }

    func testEveryOtherRequestStillGetsItsOneReply() {
        let listener = Listener("subscribe desktop-changed")
        XCTAssertTrue(wait { joined.count == 1 })

        var replies: [String?] = []
        let done = expectation(description: "replied")
        DispatchQueue.global().async {
            let got = ["status", "subscribe window-moved", "focus left"].map { IPC.send($0) }
            DispatchQueue.main.async {
                replies = got
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(replies, ["ok: status\n", "ok: subscribe window-moved\n", "ok: focus left\n"],
                       "a subscribe that does not parse is answered like any other mistake")
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(IPC.subscribers.count, 1)
        XCTAssertEqual(listener.lines, [])
    }
}
