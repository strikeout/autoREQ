import AutoREQCore
import CoreAudio
import Foundation
import Synchronization

/// Plays pink noise on chosen output channels and measures the transfer function to the microphone.
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
    }

    enum Status: Equatable {
        case idle, findingDelay, measuring, noDelay
        var label: String {
            switch self {
            case .idle: "Idle"
            case .findingDelay: "Finding delay…"
            case .measuring: "Measuring — playing pink noise"
            case .noDelay: "No signal at the mic. Check levels and routing."
            }
        }
    }

    let sampleRate: Double
    private let output: OutputStream
    private let input: InputStream
    private let refRing = SampleRing(capacityPowerOfTwo: 1 << 20)
    private let micRing = SampleRing(capacityPowerOfTwo: 1 << 20)
    /// Atomics cannot be copied into a closure, so the render closures share this box.
    private final class Shared: @unchecked Sendable {
        let noiseMask = Atomic<UInt64>(0)
        let noiseGain = Atomic<UInt32>(Float(0.25).bitPattern)
        let micPeak = Atomic<UInt32>(0)
    }
    private let shared = Shared()
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
    var clockDriftCorrection = false
    var onUpdate: ((Update) -> Void)?

    init(outputDevice: AudioDeviceID, inputDevice: AudioDeviceID, micChannel: Int, sampleRate: Double, averaging: Averaging) throws {
        AudioDevice.setSampleRate(sampleRate, for: outputDevice)
        AudioDevice.setSampleRate(sampleRate, for: inputDevice)
        var pink = PinkNoise()
        let sh = shared, ref = refRing, mic = micRing
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        output = try OutputStream(device: outputDevice) { chans, frames in
            let m = sh.noiseMask.load(ordering: .relaxed)
            let g = Float(bitPattern: sh.noiseGain.load(ordering: .relaxed))
            let n = min(frames, 8192)
            for i in 0..<n { scratch[i] = m == 0 ? 0 : pink.next() * g }
            ref.write(scratch, n)
            for (c, buf) in chans.enumerated() {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if c < 64 && m & (1 << UInt64(c)) != 0 { for i in 0..<n { p[i] = scratch[i] } } else { for i in 0..<n { p[i] = 0 } }
            }
        }
        do {
            input = try InputStream(device: inputDevice) { chans, frames in
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

    /// Plays noise on `channels` (zero-based), or stops it with an empty set. A new channel set restarts the analysis.
    func setNoise(channels: Set<Int>, levelDBFS: Double = -12) {
        let m = channels.filter { $0 < 64 }.reduce(UInt64(0)) { $0 | (1 << UInt64($1)) }
        shared.noiseGain.store(Float(pow(10, levelDBFS / 20) * 2.2).bitPattern, ordering: .relaxed)
        let old = shared.noiseMask.exchange(m, ordering: .relaxed)
        if old != m { queue.async { self.restart() } }
    }

    func setAveraging(_ a: Averaging) { queue.async { self.analyzer.averaging = a } }

    /// Clears the averages. The delay stays, because it does not change while the engines run.
    func resetAverages() { queue.async { self.resetAnalyzers(); self.history = []; self.stableFrames = 0 } }

    private func resetAnalyzers() {
        analyzer.reset()
        impulseAnalyzer.reset()
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

        guard shared.noiseMask.load(ordering: .relaxed) != 0 else { return }
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

    private func findDelay() {
        lastDelaySearch = Date()
        let mLen = 1 << 15, rLen = 1 << 17
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
