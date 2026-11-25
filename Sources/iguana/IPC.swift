import Foundation
import IguanaCore

/// The command line talks to the running app over a socket in the user's own Library folder:
/// one line in, one reply out. `subscribe` is the exception: its connection stays open, and
/// the app writes a line to it for each event (see Subscribers.swift).
enum IPC {
    static var socketPath: String { socketPathOverride ?? WindowManager.supportDirectory.appendingPathComponent("iguana.sock").path }
    /// A test listens on a socket of its own, so that it never touches the one a running
    /// Iguana answers on.
    static var socketPathOverride: String?

    private static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        return addr
    }

    private static func withSockaddr<T>(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = addr
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// False when the other end has gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ text: String) -> Bool {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private static func readAll(_ fd: Int32, untilNewline: Bool) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if untilNewline, data.contains(0x0a) { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Client

    /// A connection to the running app, or nil when nothing is listening.
    static func connection() -> Int32? {
        guard let addr = address() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withSockaddr(addr, { connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Send one command to the running app. Returns nil when nothing is listening.
    static func send(_ command: String) -> String? {
        guard let fd = connection() else { return nil }
        defer { close(fd) }
        writeAll(fd, command + "\n")
        return readAll(fd, untilNewline: false)
    }

    /// Send `subscribe` and hand over each line the app writes back, as it arrives, until the
    /// app closes the connection. Returns false when nothing is listening.
    static func stream(_ command: String, _ each: (String) -> Void) -> Bool {
        guard let fd = connection() else { return false }
        defer { close(fd) }
        writeAll(fd, command + "\n")
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(buffer, count: n)
            while let end = pending.firstIndex(of: 0x0a) {
                each(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        if !pending.isEmpty { each(String(decoding: pending, as: UTF8.self)) }
        return true
    }

    // MARK: Server

    private static var source: DispatchSourceRead?

    /// The reply to one command, on its way from the main queue to the thread that writes it
    /// back. Most commands answer at once; one that has to wait for something (`update` waits
    /// for GitHub) answers when it can, and the main queue is free in the meantime.
    final class Answer {
        private let given = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var text: String?

        /// Only the first reply counts.
        func give(_ reply: String) {
            lock.lock()
            let first = text == nil
            if first { text = reply }
            lock.unlock()
            if first { given.signal() }
        }

        func wait() -> String {
            given.wait()
            lock.lock()
            defer { lock.unlock() }
            return text ?? ""
        }
    }

    /// `handler` runs on the main queue. It answers by calling what it is given, once, at once
    /// or later, from any thread. A `subscribe` request is not handed to it: its connection
    /// becomes a subscriber, given to `subscribed` on the main queue to be sent the current state.
    static func listen(_ handler: @escaping (String, @escaping (String) -> Void) -> Void,
                       subscribed: @escaping (Subscriber) -> Void = { _ in }) -> Bool {
        guard let addr = address() else { return false }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        guard withSockaddr(addr, { bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return false
        }
        chmod(socketPath, 0o600)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async {
                let line = readAll(client, untilNewline: true).trimmingCharacters(in: .whitespacesAndNewlines)
                if case .subscribe(let events)? = try? Command.parse(line) {
                    DispatchQueue.main.async {
                        // Iguana stopped listening while the request was read.
                        guard source != nil else {
                            close(client)
                            return
                        }
                        subscribed(subscribe(client, to: events))
                    }
                    return
                }
                let answer = Answer()
                DispatchQueue.main.async { handler(line, answer.give) }
                writeAll(client, answer.wait() + "\n")
                close(client)
            }
        }
        src.resume()
        source = src
        return true
    }

    static func stop() {
        endSubscriptions()
        source?.cancel()
        source = nil
        unlink(socketPath)
    }
}
