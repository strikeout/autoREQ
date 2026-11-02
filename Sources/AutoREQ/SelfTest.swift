import AutoREQCore
import AVFoundation
import Foundation

/// Measures a loop-through device (for example VB-Cable or BlackHole) against itself.
/// A correct measurement chain reads about 0 dB with coherence near 1.
/// Run: `open -W --stdout out.txt build/AutoREQ.app --args --selftest "VB-Cable"`
@MainActor
enum SelfTest {
    static func run(deviceName: String) async -> Int32 {
        func say(_ s: String) { print(s); fflush(stdout) }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { say("FAIL microphone access denied"); return 1 }
        guard let dev = AudioDevice.all().first(where: { $0.name == deviceName && $0.inputChannels > 0 && $0.outputChannels > 0 }) else {
            say("FAIL no loop-through device named \(deviceName)"); return 1
        }
        let rate = AudioDevice.sampleRate(of: dev.id) ?? 48_000
        let engine: MeasurementEngine
        do { engine = try MeasurementEngine(outputDevice: dev.id, inputDevice: dev.id, micChannel: 0, sampleRate: rate, averaging: .fifo16) }
        catch { say("FAIL engine: \(error.localizedDescription)"); return 1 }
        var last: MeasurementEngine.Update?
        engine.onUpdate = { last = $0 }
        engine.setNoise(channels: [0], levelDBFS: -12)
        try? await Task.sleep(for: .seconds(6))
        engine.shutdown()
        guard let u = last, let r = u.response else { say("FAIL no response; status \(String(describing: last?.status))"); return 1 }
        let band = (FrequencyGrid.index(of: 50))...(FrequencyGrid.index(of: 15_000))
        let mag = r.magnitudeDB[band].reduce(0, +) / Double(band.count)
        let spread = (r.magnitudeDB[band].max() ?? 0) - (r.magnitudeDB[band].min() ?? 0)
        let coh = r.coherence[band].reduce(0, +) / Double(band.count)
        say(String(format: "rate %.0f  latency %d samples  mean %.2f dB  spread %.2f dB  coherence %.3f  mic rms %.1f dBFS  stability %.2f",
                   rate, r.latencySamples, mag, spread, coh, u.micRMSDB, u.stability))
        let probes = [30.0, 50, 100, 1000, 5000, 10_000, 15_000, 18_000]
        say("dB at " + probes.map { String(format: "%.0f Hz: %.2f", $0, r.magnitudeDB[FrequencyGrid.index(of: $0)]) }.joined(separator: ", "))
        let ok = abs(mag) < 1 && spread < 2 && coh > 0.9
        say(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }
}
