import Foundation
import IguanaCore

/// The clients of `iguana subscribe`. Each is a connection that stays open and is written a
/// line of JSON for every event it asked for, until it goes or Iguana quits.
extension IPC {
    /// Main queue only.
    private(set) static var subscribers: [Subscriber] = []

    /// Whether anyone listens for this event, so that its facts are worth working out.
    static func wants(_ event: HookEvent) -> Bool { subscribers.contains { $0.events.contains(event) } }

    /// Main queue. Returns at once, however slowly the subscribers read.
    static func broadcast(_ event: HookEvent, _ variables: [String: String]) {
        for subscriber in subscribers { subscriber.send(event, variables) }
    }

    /// Main queue. Takes over a connection whose request was `subscribe`.
    static func subscribe(_ fd: Int32, to events: Set<HookEvent>) -> Subscriber {
        let subscriber = Subscriber(fd, events: events)
        subscribers.append(subscriber)
        return subscriber
    }

    /// Main queue. Iguana is quitting: every subscriber sees the end of its stream.
    static func endSubscriptions() {
        for subscriber in subscribers { subscriber.finish() }
        subscribers = []
    }

    /// The main queue only hands lines over. They are written on a queue of the subscriber's
    /// own, so a status bar that is slow to read never holds Iguana up, and one that stops
    /// reading is let go once `backlog` lines wait for it instead of piling them up.
    final class Subscriber {
        static let backlog = 256

        let events: Set<HookEvent>
        private let fd: Int32
        private let queue: DispatchQueue
        /// Notices that the client has gone, without waiting for the next event.
        private let reader: DispatchSourceRead
        private let lock = NSLock()
        /// Under `lock`. Once `ending` is set nothing more is written. `open` stays set until
        /// the socket is closed, which only happens on `queue`, so no write can meet a closed
        /// socket, or another file that was given its number.
        private var ending = false, open = true, waiting = 0

        init(_ fd: Int32, events: Set<HookEvent>) {
            self.fd = fd
            self.events = events
            queue = DispatchQueue(label: "xyz.onlychan.iguana.subscriber", qos: .utility)
            reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            var on: Int32 = 1
            // A status bar that has gone must never be able to stop Iguana with SIGPIPE.
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // The time limit was for reading the request. From now on the socket is read only
            // when there is something to read.
            var never = timeval()
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &never, socklen_t(MemoryLayout<timeval>.size))
            reader.setEventHandler { [weak self] in
                // A client sends nothing after its request, so this is the end of the connection.
                var buffer = [UInt8](repeating: 0, count: 512)
                if read(fd, &buffer, buffer.count) <= 0 { self?.finish() }
            }
            // Holds on to the subscriber until it has run; then the system lets go of it.
            reader.setCancelHandler { [self] in
                lock.lock()
                open = false
                close(fd)
                lock.unlock()
                DispatchQueue.main.async { IPC.subscribers.removeAll { $0 === self } }
            }
            reader.resume()
        }

        /// Main queue. Nothing is sent for an event the client did not ask for.
        func send(_ event: HookEvent, _ variables: [String: String]) {
            guard events.contains(event) else { return }
            let line = EventStream.line(variables) + "\n"
            lock.lock()
            let full = waiting >= Self.backlog, write = !ending && !full
            if write { waiting += 1 }
            lock.unlock()
            if full { finish() }
            guard write else { return }
            queue.async { [self] in
                lock.lock()
                let stopped = ending
                lock.unlock()
                if !stopped, !IPC.writeAll(fd, line) { finish() }
                lock.lock()
                waiting -= 1
                lock.unlock()
            }
        }

        /// Any thread. Ends the stream: a write that waits for a client that stopped reading
        /// is woken, and the socket is closed once nothing uses it.
        func finish() {
            lock.lock()
            let first = !ending
            ending = true
            if open { shutdown(fd, SHUT_RDWR) }
            lock.unlock()
            if first { reader.cancel() }
        }
    }
}
