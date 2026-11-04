import AutoREQCore
import CoreAudio
import Foundation
import Synchronization

/// Plays the generator signal on chosen output channels and measures the transfer function to the microphone.
/// It also gives the spectrum of chosen input channels for the RTA and the spectrograph.
///
/// The output and the input run on two engines. Each engine writes its samples to a ring with an
/// absolute counter. GCC-PHAT finds the offset between the two counters. The offset stays constant
/// while both engines run, so arrival times of different speakers are comparable within one session.
final class MeasurementEngine: @unchecked Sendable {
    struct Update {
        var response: Response?
        var micPeakDB: Double
        var micRMSDB: Double
        var status: Status
        /// 0…1. It reaches 1 when the reading is stable (for Auto Capture).
        var stability: Double
        /// The averaged band levels of each spectrum channel.
        var spectrum: [Int: [Double]] = [:]
        /// The 1/24-octave levels of the last frame of the first spectrum channel.
        var spectrogramFrame: [Float]?
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

    let sampleRate: Double
    private let output: OutputStream
    private let input: InputStream
    private let refRing = SampleRing(capacityPowerOfTwo: 1 << 20)
    private let micRing = SampleRing(capacityPowerOfTwo: 1 << 20)
    /// One ring for each of the first `maxSpectrumChannels` input channels.
    private let inputRings: [SampleRing]
    static let maxSpectrumChannels = 8
    /// Atomics cannot be copied into a closure, so the render closures share this box.
    private final class Shared: @unchecked Sendable {
        let noiseMask = Atomic<UInt64>(0)
        let noiseGain = Atomic<UInt32>(Float(0.1).bitPattern)
        let micPeak = Atomic<UInt32>(0)
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
    private let analyzer: TransferAnalyzer
    private let impulseAnalyzer: ImpulseAnalyzer
    private var lastImpulse: ImpulseResponse?
    private var ticks = 0
    private var refOffset: Int?
    private var lastDelaySearch = Date.distantPast
    private var noiseStartCount = 0
    private var history: [Double] = []
    private var stableFrames = 0
    private var failedSearches = 0
    private var periodicSignal = false
    private var tonalSignal = false
    private var spectrumChannels: [Int] = []
    private var spectrumAnalyzers: [Int: SpectrumAnalyzer] = [:]
    private var banding = Banding.oct3
    private var spectrumAveraging = Averaging.fast
    var clockDriftCorrection = false
    var onUpdate: ((Update) -> Void)?

