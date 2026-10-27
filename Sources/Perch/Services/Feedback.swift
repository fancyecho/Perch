import AppKit
import AVFoundation
import Observation

/// How the completion chime sounds. Most are macOS's own recorded sounds, read from the system at
/// runtime; recordings sound far more natural than anything synthesized from sine waves.
nonisolated enum ChimeStyle: String, CaseIterable, Identifiable, Sendable {
    /// Perch's own "di-da", re-composed from the strikes of the Apple Pay chime.
    case perch
    /// The Apple Pay "payment succeeded" chime as is.
    case applePay
    case glass
    case tink
    case bottle
    /// Synthesized; also the fallback when a system sound file is missing.
    case marimba

    var id: String { rawValue }

    var systemSound: URL? {
        let path: String? = switch self {
        case .perch, .applePay: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/payment_success.aif"
        case .glass: "/System/Library/Sounds/Glass.aiff"
        case .tink: "/System/Library/Sounds/Tink.aiff"
        case .bottle: "/System/Library/Sounds/Bottle.aiff"
        case .marimba: nil
        }
        return path.map { URL(fileURLWithPath: $0) }
    }
}

/// The little rewards for getting things done: a crisp chime on every completion, and a fanfare
/// plus confetti when today is cleared.
@Observable
final class Feedback {
    static let shared = Feedback()

    /// Bumped on every completion; drives the progress-ring pop.
    private(set) var completionCount = 0
    /// Bumped when today's list is cleared; drives the confetti.
    private(set) var celebrationCount = 0

    @ObservationIgnored private var cache: [String: Data] = [:]
    /// NSSound stops when released, so keep the ones that are still ringing.
    @ObservationIgnored private var playing: [NSSound] = []

    private var soundOn: Bool { UserDefaults.standard.bool(forKey: Pref.completionSound) }
    private var celebrationsOn: Bool { UserDefaults.standard.bool(forKey: Pref.celebrations) }
    private var style: ChimeStyle {
        UserDefaults.standard.string(forKey: Pref.chimeStyle).flatMap(ChimeStyle.init(rawValue:)) ?? .perch
    }

    /// The moment a task is checked off, before the row animates away.
    func taskChecked() {
        completionCount += 1
        guard soundOn else { return }
        play(chime(style))
    }

    func todayCleared() {
        if celebrationsOn { celebrationCount += 1 }
        guard soundOn else { return }
        let style = style
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            play(cached("fanfare-\(style.rawValue)") { SoundBank.fanfare(style) })
        }
    }

    func preview(_ style: ChimeStyle? = nil) {
        play(chime(style ?? self.style))
    }

    private func chime(_ style: ChimeStyle) -> Data {
        cached("chime-\(style.rawValue)") { SoundBank.chime(style) }
    }

    private func cached(_ key: String, render: () -> Data) -> Data {
        if let data = cache[key] { return data }
        let data = render()
        cache[key] = data
        return data
    }

    private func play(_ wav: Data) {
        playing.removeAll { !$0.isPlaying }
        guard let sound = NSSound(data: wav) else { return }
        sound.volume = 0.6
        sound.play()
        playing.append(sound)
    }
}

/// Prepares chime audio: system recordings trimmed, level-matched and pitched, or the synthesized
/// marimba when no recording is available.
nonisolated enum SoundBank {
    static func chime(_ style: ChimeStyle) -> Data {
        guard let clip = recording(for: style) else { return ToneSynth.marimba() }
        if style == .perch { return PerchChime(source: clip).chime.wav() }
        return clip.wav()
    }

    /// The same sound as a quick rising major arpeggio.
    static func fanfare(_ style: ChimeStyle) -> Data {
        guard let clip = recording(for: style) else { return ToneSynth.marimbaFanfare() }
        if style == .perch { return PerchChime(source: clip).fanfare.wav() }
        let steps: [(semitones: Double, delay: Double)] = [(0, 0), (4, 0.11), (7, 0.22), (12, 0.33)]
        return Clip.mix(steps.map { (clip.pitched(by: $0.semitones), $0.delay) }, sampleRate: clip.sampleRate).wav()
    }

    private static func recording(for style: ChimeStyle) -> Clip? {
        guard let url = style.systemSound else { return nil }
        return Clip(contentsOf: url)?.trimmingLeadingSilence()
    }
}

