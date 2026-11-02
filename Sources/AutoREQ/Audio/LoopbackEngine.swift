import AutoREQCore
import CoreAudio
import Foundation
import os
import Synchronization

/// Captures system audio from a virtual device (for example BlackHole 2ch), applies the room correction
/// per output channel, and plays the result on the real speaker output.
final class LoopbackEngine: @unchecked Sendable {
    /// The processing of one output channel. The render thread owns the mutable state.
    final class Channel {
        let output: Int
        let source: InputSource
        let gain: Float
        var filters: [BiquadState]
        var delayLine: [Float]
        var delayPos = 0

        init(_ c: ChannelCorrection, sampleRate: Double, bypass: Bool) {
            output = c.outputChannel
            source = c.source
            var g = pow(10, c.gainDB / 20) * (c.inverted && !bypass ? -1 : 1)
            if bypass { g = pow(10, c.gainDB / 20) }
            gain = Float(g)
            var f = c.filters(sampleRate: sampleRate)
            // Bypass is level matched: it keeps the crossover and the gain, and drops EQ, delay and polarity.
            if bypass { f = c.crossover?.coefficients(sampleRate: sampleRate) ?? [] }
            filters = f.map(BiquadState.init)
            let d = bypass ? 0 : Int((c.delayMs / 1000 * sampleRate).rounded())
            delayLine = .init(repeating: 0, count: max(d, 0) + 1)
        }

        @inline(__always)
        func process(_ x: Float) -> Float {
            var y = Double(x)
            for k in filters.indices { y = filters[k].process(y) }
            delayLine[delayPos] = Float(y) * gain
            delayPos = (delayPos + 1) % delayLine.count
            return delayLine[delayPos]
        }
    }

    let sampleRate: Double
    private let input: InputStream
    private let output: OutputStream
    private let left = SampleRing(capacityPowerOfTwo: 1 << 16)
    private let right = SampleRing(capacityPowerOfTwo: 1 << 16)
    private let bank = OSAllocatedUnfairLock<[Channel]>(initialState: [])
    private final class Counter: @unchecked Sendable { let value = Atomic<Int>(0) }
    private let underruns = Counter()

    var outputChannelCount: Int { output.channelCount }
    var resyncCount: Int { underruns.value.load(ordering: .relaxed) }

    init(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID, sampleRate: Double) throws {
        AudioDevice.setSampleRate(sampleRate, for: inputDevice)
        AudioDevice.setSampleRate(sampleRate, for: outputDevice)
        let l = left, r = right
        input = try InputStream(device: inputDevice) { chans, frames in
            guard let p0 = chans[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let p1 = chans.count > 1 ? chans[1].mData?.assumingMemoryBound(to: Float.self) ?? p0 : p0
            l.write(p0, frames)
            r.write(p1, frames)
        }
        let bank = bank, underruns = underruns
        var current: [Channel] = []
        var readPos = -1
        do {
            output = try OutputStream(device: outputDevice) { chans, frames in
                if let next = bank.withLockIfAvailable({ $0 }) { current = next }
                for buf in chans { if let p = buf.mData?.assumingMemoryBound(to: Float.self) { for i in 0..<frames { p[i] = 0 } } }
                let written = l.count
                // ponytail: two device clocks drift apart; this jumps the read point back to the target latency
                // when it drifts out of range, which clicks about once per minute at worst. Upgrade: an adaptive resampler.
                let target = frames * 2 + 256
                if readPos < 0 || written - readPos < frames || written - readPos > target * 4 {
                    if readPos >= 0 { underruns.value.add(1, ordering: .relaxed) }
                    readPos = written - target
                }
                for ch in current where ch.output < chans.count {
                    guard let p = chans[ch.output].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames {
                        let a = l.sample(at: readPos + i), b = r.sample(at: readPos + i)
                        let x: Float = switch ch.source {
                        case .left: a
                        case .right: b
                        case .mono: (a + b) * 0.5
                        }
                        p[i] += ch.process(x)
                    }
                }
                readPos += frames
            }
        } catch {
            input.stop()
            throw error
        }
        self.sampleRate = output.sampleRate
    }

    /// Installs a new correction. With no corrections, the engine plays stereo straight through on channels 1 and 2.
    func apply(_ corrections: [ChannelCorrection], bypass: Bool) {
        var c = corrections
        if c.isEmpty {
            c = SystemTemplate.stereo.speakers.map { ChannelCorrection(speaker: $0, outputChannel: $0.outputChannel!) }
        }
        let channels = c.map { Channel($0, sampleRate: sampleRate, bypass: bypass) }
        bank.withLock { $0 = channels }
    }

    func stop() {
        input.stop()
        output.stop()
    }
}
