import AppKit
import IguanaCore
import Security

/// What an unpacked app must satisfy before it may take the place of the running one. This is
/// the whole of the trust in an update: where the zip came from counts for nothing, and a zip
/// from anywhere is acceptable if and only if the app in it passes both.
struct UpdateTrust {
    /// The designated requirement of the app that is running. macOS uses the same one to
    /// decide that an app is still the app that was given the Accessibility permission, so
    /// what passes here keeps the permission, and what does not would never have had it.
    let sameApp: SecRequirement
    /// Apple has seen this very build and issued a ticket for it.
    let notarized: SecRequirement

    init(sameApp: SecRequirement, notarized: SecRequirement) {
        self.sameApp = sameApp
        self.notarized = notarized
    }

    /// From the text of two requirements. A test names its own here, because the process a
    /// test runs in is the test runner and not Iguana.
    init(sameApp: String, notarized: String = "notarized") throws {
        self.init(sameApp: try Self.requirement(sameApp), notarized: try Self.requirement(notarized))
    }

    static func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw UpdateFailure("macOS could not read the requirement \"\(text)\" (\(MacUpdateSteps.words(for: status)))")
        }
        return requirement
    }

    /// What the running Iguana asks of its successor.
    static func ofRunningApp() throws -> UpdateTrust {
        var running: SecCode?
        var status = SecCodeCopySelf([], &running)
        guard status == errSecSuccess, let running else {
            throw UpdateFailure("macOS would not say how the running Iguana is signed (\(MacUpdateSteps.words(for: status)))")
        }
        var onDisk: SecStaticCode?
        status = SecCodeCopyStaticCode(running, [], &onDisk)
        guard status == errSecSuccess, let onDisk else {
            throw UpdateFailure("macOS could not find the running Iguana on disk (\(MacUpdateSteps.words(for: status)))")
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(onDisk, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw UpdateFailure("the running Iguana has no requirement to check a download against (\(MacUpdateSteps.words(for: status)))")
        }
        // The requirement was read from the app on disk. The process itself, as the system
        // knows it, must satisfy it too, or the app on disk is no longer the one that is running.
        status = SecCodeCheckValidity(running, [], requirement)
        guard status == errSecSuccess else {
            throw UpdateFailure("the running Iguana does not match its own signature (\(MacUpdateSteps.words(for: status)))")
        }
        return UpdateTrust(sameApp: requirement, notarized: try Self.requirement("notarized"))
    }
}

/// The steps of an install, on the Mac. Each is a function of the paths it is handed, so a
/// test can run it for real on throwaway apps in a temporary folder.
///
/// Nothing here asks for an administrator's rights. What the current user may not replace is
/// refused before anything is downloaded.
final class MacUpdateSteps: UpdateSteps {
    private let bundle: URL
    private let version: String
    private let trust: () throws -> UpdateTrust
    /// A test answers in the server's place through these, so no test touches the network.
    private let protocols: [AnyClass]?
    private let limit: Int64

    init(bundle: URL = Bundle.main.bundleURL, version: String = Iguana.version,
         trust: @escaping () throws -> UpdateTrust = UpdateTrust.ofRunningApp, protocols: [AnyClass]? = nil,
         limit: Int64 = UpdateInstall.largestDownload) {
        self.bundle = bundle
        self.version = version
        self.trust = trust
        self.protocols = protocols
        self.limit = limit
    }

    static func words(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }

    // MARK: 1. The facts for "may it?"

    func facts() -> UpdateInstall.Facts {
        // The real folder, so that it is the app that gets replaced and not a link to it.
        let bundle = bundle.resolvingSymlinksInPath()
        let signature = Self.runningSignature()
        let files = FileManager.default
        return UpdateInstall.Facts(bundlePath: bundle.path, teamIdentifier: signature.team, adHoc: signature.adHoc,
                                   folderWritable: files.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
                                   bundleWritable: files.isWritableFile(atPath: bundle.path), running: version)
    }