/// Perch's chime, rebuilt from the two strikes of the Apple Pay chime (D6, then D7 an octave up).
/// The octave leap is what makes it sound like a payment, so the strikes are re-tuned to a warmer
/// major sixth (C6 → A6), brought closer together for a quicker "di-da", and given a shorter,
/// slightly softened tail that is easier on the ear when heard all day.
nonisolated struct PerchChime {
    let low: Clip
    let high: Clip

    init(source: Clip) {
        let split = Self.secondStrike(in: source)
        low = source.slice(from: 0, to: split).fadingOut(over: 0.015).pitched(by: -2)
        // Cut before re-tuning: pitching down five semitones stretches it by about a third.
        high = source.slice(from: split, to: split + 0.3).fadingOut(over: 0.14)
    }

    var chime: Clip {
        Clip.mix([(low, 0), (high.pitched(by: -5), 0.085)], sampleRate: low.sampleRate).lowPassed(cutoff: 6500)
    }

    /// The first strike, then the bright one climbing A6 → C7 → E7.
    var fanfare: Clip {
        Clip.mix([(low, 0), (high.pitched(by: -5), 0.085), (high.pitched(by: -2), 0.2), (high.pitched(by: 2), 0.32)], sampleRate: low.sampleRate)
            .lowPassed(cutoff: 7000)
    }

    /// Seconds to the start of the second strike: the steepest rise in loudness after the first.
    private static func secondStrike(in clip: Clip) -> Double {
        let window = Int(0.005 * clip.sampleRate)
        let start = Int(0.06 * clip.sampleRate), end = min(clip.samples.count - window, Int(0.4 * clip.sampleRate))
        guard window > 0, end > start else { return 0.13 }
        var bestRise: Float = 0, bestIndex = 0
        var previous = rms(clip.samples, start - window, window)
        for i in stride(from: start, to: end, by: window) {
            let current = rms(clip.samples, i, window)
            if current - previous > bestRise { bestRise = current - previous; bestIndex = i }
            previous = current
        }
        guard bestIndex > 0 else { return 0.13 }
        return max(0, Double(bestIndex - window) / clip.sampleRate)
    }

    private static func rms(_ samples: [Float], _ start: Int, _ count: Int) -> Float {
        guard start >= 0, start + count <= samples.count, count > 0 else { return 0 }
        var sum: Float = 0
        for i in start..<(start + count) { sum += samples[i] * samples[i] }
        return (sum / Float(count)).squareRoot()
    }
}

