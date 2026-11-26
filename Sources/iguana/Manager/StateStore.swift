import CoreGraphics
import Foundation
import IguanaCore

/// The layouts as they are kept between runs of Iguana.
struct SavedState: Codable {
    var boot: Double
    var trees: [String: NodeSnapshot]
    /// The windows floated by hand.
    var floating: [CGWindowID]
    /// The windows tiled by hand, so that a rule that floats one of them does not float it
    /// again. A file written before this was kept has none.
    var tiled: [CGWindowID]?
    /// Minimum sizes learned so far, as [width, height], so a restart does not relearn them.
    var minSizes: [String: [Double]]?
    /// What each window in `trees`, `floating` and `tiled` is, so that it can be known again
    /// after a restart of the Mac, when it has a new id.
    var windows: [String: WindowDescriptor]?
}

/// Reads and writes the saved layouts.
struct StateStore {
    let url: URL
    /// When the Mac started. Window ids are only meaningful until the next restart of the Mac.
    let bootTime: () -> Double

    /// The file Iguana keeps in its Application Support folder. A test run gets a file of its
    /// own in the temporary folder instead (see `Iguana.isUnderTest`).
    static var standard: StateStore {
        let folder = Iguana.isUnderTest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("iguana-tests-\(getpid())")
            : Iguana.supportDirectory
        return StateStore(url: folder.appendingPathComponent("state.json"), bootTime: { systemBootTime })
    }

    static var systemBootTime: Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib = [CTL_KERN, KERN_BOOTTIME]
        return sysctl(&mib, 2, &tv, &size, nil, 0) == 0 ? Double(tv.tv_sec) : 0
    }

    func load() -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    func save(_ state: SavedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
