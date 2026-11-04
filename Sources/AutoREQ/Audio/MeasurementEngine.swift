import AutoREQCore
import CoreAudio
import Foundation
import Synchronization

/// Plays the generator signal on chosen output channels and measures the transfer function to one
/// or more mic channels. It also gives the spectrum of chosen input channels for the RTA.
///
/// The output and the input run on two engines. Each engine writes its samples to a ring with an
/// absolute counter. GCC-PHAT finds the offset between the two counters for each mic. The offset
/// stays constant while both engines run, so arrival times of different speakers are comparable
/// within one session.
final class MeasurementEngine: @unchecked Sendable {
    struct Update {
        /// The response of the first mic channel.
        var response: Response?
        /// The response of each mic channel, keyed by the zero-based input channel.
        var responses: [Int: Response] = [:]
        var micPeakDB: Double
        var micRMSDB: Double
        var status: Status
        /// 0…1. It reaches 1 when the reading is stable (for Auto Capture).
        var stability: Double
        /// The averaged band levels of each spectrum channel.
        var spectrum: [Int: [Double]] = [:]
        /// The 1/24-octave levels of the last frame of the first spectrum channel.
        var spectrogramFrame: [Float]?
        /// The sound levels of each SPL channel.
        var soundLevels: [Int: SoundLevels] = [:]
    }

    enum Status: Equatable {
        case idle, findingDelay, measuring, noDelay, tone
        var label: String {
            switch self {
            case .idle: "Idle"
            case .findingDelay: "Finding delay…"
            case .measuring: "Measuring"
            case .noDelay: "No signal at the mic. Check levels and routing."
            case .tone: "Playing a tone. A transfer function needs noise or music."
            }
        }
    }

    /// The analysis state of one mic channel. The analysis queue owns it.
    private final class Mic {
        let channel: Int
        let ring: SampleRing
        var analyzer: WindowedTransferAnalyzer
        let impulse: ImpulseAnalyzer
        var lastImpulse: ImpulseResponse?
        /// The reference index minus the mic index of the same sound.
        var offset: Int?
        var failedSearches = 0
        var tracker = DelayTracker()

        init(channel: Int, ring: SampleRing, sampleRate: Double, averaging: Averaging, multiWindow: Bool) {
            self.channel = channel
            self.ring = ring
            analyzer = WindowedTransferAnalyzer(sampleRate: sampleRate, averaging: averaging, multiWindow: multiWindow)
            impulse = ImpulseAnalyzer(sampleRate: sampleRate)
        }

        func reset(periodic: Bool) {
            analyzer.reset()
            impulse.reset()
            impulse.periodic = periodic
            lastImpulse = nil
        }
    }

