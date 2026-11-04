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
        engine.setSpectrum(channels: [0], banding: .oct3, averaging: .fifo32)
        engine.setNoise(channels: [0], levelDBFS: -20)
        try? await Task.sleep(for: .seconds(6))
        guard let u = last, let r = u.response else { engine.shutdown(); say("FAIL no response; status \(String(describing: last?.status))"); return 1 }
        let band = (FrequencyGrid.index(of: 50))...(FrequencyGrid.index(of: 15_000))
        let mag = r.magnitudeDB[band].reduce(0, +) / Double(band.count)
        let spread = (r.magnitudeDB[band].max() ?? 0) - (r.magnitudeDB[band].min() ?? 0)
        let coh = r.coherence[band].reduce(0, +) / Double(band.count)
        say(String(format: "rate %.0f  latency %d samples  mean %.2f dB  spread %.2f dB  coherence %.3f  mic rms %.1f dBFS  stability %.2f",
                   rate, r.latencySamples, mag, spread, coh, u.micRMSDB, u.stability))
        let probes = [30.0, 50, 100, 1000, 5000, 10_000, 15_000, 18_000]
        say("dB at " + probes.map { String(format: "%.0f Hz: %.2f", $0, r.magnitudeDB[FrequencyGrid.index(of: $0)]) }.joined(separator: ", "))
        // A loop-through device has a single peak at lag 0 and no reflections.
        var irOK = false
        if let ir = r.impulse, let peak = ir.samples.indices.max(by: { abs(ir.samples[$0]) < abs(ir.samples[$1]) }) {
            let refl = RoomAnalysis.reflections(ir)
            say(String(format: "impulse peak %.2f at %.2f ms, %d reflections", ir.samples[peak], ir.timeMs(peak), refl.count))
            irOK = abs(ir.timeMs(peak)) < 0.1 && refl.isEmpty
        } else {
            say("no impulse response")
        }

        // Pink noise has the same energy in each 1/3-octave band.
        let bands = Band.bands(.oct3)
        var rtaOK = false
        if let lv = u.spectrum[0] {
            let used = bands.indices.filter { bands[$0].centre >= 100 && bands[$0].centre <= 10_000 }
            let mean = used.map { lv[$0] }.reduce(0, +) / Double(used.count)
            let dev = used.map { abs(lv[$0] - mean) }.max() ?? 99
            say(String(format: "rta pink: band level %.1f dBFS, largest deviation %.2f dB (100 Hz–10 kHz)", mean, dev))
            rtaOK = dev < 1
        } else { say("no spectrum") }

        // A sine at -20 dBFS RMS reads -20 dB in its band.
        engine.setOutput(channels: [0], signal: SignalSettings(kind: .sine, frequency: 1000), levelDBFS: -20)
        engine.resetSpectrum()
        try? await Task.sleep(for: .seconds(2))
        let k = bands.firstIndex { abs($0.centre - 1000) < 1 }!
        let sineLevel = last?.spectrum[0]?[k] ?? -200
        say(String(format: "rta sine: 1 kHz band %.2f dB, status %@", sineLevel, last?.status.label ?? "-"))
        let sineOK = abs(sineLevel + 20) < 0.5 && last?.status == .tone

        // Periodic pink noise gives the impulse response with no window error.
        engine.setOutput(channels: [0], signal: SignalSettings(kind: .periodicPink), levelDBFS: -20)
        try? await Task.sleep(for: .seconds(6))
        engine.shutdown()
        var periodicOK = false
        if let ir = last?.response?.impulse, let peak = ir.samples.indices.max(by: { abs(ir.samples[$0]) < abs(ir.samples[$1]) }) {
            let refl = RoomAnalysis.reflections(ir)
            say(String(format: "periodic pink: impulse peak %.3f at %.2f ms, %d reflections", ir.samples[peak], ir.timeMs(peak), refl.count))
            periodicOK = abs(ir.timeMs(peak)) < 0.1 && refl.isEmpty && ir.samples[peak] > 0.8
        } else { say("periodic pink: no impulse response") }

        let ok = abs(mag) < 1 && spread < 2 && coh > 0.9 && irOK && rtaOK && sineOK && periodicOK
        say(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }
}