    /// The team that signed the process this is, and whether it is signed without an identity.
    /// No team when the process no longer matches its signature: then nothing it says counts.
    static func runningSignature() -> (team: String?, adHoc: Bool) {
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess else { return (nil, false) }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &onDisk) == errSecSuccess, let onDisk else { return (nil, false) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let facts = information as? [String: Any] else { return (nil, false) }
        let flags = (facts[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return (facts[kSecCodeInfoTeamIdentifier as String] as? String, flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
    }

    // MARK: The workspace

    /// A folder only this user can read, on the volume the app is on: the swap is one move
    /// only when the new app and the old one are on the same volume.
    func makeWorkspace(for bundle: URL) throws -> URL {
        let files = FileManager.default
        let folder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
        do {
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let here = try folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
            let there = try bundle.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
            guard let here, let there, here.isEqual(there) else {
                throw UpdateFailure("macOS gave a temporary folder on another volume than the app's")
            }
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
        return folder
    }

    func remove(_ workspace: URL) {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: 2. Download

    /// One `GET` for the zip, made as the update check is made: no cookies, no cache, no
    /// credentials, and Iguana's name and version as all it says about itself.
    static func request(_ url: URL, version: String = Iguana.version) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: UpdateInstall.silenceTimeout)
        request.httpShouldHandleCookies = false
        request.setValue(UpdateCheck.userAgent(version: version), forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        // Left alone, the system fills this in with the languages chosen in System Settings.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    func download(_ url: URL, to file: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        // The test suite never reaches the network, even if a test forgets to stand in for the server.
        guard !Iguana.isUnderTest || protocols != nil else {
            return completion(.failure(UpdateFailure("a test may not download from the network")))
        }
        let configuration = UpdateChecker.configuration(silence: UpdateInstall.silenceTimeout, whole: UpdateInstall.downloadTimeout,
                                                        protocols: protocols)
        // A session for this one download, so nothing carries over to the next.
        let session = URLSession(configuration: configuration, delegate: Download(file: file, limit: limit, completion: completion),
                                 delegateQueue: nil)
        session.downloadTask(with: Self.request(url, version: version)).resume()
        session.finishTasksAndInvalidate()
    }

    /// Watches one download: where it is sent on to, what the answer is, and how much arrives.
    private final class Download: NSObject, URLSessionDownloadDelegate {
        private let file: URL
        private let limit: Int64
        private let completion: (Result<Void, Error>) -> Void
        /// Why the download is not kept. The first reason stands.
        private var problem: String?
        private var kept = false

        init(file: URL, limit: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
            self.file = file
            self.limit = limit
            self.completion = completion
        }

        private func refuse(_ reason: String, _ task: URLSessionTask) {
            if problem == nil { problem = reason }
            task.cancel()
        }

        /// A redirect that is not followed comes back as the answer, and its status is the failure.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let allowed = request.url.map(UpdateInstall.allowsRedirect(to:)) ?? false
            if !allowed, problem == nil { problem = "the download was sent on to an address that is not https" }
            completionHandler(allowed ? request : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            // What the server says is coming, and then what really came: a server can say
            // anything, or nothing.
            if let answer = downloadTask.response as? HTTPURLResponse,
               let reason = UpdateInstall.downloadProblem(status: answer.statusCode, expectedLength: totalBytesExpectedToWrite, limit: limit) {
                refuse(reason, downloadTask)
            } else if totalBytesWritten > limit {
                refuse(UpdateInstall.tooLarge(limit: limit), downloadTask)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard problem == nil else { return }
            guard let answer = downloadTask.response as? HTTPURLResponse else {
                problem = "the server gave no answer"
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let reason = UpdateInstall.downloadProblem(status: answer.statusCode, expectedLength: size, limit: limit) {
                problem = reason
                return
            }
            // The system removes its own file when this returns, so it is moved now.
            do {
                try FileManager.default.moveItem(at: location, to: file)
                kept = true
            } catch {
                problem = "the download could not be kept (\(error.localizedDescription))"
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let problem {
                completion(.failure(UpdateFailure(problem)))
            } else if let error {
                completion(.failure(error))
            } else if kept {
                completion(.success(()))
            } else {
                completion(.failure(UpdateFailure("nothing was downloaded")))
            }
        }
    }

    // MARK: 3. Unpack

    func unpack(_ zip: URL, into folder: URL) throws -> URL {
        // New, and readable by this user only. A folder that is there already is not used.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        let complaints = Pipe()
        ditto.standardInput = FileHandle.nullDevice
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = complaints
        try ditto.run()
        let said = String(decoding: complaints.fileHandleForReading.readDataToEndOfFile().prefix(300), as: UTF8.self)
        ditto.waitUntilExit()
        guard ditto.terminationReason == .exit, ditto.terminationStatus == 0 else {
            let why = said.split(separator: "\n").last.map(String.init) ?? "status \(ditto.terminationStatus)"
            throw UpdateFailure("the download could not be unpacked (\(why))")
        }
        return try Self.bundle(in: folder)
    }

    /// The app a release's zip unpacks to: `Iguana.app`, a real folder, and nothing beside it.
    static func bundle(in folder: URL) throws -> URL {
        let found = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        guard found == [UpdateInstall.bundleName] else {
            let listed = found.isEmpty ? "nothing" : found.prefix(4).joined(separator: ", ")
            throw UpdateFailure("the download holds \(listed), where a release holds \(UpdateInstall.bundleName) and nothing else")
        }
        let bundle = folder.appendingPathComponent(UpdateInstall.bundleName)
        // Asked of the item itself, not of what it points to. A link in the app's place would
        // have the signature checked in one folder and another folder moved into place.
        let type = try FileManager.default.attributesOfItem(atPath: bundle.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else {
            throw UpdateFailure("\(UpdateInstall.bundleName) in the download is not a folder")
        }
        return bundle
    }

    // MARK: 4. Verify

    /// Everything is checked: every architecture, the code nested in the app, every sealed
    /// file, and that nothing in the app is a link out of it or carries data beside its files.
    static let validation = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        | kSecCSRestrictSymlinks | kSecCSRestrictToAppLike | kSecCSRestrictSidebandData)

    func verify(_ bundle: URL, version: String) throws {
        try Self.verify(bundle, version: version, trust: try trust())
    }

    /// Throws unless the app at `bundle` satisfies both requirements of `trust` and is Iguana
    /// `version`. The system's code signing does the checking; nothing is taken on the word of
    /// a checksum or of a tool's output.
    static func verify(_ bundle: URL, version: String, trust: UpdateTrust, identifier: String = UpdateInstall.bundleIdentifier) throws {
        var unpacked: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &unpacked)
        guard status == errSecSuccess, let unpacked else {
            throw UpdateFailure("the download is not an app macOS can read (\(words(for: status)))")
        }
        if let why = failure(of: unpacked, against: trust.sameApp) {
            throw UpdateFailure("the download is not signed as the Iguana that is running (\(why))")
        }
        if let why = failure(of: unpacked, against: trust.notarized) {
            throw UpdateFailure("the download is not notarized by Apple (\(why))")
        }
        // The Info.plist as the signature that was just checked seals it, not a second
        // reading of a file that could have been changed in between.
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(unpacked, [], &information) == errSecSuccess,
              let plist = (information as? [String: Any])?[kSecCodeInfoPList as String] as? [String: Any] else {
            throw UpdateFailure("the download has no Info.plist under its signature")
        }
        let name = plist["CFBundleIdentifier"] as? String
        guard name == identifier else {
            throw UpdateFailure("the download is not Iguana: it calls itself \(String((name ?? "nothing").prefix(80)))")
        }
        let found = plist["CFBundleShortVersionString"] as? String
        guard UpdateInstall.isVersion(found, version) else {
            throw UpdateFailure("the download is Iguana \(String((found ?? "of no version").prefix(40))), not Iguana \(version)")
        }
    }

    /// Why `code` does not satisfy `requirement`, or nil when it does.
    private static func failure(of code: SecStaticCode, against requirement: SecRequirement) -> String? {
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, validation, requirement, &error)
        // The error only repeats the status as a number. It is taken so that it is released.
        error?.release()
        return status == errSecSuccess ? nil : words(for: status)
    }

    // MARK: 5. Swap

    func swap(_ installed: URL, with fresh: URL) throws {
        try Self.swap(installed, with: fresh)
    }

    /// Puts `fresh` where `installed` is, in one move on one volume. When it cannot, the old
    /// app is where it was: there is no moment at which the path holds half an app.
    static func swap(_ installed: URL, with fresh: URL) throws {
        let files = FileManager.default
        // The app that is in use on this Mac is never a test's to replace.
        guard !Iguana.isUnderTest || !installed.standardizedFileURL.path.hasPrefix("/Applications/") else {
            throw UpdateFailure("a test may not replace an app in /Applications")
        }
        for (url, what) in [(installed, "the app to replace"), (fresh, "the new app")] {
            guard (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else {
                throw UpdateFailure("\(what) is not a folder at \(url.path)")
            }
        }
        do {
            _ = try files.replaceItemAt(installed, withItemAt: fresh, backupItemName: nil, options: [])
        } catch {
            // A replacement that fails part of the way says where it left the old app. The
            // key has no constant: Foundation documents it by this name.
            if !files.fileExists(atPath: installed.path),
               let aside = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL {
                try? files.moveItem(at: aside, to: installed)
            }
            throw UpdateFailure("the new app could not be put in the place of the old one (\(error.localizedDescription))")
        }
    }

    // MARK: 6. Restart

    /// Waits for the process `$1` to end, then opens the app `$2`. Both are arguments: the
    /// path is never part of the text the shell reads, so nothing in a path can be run. After
    /// half a minute it gives up, and opens nothing while the old Iguana is still there.
    static let relaunchScript = """
    n=0
    while kill -0 "$1" 2>/dev/null && [ "$n" -lt 150 ]; do /bin/sleep 0.2; n=$((n + 1)); done
    kill -0 "$1" 2>/dev/null || exec /usr/bin/open "$2"
    """

    /// The shell that outlives this process and starts the new app. Made here and not run, so
    /// a test can look at what it would be handed.
    static func relaunchProcess(bundle: URL, pid: pid_t) throws -> Process {
        let path = bundle.path
        guard path.hasPrefix("/"), path.hasSuffix(".app"), pid > 1 else {
            throw UpdateFailure("\(path) is not an app to open again")
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", relaunchScript, "iguana-relaunch", String(pid), path]
        shell.currentDirectoryURL = URL(fileURLWithPath: "/")
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        return shell
    }

    func relaunch(_ bundle: URL) throws {
        // A test never ends the process it runs in, and never opens an app.
        guard !Iguana.isUnderTest else { throw UpdateFailure("a test may not restart anything") }
        try Self.relaunchProcess(bundle: bundle, pid: ProcessInfo.processInfo.processIdentifier).run()
        // The ordinary way out, so that the layouts are saved as on any quit. The windows stay
        // where they are, and the new Iguana finds them there.
        NSApp.terminate(nil)
    }
}