    init(outputDevice: AudioDeviceID, inputDevice: AudioDeviceID, micChannel: Int, sampleRate: Double, averaging: Averaging) throws {
        AudioDevice.setSampleRate(sampleRate, for: outputDevice)
        AudioDevice.setSampleRate(sampleRate, for: inputDevice)
        shared = Shared(SignalGenerator(.pink, sampleRate: sampleRate))
        inputRings = (0..<Self.maxSpectrumChannels).map { _ in SampleRing(capacityPowerOfTwo: 1 << 16) }
        let sh = shared, ref = refRing, mic = micRing, rings = inputRings
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        output = try OutputStream(device: outputDevice) { chans, frames in
            let m = sh.noiseMask.load(ordering: .relaxed)
            let g = Float(bitPattern: sh.noiseGain.load(ordering: .relaxed))
            let n = min(frames, 8192)
            if m == 0 || sh.generator.withLockIfAvailable({ $0.render(scratch, n) }) == nil {
                for i in 0..<n { scratch[i] = 0 }
            }
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
                let c = min(micChannel, chans.count - 1)
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
        self.sampleRate = output.sampleRate
        analyzer = TransferAnalyzer(fftSize: 16_384, sampleRate: output.sampleRate, averaging: averaging)
        analyzer.frameInterval = 0.1
        impulseAnalyzer = ImpulseAnalyzer(sampleRate: output.sampleRate)
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
            let g = SignalGenerator(new, sampleRate: sampleRate, periodLength: impulseAnalyzer.fftSize, fileSamples: fileSamples)
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

    func setAveraging(_ a: Averaging) { queue.async { self.analyzer.averaging = a } }

    /// Clears the averages. The delay stays, because it does not change while the engines run.
    func resetAverages() { queue.async { self.resetAnalyzers(); self.history = []; self.stableFrames = 0 } }

    private func resetAnalyzers() {
        analyzer.reset()
        impulseAnalyzer.reset()
        impulseAnalyzer.periodic = periodicSignal
        lastImpulse = nil
    }

    private func restart() {
        resetAnalyzers()
        history = []
        stableFrames = 0
        failedSearches = 0
        noiseStartCount = refRing.count
        refOffset = nil
    }

    private func tick() {
        let pk = Float(bitPattern: shared.micPeak.exchange(0, ordering: .relaxed))
        let mc = micRing.count
        let rmsWindow = micRing.read(from: mc - 4800, count: 4800) ?? []
        let rms = rmsWindow.isEmpty ? 0 : (rmsWindow.reduce(0) { $0 + $1 * $1 } / Float(rmsWindow.count)).squareRoot()
        var update = Update(response: nil, micPeakDB: 20 * log10(max(Double(pk), 1e-7)), micRMSDB: 20 * log10(max(Double(rms), 1e-7)), status: .idle, stability: 0)
        defer { let u = update; DispatchQueue.main.async { self.onUpdate?(u) } }
        analyzeSpectrum(&update)

        guard shared.noiseMask.load(ordering: .relaxed) != 0 else { return }
        guard !tonalSignal else { update.status = .tone; return }
        let n = analyzer.fftSize
        let playedSamples = refRing.count - noiseStartCount
        if refOffset == nil || (clockDriftCorrection && Date().timeIntervalSince(lastDelaySearch) > 3) {
            update.status = refOffset == nil ? (failedSearches > 6 ? .noDelay : .findingDelay) : .measuring
            guard playedSamples > Int(sampleRate * 0.8) else { return }
            findDelay()
            if refOffset == nil { return }
        }
        guard let off = refOffset,
              let mic = micRing.read(from: mc - n, count: n),
              let ref = refRing.read(from: mc - n + off, count: n)
        else { update.status = .findingDelay; return }
        analyzer.add(reference: ref, measured: mic)
        // The impulse frame is longer than 1.2 s, so a new frame every 0.5 s is enough.
        ticks += 1
        let ni = impulseAnalyzer.fftSize
        if ticks % 5 == 0,
           let micLong = micRing.read(from: mc - ni, count: ni),
           let refLong = refRing.read(from: mc - ni + off, count: ni) {
            impulseAnalyzer.add(reference: refLong, measured: micLong)
            lastImpulse = impulseAnalyzer.impulse()
        }
        var r = analyzer.response(latencySamples: -off)
        r.impulse = lastImpulse
        update.response = r
        update.status = .measuring

        // Stability: the mean level in 100 Hz–10 kHz changes little, and the coherence is fair.
        let lo = FrequencyGrid.index(of: 100), hi = FrequencyGrid.index(of: 10_000)
        let mean = r.magnitudeDB[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        let coh = r.coherence[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        history.append(mean)
        if history.count > 5 { history.removeFirst() }
        let spread = (history.max() ?? 0) - (history.min() ?? 0)
        stableFrames = (history.count == 5 && spread < 0.25 && coh > 0.6) ? stableFrames + 1 : max(0, stableFrames - 1)
        update.stability = min(1, Double(stableFrames) / 15)
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

    private func findDelay() {
        lastDelaySearch = Date()
        // Periodic noise matches at every period. A search range shorter than one period keeps the match unique.
        let mLen = 1 << 15, rLen = periodicSignal ? mLen + (1 << 15) : 1 << 17
        let mc = micRing.count, rc = refRing.count
        guard let mic = micRing.read(from: mc - mLen, count: mLen),
              let ref = refRing.read(from: rc - rLen, count: rLen),
              let hit = DelayFinder.find(reference: ref, measured: mic)
        else { failedSearches += 1; return }
        guard hit.quality > 6 else { failedSearches += 1; return }
        let newOffset = (rc - rLen + hit.lag) - (mc - mLen)
        if let old = refOffset, old != newOffset { resetAnalyzers() }
        refOffset = newOffset
    }
}