    let sampleRate: Double
    /// The mic channels. The first is the main mic: the level meter, the status and Auto Capture use it.
    let micChannels: [Int]
    private let output: OutputStream
    private let input: InputStream
    private let refRing = SampleRing(capacityPowerOfTwo: 1 << 20)
    private let micRing = SampleRing(capacityPowerOfTwo: 1 << 20)
    /// One ring for each of the first `maxSpectrumChannels` input channels.
    /// The rings hold more than the longest analysis frame at 96 kHz.
    private let inputRings: [SampleRing]
    static let maxSpectrumChannels = 8
    /// Atomics cannot be copied into a closure, so the render closures share this box.
    private final class Shared: @unchecked Sendable {
        let noiseMask = Atomic<UInt64>(0)
        let noiseGain = Atomic<UInt32>(Float(0.1).bitPattern)
        let micPeak = Atomic<UInt32>(0)
        /// The reference index of the last table start (a sweep start), or -1.
        let periodStart = Atomic<Int>(-1)
        /// The render thread only tries the lock. If the main thread holds it to swap the signal,
        /// the render thread plays silence for one buffer.
        let generator: Mutex<SignalGenerator>
        init(_ g: SignalGenerator) { generator = Mutex(g) }
    }
    private let shared: Shared
    /// The signal that plays now. Only the main thread reads and writes it.
    private var signal = SignalSettings.pink
    private let queue = DispatchQueue(label: "autoreq.analysis", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    // State owned by `queue`.
    private var mics: [Mic]
    private var averaging: Averaging
    private var multiWindow: Bool
    private var ticks = 0
    private var lastRefCount = 0
    private var noiseStartCount = 0
    private var history: [Double] = []
    private var stableFrames = 0
    private var periodicSignal = false
    private var tonalSignal = false
    private var spectrumChannels: [Int] = []
    private var spectrumAnalyzers: [Int: SpectrumAnalyzer] = [:]
    private var banding = Banding.oct3
    private var spectrumAveraging = Averaging.fast
    private var meters: [Int: SoundLevelMeter] = [:]
    private var meterRead: [Int: Int] = [:]
    /// Follows the delay of each mic from its impulse response. This also removes clock drift.
    var clockDriftCorrection = false
    var onUpdate: ((Update) -> Void)?

    /// - Parameter micChannels: The zero-based input channels of the mics. The first is the main mic.
    ///   Extra mics must be among the first `maxSpectrumChannels` channels.
    init(outputDevice: AudioDeviceID, inputDevice: AudioDeviceID, micChannels: [Int], sampleRate: Double, averaging: Averaging, multiWindow: Bool = true) throws {
        AudioDevice.setSampleRate(sampleRate, for: outputDevice)
        AudioDevice.setSampleRate(sampleRate, for: inputDevice)
        let main = micChannels.first ?? 0
        shared = Shared(SignalGenerator(.pink, sampleRate: sampleRate))
        inputRings = (0..<Self.maxSpectrumChannels).map { _ in SampleRing(capacityPowerOfTwo: 1 << 18) }
        let sh = shared, ref = refRing, mic = micRing, rings = inputRings
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        output = try OutputStream(device: outputDevice) { chans, frames in
            let m = sh.noiseMask.load(ordering: .relaxed)
            let g = Float(bitPattern: sh.noiseGain.load(ordering: .relaxed))
            let n = min(frames, 8192)
            let before = ref.count
            let wrap = m == 0 ? nil : sh.generator.withLockIfAvailable { g -> Int? in g.render(scratch, n); return g.lastWrap }
            if wrap == nil { for i in 0..<n { scratch[i] = 0 } }
            if let w = wrap ?? nil { sh.periodStart.store(before + w, ordering: .relaxed) }
            for i in 0..<n { scratch[i] *= g }
            ref.write(scratch, n)
            for (c, buf) in chans.enumerated() {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if c < 64 && m & (1 << UInt64(c)) != 0 { for i in 0..<n { p[i] = scratch[i] } } else { for i in 0..<n { p[i] = 0 } }
            }
        }
        do {
            input = try InputStream(device: inputDevice) { chans, frames in
                for (i, ring) in rings.enumerated() where i < chans.count {
                    if let p = chans[i].mData?.assumingMemoryBound(to: Float.self) { ring.write(p, frames) }
                }
                let c = min(main, chans.count - 1)
                guard c >= 0, let p = chans[c].mData?.assumingMemoryBound(to: Float.self) else { return }
                mic.write(p, frames)
                var pk = Float(bitPattern: sh.micPeak.load(ordering: .relaxed))
                for i in 0..<frames { pk = max(pk, abs(p[i])) }
                sh.micPeak.store(pk.bitPattern, ordering: .relaxed)
            }
        } catch {
            output.stop()
            throw error
        }
        if abs(output.sampleRate - input.sampleRate) > 1 {
            output.stop(); input.stop()
            throw NSError(domain: "AutoREQ", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The mic runs at \(Int(input.sampleRate)) Hz and the output at \(Int(output.sampleRate)) Hz. Set both devices to the same rate in Audio MIDI Setup."])
        }
        let rate = output.sampleRate
        self.sampleRate = rate
        self.averaging = averaging
        self.multiWindow = multiWindow
        let inCount = input.channelCount, limit = Self.maxSpectrumChannels
        let extras = Array(micChannels.dropFirst().filter { $0 != main && $0 < limit && $0 < inCount })
        self.micChannels = [main] + extras
        var list = [Mic(channel: main, ring: mic, sampleRate: rate, averaging: averaging, multiWindow: multiWindow)]
        for c in extras { list.append(Mic(channel: c, ring: rings[c], sampleRate: rate, averaging: averaging, multiWindow: multiWindow)) }
        mics = list
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    var outputChannelCount: Int { output.channelCount }
    var inputChannelCount: Int { input.channelCount }

    func shutdown() {
        timer?.cancel()
        shared.noiseMask.store(0, ordering: .relaxed)
        output.stop()
        input.stop()
    }

    /// Plays pink noise on `channels` (zero-based), or stops it with an empty set.
    func setNoise(channels: Set<Int>, levelDBFS: Double = -20) {
        setOutput(channels: channels, signal: .pink, levelDBFS: levelDBFS)
    }

    /// Plays `signal` at an RMS level of `levelDBFS` on `channels`, or stops it with an empty set.
    /// A new channel set or a new signal restarts the analysis. Call it from the main thread.
    func setOutput(channels: Set<Int>, signal new: SignalSettings, levelDBFS: Double, fileSamples: [Float] = []) {
        let changed = new != signal
        if changed {
            signal = new
            // Make the generator here: the periodic noise and a file need a table.
            let period = ImpulseAnalyzer.frameLength(sampleRate: sampleRate)
            let g = SignalGenerator(new, sampleRate: sampleRate, periodLength: period, fileSamples: fileSamples)
            shared.generator.withLock { $0 = g }
        }
        setLevel(levelDBFS)
        let m = channels.filter { $0 < 64 }.reduce(UInt64(0)) { $0 | (1 << UInt64($1)) }
        let old = shared.noiseMask.exchange(m, ordering: .relaxed)
        if old != m || changed {
            let periodic = new.kind == .periodicPink, tonal = new.kind.isTonal
            queue.async { self.periodicSignal = periodic; self.tonalSignal = tonal; self.restart() }
        }
    }

    /// Changes the level of the playing signal. The analysis continues.
    func setLevel(_ levelDBFS: Double) {
        shared.noiseGain.store(Float(pow(10, levelDBFS / 20)).bitPattern, ordering: .relaxed)
    }

    /// Analyzes the spectrum of the input `channels` (zero-based). An empty list stops the spectrum analysis.
    func setSpectrum(channels: [Int], banding: Banding, averaging: Averaging) {
        let chans = channels.filter { $0 < Self.maxSpectrumChannels }
        queue.async {
            self.spectrumChannels = chans
            self.banding = banding
            self.spectrumAveraging = averaging
            self.spectrumAnalyzers = self.spectrumAnalyzers.filter { chans.contains($0.key) }
            for c in chans where self.spectrumAnalyzers[c] == nil {
                let a = SpectrumAnalyzer(sampleRate: self.sampleRate, averaging: averaging)
                a.frameInterval = 0.1
                self.spectrumAnalyzers[c] = a
            }
            for a in self.spectrumAnalyzers.values { a.averaging = averaging }
        }
    }

    func resetSpectrum() { queue.async { for a in self.spectrumAnalyzers.values { a.reset() } } }

    /// Runs one sound level meter for each input channel in `calibrations` (channel → dB SPL offset).
    /// A channel that already has a meter keeps its values. An empty set stops the meters.
    func setSoundLevel(calibrations: [Int: Double]) {
        let cal = calibrations.filter { $0.key < Self.maxSpectrumChannels }
        queue.async {
            self.meters = self.meters.filter { cal[$0.key] != nil }
            self.meterRead = self.meterRead.filter { cal[$0.key] != nil }
            for (c, db) in cal {
                if let m = self.meters[c] { m.calibrationDB = db } else { self.meters[c] = SoundLevelMeter(sampleRate: self.sampleRate, calibrationDB: db) }
            }
        }
    }

    /// Clears the Leq, the maxima, the peaks and the doses of all meters.
    func resetSoundLevel() { queue.async { for m in self.meters.values { m.reset() } } }

    /// The RMS level in dBFS of the last `seconds` of an input channel, for the calibrator.
    func rmsDBFS(channel: Int, seconds: Double) -> Double? {
        guard channel < Self.maxSpectrumChannels else { return nil }
        let ring = inputRings[channel], n = Int(seconds * sampleRate)
        guard let x = ring.read(from: ring.count - n, count: n) else { return nil }
        let ms = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(n)
        return 10 * log10(max(ms, 1e-20))
    }

    func setAveraging(_ a: Averaging) { queue.async { self.averaging = a; for m in self.mics { m.analyzer.averaging = a } } }

    /// Turns the frequency-dependent windows on or off. The averages restart, and the delays stay.
    func setMultiWindow(_ on: Bool) {
        queue.async {
            self.multiWindow = on
            for m in self.mics { m.analyzer = WindowedTransferAnalyzer(sampleRate: self.sampleRate, averaging: self.averaging, multiWindow: on) }
            self.history = []; self.stableFrames = 0
        }
    }

    /// Clears the averages. The delays stay, because they do not change while the engines run.
    func resetAverages() { queue.async { for m in self.mics { m.reset(periodic: self.periodicSignal) }; self.history = []; self.stableFrames = 0 } }

    /// The reference index of the last table start, or -1. The sweep measurement reads it.
    var periodStart: Int { shared.periodStart.load(ordering: .relaxed) }

    /// The mic samples of the last complete period of the table (for example one sweep and its tail).
    /// Each array starts at the first sample of the sweep, with the delay of its mic removed.
    /// `start` identifies the period. It returns nil before the delays are known.
    func lastPeriod(length: Int) -> (start: Int, offsets: [Int: Int], data: [Int: [Float]])? {
        queue.sync {
            let s = shared.periodStart.load(ordering: .relaxed)
            guard s >= 0, let main = mics.first, let off = main.offset else { return nil }
            // Use the newest period that the main mic has fully recorded.
            let start = main.ring.count >= s - off + length ? s : s - length
            var data: [Int: [Float]] = [:], offsets: [Int: Int] = [:]
            for m in mics {
                guard let o = m.offset, let y = m.ring.read(from: start - o, count: length) else { continue }
                data[m.channel] = y
                offsets[m.channel] = o
            }
            return data.isEmpty ? nil : (start, offsets, data)
        }
    }

    private func restart() {
        for m in mics {
            m.reset(periodic: periodicSignal)
            m.offset = nil
            m.failedSearches = 0
            m.tracker = DelayTracker()
        }
        history = []
        stableFrames = 0
        noiseStartCount = refRing.count
    }

    private func tick() {
        let pk = Float(bitPattern: shared.micPeak.exchange(0, ordering: .relaxed))
        let rmsWindow = micRing.read(from: micRing.count - 4800, count: 4800) ?? []
        let rms = rmsWindow.isEmpty ? 0 : (rmsWindow.reduce(0) { $0 + $1 * $1 } / Float(rmsWindow.count)).squareRoot()
        var update = Update(response: nil, micPeakDB: 20 * log10(max(Double(pk), 1e-7)), micRMSDB: 20 * log10(max(Double(rms), 1e-7)), status: .idle, stability: 0)
        defer { let u = update; DispatchQueue.main.async { self.onUpdate?(u) } }
        analyzeSpectrum(&update)
        measureSoundLevel(&update)
        let rc = refRing.count
        let newSamples = max(0, rc - lastRefCount)
        lastRefCount = rc

        guard shared.noiseMask.load(ordering: .relaxed) != 0 else { return }
        guard !tonalSignal else { update.status = .tone; return }
        ticks += 1
        let playedSamples = rc - noiseStartCount
        for (k, mic) in mics.enumerated() {
            if mic.offset == nil {
                if k == 0 { update.status = mic.failedSearches > 6 ? .noDelay : .findingDelay }
                guard playedSamples > Int(sampleRate * 0.8) else { continue }
                findDelay(mic)
                if mic.offset == nil { continue }
            }
            guard let off = mic.offset else { continue }
            let mc = mic.ring.count, n = mic.analyzer.frameLength
            guard let y = mic.ring.read(from: mc - n, count: n), let x = refRing.read(from: mc - n + off, count: n) else {
                if k == 0 { update.status = .findingDelay }
                continue
            }
            mic.analyzer.add(reference: x, measured: y, newSamples: min(newSamples, n), interval: 0.1)
            // The impulse frame is longer than 1.2 s, so a new frame every 0.5 s is enough.
            let ni = mic.impulse.fftSize
            if ticks % 5 == 0, let yl = mic.ring.read(from: mc - ni, count: ni), let xl = refRing.read(from: mc - ni + off, count: ni) {
                mic.impulse.add(reference: xl, measured: yl)
                mic.lastImpulse = mic.impulse.impulse()
                if clockDriftCorrection, let d = mic.tracker.update(lag: mic.impulse.latestPeakLag()) {
                    // The mic hears the sound d samples later than before, so the reference moves back by d.
                    mic.offset = off - d
                    mic.reset(periodic: periodicSignal)
                    if k == 0 { history = []; stableFrames = 0 }
                    continue
                }
            }
            var r = mic.analyzer.response(latencySamples: -off)
            r.impulse = mic.lastImpulse
            update.responses[mic.channel] = r
            if k == 0 {
                update.response = r
                update.status = .measuring
                updateStability(r, &update)
            }
        }
    }

    /// Stability: the mean level in 100 Hz–10 kHz changes little, and the coherence is fair.
    private func updateStability(_ r: Response, _ update: inout Update) {
        let lo = FrequencyGrid.index(of: 100), hi = FrequencyGrid.index(of: 10_000)
        let mean = r.magnitudeDB[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        let coh = r.coherence[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        history.append(mean)
        if history.count > 5 { history.removeFirst() }
        let spread = (history.max() ?? 0) - (history.min() ?? 0)
        stableFrames = (history.count == 5 && spread < 0.25 && coh > 0.6) ? stableFrames + 1 : max(0, stableFrames - 1)
        update.stability = min(1, Double(stableFrames) / 15)
    }

    /// Feeds each meter the samples since the last tick. After a gap, it starts again from the newest 0.1 s.
    private func measureSoundLevel(_ update: inout Update) {
        for (c, m) in meters {
            let ring = inputRings[c], cnt = ring.count
            var from = meterRead[c] ?? (cnt - 4800)
            if cnt - from > ring.capacity / 2 { from = cnt - 4800 }
            if cnt > from, let x = ring.read(from: from, count: cnt - from) { m.process(x) }
            meterRead[c] = cnt
            update.soundLevels[c] = m.levels()
        }
    }

    private func analyzeSpectrum(_ update: inout Update) {
        for (i, c) in spectrumChannels.enumerated() {
            let ring = inputRings[c], a = spectrumAnalyzers[c]!
            guard let x = ring.read(from: ring.count - a.fftSize, count: a.fftSize) else { continue }
            a.add(x)
            update.spectrum[c] = a.levels(banding)
            if i == 0 { update.spectrogramFrame = a.levels(.oct24, averaged: false).map(Float.init) }
        }
    }

    private func findDelay(_ mic: Mic) {
        // Periodic noise matches at every period. A search range shorter than one period keeps the match unique.
        let mLen = 1 << 15, rLen = periodicSignal ? mLen + (1 << 15) : 1 << 17
        let mc = mic.ring.count, rc = refRing.count
        guard let m = mic.ring.read(from: mc - mLen, count: mLen),
              let r = refRing.read(from: rc - rLen, count: rLen),
              let hit = DelayFinder.find(reference: r, measured: m),
              hit.quality > 6
        else { mic.failedSearches += 1; return }
        mic.offset = (rc - rLen + hit.lag) - (mc - mLen)
        mic.reset(periodic: periodicSignal)
    }
}
