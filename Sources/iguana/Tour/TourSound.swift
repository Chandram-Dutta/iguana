import AVFoundation

/// The sounds of the welcome tour. Nothing is loaded from a file: every cue is a few soft mallet
/// notes from one pentatonic scale, built when the tour opens, so any two of them sound right
/// together however fast they follow each other.
final class TourSound {
    enum Cue: Hashable {
        case hello
        /// A window opening; the number is how many were open before it.
        case open(Int)
        /// Focus landing on a window; 0 is the left edge of the desktop and 5 the right.
        case focus(Int)
        case reached
        case move
        case resize(grow: Bool)
        case desktop(Int)
        case carry
        case success
        case granted
        case finale
    }

    var muted = false

    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let mix = AVAudioMixerNode()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var wired = false
    private var cache: [Cue: AVAudioPCMBuffer] = [:]
    private let lock = NSLock()
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// G major pentatonic, two and a half octaves.
    private static let scale: [Double] = [196.00, 220.00, 246.94, 293.66, 329.63, 392.00, 440.00, 493.88, 587.33, 659.25, 783.99, 880.00]

    static let allCues: [Cue] = [.hello, .reached, .move, .resize(grow: true), .resize(grow: false), .carry, .success, .granted, .finale]
        + (0..<4).map(Cue.open) + (0..<6).map(Cue.focus) + (0..<3).map(Cue.desktop)