/// Mono audio samples with the few operations the chimes need.
nonisolated struct Clip {
    var samples: [Float]
    let sampleRate: Double

    init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    init?(contentsOf url: URL) {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
            for i in 0..<frames { mono[i] += channels[channel][i] / Float(count) }
        }
        self.init(samples: mono, sampleRate: buffer.format.sampleRate)
    }

    /// Starts 2 ms before the sound does, so it fires the instant a task is checked.
    func trimmingLeadingSilence() -> Clip {
        let peak = samples.lazy.map(abs).max() ?? 0
        guard peak > 0, let onset = samples.firstIndex(where: { abs($0) > peak * 0.03 }) else { return self }
        let start = max(0, onset - Int(0.002 * sampleRate))
        return Clip(samples: Array(samples[start...]), sampleRate: sampleRate)
    }

    /// Raises pitch like playing the recording slightly faster, which keeps it sounding natural.
    func pitched(by semitones: Double) -> Clip {
        guard semitones != 0 else { return self }
        let rate = pow(2, semitones / 12)
        let count = Int(Double(samples.count) / rate)
        var output = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * rate
            let index = Int(position), fraction = Float(position - Double(index))
            // Cubic (Catmull-Rom) interpolation between neighbouring samples.
            let p0 = sample(index - 1), p1 = sample(index), p2 = sample(index + 1), p3 = sample(index + 2)
            let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
            let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
            let c = -0.5 * p0 + 0.5 * p2
            output[i] = ((a * fraction + b) * fraction + c) * fraction + p1
        }
        return Clip(samples: output, sampleRate: sampleRate)
    }

    func slice(from start: Double, to end: Double) -> Clip {
        let first = max(0, min(samples.count, Int(start * sampleRate)))
        let last = max(first, min(samples.count, Int(end * sampleRate)))
        return Clip(samples: Array(samples[first..<last]), sampleRate: sampleRate)
    }

    func fadingOut(over seconds: Double) -> Clip {
        let length = min(samples.count, Int(seconds * sampleRate))
        guard length > 0 else { return self }
        var copy = samples
        for i in 0..<length {
            // Equal-power curve: fades without a sudden drop at the start.
            copy[samples.count - length + i] *= Float(cos(Double(i) / Double(length) * .pi / 2))
        }
        return Clip(samples: copy, sampleRate: sampleRate)
    }

    /// One-pole low-pass: takes the sharpest edge off the very top.
    func lowPassed(cutoff: Double) -> Clip {
        let alpha = Float(1 - exp(-2 * .pi * cutoff / sampleRate))
        var state: Float = 0
        return Clip(samples: samples.map { state += alpha * ($0 - state); return state }, sampleRate: sampleRate)
    }

    private func sample(_ index: Int) -> Float {
        samples.indices.contains(index) ? samples[index] : 0
    }

    static func mix(_ parts: [(clip: Clip, delay: Double)], sampleRate: Double) -> Clip {
        let length = parts.map { Int($0.delay * sampleRate) + $0.clip.samples.count }.max() ?? 0
        var output = [Float](repeating: 0, count: length)
        for part in parts {
            let offset = Int(part.delay * sampleRate)
            for (i, value) in part.clip.samples.enumerated() { output[offset + i] += value * 0.7 }
        }
        return Clip(samples: output, sampleRate: sampleRate)
    }

    /// Peak-normalized 16-bit mono WAV, so every choice plays at a similar level.
    func wav() -> Data {
        let peak: Float = samples.lazy.map(abs).max() ?? 0
        let scale: Float = peak > 0 ? 0.85 / peak : 0
        let pcm: [Int16] = samples.map { sample in
            let clamped: Float = max(-1, min(1, sample * scale))
            return Int16(clamped * Float(Int16.max))
        }
        return ToneSynth.wav(pcm, sampleRate: sampleRate)
    }
}

/// The synthesized marimba: harmonic, woody overtones on a short decay.
nonisolated enum ToneSynth {
    struct Note {
        let frequency: Double
        let start: Double
        let decay: Double
        let gain: Double
    }

    static let sampleRate = 44_100.0

    /// Marimba bars are tuned so their overtones land on the 4th and 10th harmonics.
    private static let partials: [(ratio: Double, gain: Double, decay: Double)] = [(1, 1, 1), (4, 0.45, 0.22), (10, 0.06, 0.08)]

    static func marimba() -> Data {
        let base = 1046.5  // C6, then G6
        return render([
            Note(frequency: base, start: 0, decay: 0.07, gain: 0.75),
            Note(frequency: base * 1.5, start: 0.08, decay: 0.16, gain: 1),
        ], length: 0.55)
    }

    static func marimbaFanfare() -> Data {
        let notes = [1, 1.25, 1.5, 2].enumerated().map { index, ratio in
            Note(frequency: 1046.5 * ratio, start: Double(index) * 0.09, decay: index == 3 ? 0.4 : 0.12, gain: index == 3 ? 1 : 0.75)
        }
        return render(notes, length: 1.2)
    }

    static func render(_ notes: [Note], length: Double) -> Data {
        let count = Int(length * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for note in notes {
            let first = Int(note.start * sampleRate)
            guard first < count else { continue }
            for i in first..<count {
                let t = Double(i - first) / sampleRate
                let attack = t < 0.0015 ? 0.5 - 0.5 * cos(.pi * t / 0.0015) : 1
                // Stop once the note has died away; the attack starts from 0, so skip it.
                if t > 0.0015 && exp(-t / note.decay) < 0.0003 { break }
                var value = 0.0
                for partial in partials {
                    value += partial.gain * exp(-t / (note.decay * partial.decay)) * sin(2 * .pi * note.frequency * partial.ratio * t)
                }
                samples[i] += Float(note.gain * attack * value)
            }
        }
        return Clip(samples: samples, sampleRate: sampleRate).wav()
    }

    static func wav(_ samples: [Int16], sampleRate: Double) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples { append(sample) }
        return data
    }
}