    init() {
        // Build the cues off the main thread, so the first one is ready when it is asked for.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for cue in Self.allCues { _ = self?.buffer(for: cue) }
        }
    }

    func play(_ cue: Cue) {
        guard !muted, start() else { return }
        guard let buffer = buffer(for: cue) else { return }
        let player = players[next]
        next = (next + 1) % players.count
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        guard wired else { return }
        players.forEach { $0.stop() }
        engine.stop()
    }

    private func start() -> Bool {
        // With no sound output (a virtual machine, a Mac with nothing plugged in) there is
        // nothing to connect to, and trying would bring the app down rather than fail politely.
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.channelCount > 0, output.sampleRate > 0 else { return false }
        if !wired {
            wired = true
            engine.attach(mix)
            engine.attach(reverb)
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 16
            for _ in 0..<6 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: mix, format: Self.format)
                players.append(player)
            }
            engine.connect(mix, to: reverb, format: Self.format)
            engine.connect(reverb, to: engine.mainMixerNode, format: Self.format)
            engine.mainMixerNode.outputVolume = 0.7
        }
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            // No output device, or it is in use exclusively: the tour simply stays silent.
            return false
        }
    }

    private func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if let made = cache[cue] { return made }
        let made = Self.render(Self.notes(for: cue))
        cache[cue] = made
        return made
    }

    /// Write every cue to a WAV file, to listen to or measure them outside the app.
    static func export(to folder: URL) {
        for cue in allCues {
            guard let buffer = render(notes(for: cue)) else { continue }
            let name = "\(cue)".replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let url = folder.appendingPathComponent("\(name).wav")
            try? FileManager.default.removeItem(at: url)
            guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { continue }
            try? file.write(from: buffer)
        }
    }

    // MARK: Score

    private enum Voice { case mallet, tick, pad }

    private struct Note {
        var at: Double
        var hz: Double
        var gain: Double
        var pan: Double = 0
        var voice: Voice = .mallet
        /// The pitch slides to this multiple of `hz` over the first tenth of a second.
        var glide: Double = 1
    }

    private static func notes(for cue: Cue) -> [Note] {
        let s = scale
        switch cue {
        case .hello:
            return [Note(at: 0, hz: s[0] / 2, gain: 0.20, voice: .pad), Note(at: 0, hz: s[3], gain: 0.13, pan: -0.3, voice: .pad),
                    Note(at: 0.05, hz: s[5], gain: 0.10, pan: 0.3, voice: .pad),
                    Note(at: 0.10, hz: s[5], gain: 0.30, pan: -0.2), Note(at: 0.24, hz: s[7], gain: 0.28, pan: 0.0),
                    Note(at: 0.38, hz: s[8], gain: 0.26, pan: 0.2), Note(at: 0.58, hz: s[10], gain: 0.22, pan: 0.3)]
        case .open(let n):
            let hz = [s[3], s[5], s[7], s[8]][min(max(n, 0), 3)]
            return [Note(at: 0, hz: hz, gain: 0.36), Note(at: 0, hz: hz * 2, gain: 0.07, voice: .tick)]
        case .focus(let position):
            let i = min(max(position, 0), 5)
            return [Note(at: 0, hz: s[5 + i], gain: 0.27, pan: Double(i) / 2.5 - 1, voice: .tick)]
        case .reached:
            return [Note(at: 0, hz: s[8], gain: 0.24), Note(at: 0.07, hz: s[10], gain: 0.22)]
        case .move:
            return [Note(at: 0, hz: s[4], gain: 0.26, voice: .tick), Note(at: 0.055, hz: s[6], gain: 0.24)]
        case .resize(let grow):
            return [Note(at: 0, hz: grow ? s[5] : s[6], gain: 0.22, voice: .tick, glide: grow ? 1.122 : 0.891)]
        case .desktop(let n):
            let hz = [s[0], s[2], s[3]][min(max(n, 0), 2)]
            return [Note(at: 0, hz: hz, gain: 0.40, pan: Double(min(max(n, 0), 2) - 1) * 0.5), Note(at: 0, hz: hz * 2, gain: 0.10)]
        case .carry:
            return [Note(at: 0, hz: s[3], gain: 0.24, pan: -0.3, voice: .tick), Note(at: 0.05, hz: s[5], gain: 0.24, voice: .tick),
                    Note(at: 0.10, hz: s[7], gain: 0.26, pan: 0.3)]
        case .success:
            return [Note(at: 0, hz: s[5], gain: 0.26, pan: -0.2), Note(at: 0.08, hz: s[7], gain: 0.25),
                    Note(at: 0.16, hz: s[8], gain: 0.25, pan: 0.2), Note(at: 0.26, hz: s[10], gain: 0.26)]
        case .granted:
            return [Note(at: 0, hz: s[0], gain: 0.16, voice: .pad), Note(at: 0, hz: s[5], gain: 0.10, voice: .pad),
                    Note(at: 0, hz: s[3], gain: 0.30, pan: -0.2), Note(at: 0.09, hz: s[5], gain: 0.28),
                    Note(at: 0.18, hz: s[7], gain: 0.28, pan: 0.2), Note(at: 0.30, hz: s[10], gain: 0.30)]
        case .finale:
            return [Note(at: 0, hz: s[0] / 2, gain: 0.22, voice: .pad), Note(at: 0, hz: s[3] / 2, gain: 0.14, voice: .pad),
                    Note(at: 0.04, hz: s[2], gain: 0.12, pan: -0.4, voice: .pad), Note(at: 0.08, hz: s[4], gain: 0.10, pan: 0.4, voice: .pad),
                    Note(at: 0.00, hz: s[10], gain: 0.24, pan: 0.3), Note(at: 0.11, hz: s[8], gain: 0.22, pan: 0.1),
                    Note(at: 0.22, hz: s[7], gain: 0.22, pan: -0.1), Note(at: 0.33, hz: s[5], gain: 0.24, pan: -0.3),
                    Note(at: 0.62, hz: s[10], gain: 0.16), Note(at: 0.62, hz: s[5], gain: 0.20)]
        }
    }

    // MARK: Synthesis

    /// A partial of a voice: a multiple of the note's pitch, how loud it is, and how fast it
    /// fades compared with the fundamental.
    private typealias Partial = (ratio: Double, gain: Double, decay: Double)

    private static func render(_ notes: [Note]) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        func length(_ note: Note) -> Double {
            switch note.voice {
            case .mallet: return 1.5
            case .tick: return 0.45
            case .pad: return 5.2
            }
        }
        let seconds = notes.map { $0.at + length($0) }.max() ?? 0
        let frames = Int(seconds * rate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = channels[0], right = channels[1]
        for i in 0..<frames {
            left[i] = 0
            right[i] = 0
        }

        for note in notes {
            let partials: [Partial]
            let attack: Double
            var fade: Double
            switch note.voice {
            case .mallet:
                // The bars of a marimba ring at one, four and about ten times their pitch.
                partials = [(1, 1, 1), (2, 0.08, 0.6), (4, 0.15, 0.24), (9.2, 0.035, 0.1)]
                attack = 0.004
                fade = 0.30 * pow(330 / note.hz, 0.35)
            case .tick:
                partials = [(1, 1, 1), (4, 0.10, 0.3)]
                attack = 0.003
                fade = 0.085 * pow(330 / note.hz, 0.25)
            case .pad:
                partials = [(1, 1, 1), (1.003, 0.8, 1), (2, 0.28, 0.8), (2.006, 0.2, 0.8), (3, 0.08, 0.6)]
                attack = 0.32
                fade = 1.55
            }
            fade = max(fade, 0.03)
            let angle = (note.pan + 1) * Double.pi / 4
            let gainLeft = Float(cos(angle) * note.gain), gainRight = Float(sin(angle) * note.gain)
            let first = Int(note.at * rate)
            let count = min(Int(length(note) * rate), frames - first)
            guard count > 0 else { continue }
            var phases = [Double](repeating: 0, count: partials.count)
            let tail = 0.03 * rate
            for i in 0..<count {
                let t = Double(i) / rate
                let bend = note.glide == 1 ? 1 : 1 + (note.glide - 1) * min(t / 0.1, 1)
                let rise = 1 - exp(-t / attack)
                // Fade the very end to silence, so that a note cut short does not click.
                let end = min(Double(count - i) / tail, 1)
                var sample = 0.0
                for (p, partial) in partials.enumerated() {
                    let hz = note.hz * partial.ratio * bend
                    guard hz < rate * 0.45 else { continue }
                    phases[p] += 2 * Double.pi * hz / rate
                    sample += sin(phases[p]) * partial.gain * exp(-t / (fade * partial.decay))
                }
                let value = Float(sample * rise * end)
                left[first + i] += value * gainLeft
                right[first + i] += value * gainRight
            }
        }

        // Several notes together must never reach full scale.
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(left[i]), abs(right[i])) }
        if peak > 0.7 {
            let scale = 0.7 / peak
            for i in 0..<frames {
                left[i] *= scale
                right[i] *= scale
            }
        }
        return buffer
    }
}
