import AVFoundation
import CoreAudio

/// A CoreAudio device with its channel counts.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", name: string(id, kAudioObjectPropertyName) ?? "Device \(id)",
                        inputChannels: channels(id, kAudioObjectPropertyScopeInput), outputChannels: channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Sets the device's nominal sample rate. The input and the output device must run at the same rate.
    @discardableResult
    static func setSampleRate(_ rate: Double, for id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = Float64(rate)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r) == noErr
    }

    static func sampleRate(of id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r) == noErr ? r : nil
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// An output-only AVAudioEngine on one device. The render closure fills every hardware channel.
final class OutputStream {
    typealias Render = (_ channels: UnsafeMutableAudioBufferListPointer, _ frames: Int) -> Void
    let engine = AVAudioEngine()
    let channelCount: Int
    let sampleRate: Double

    init(device: AudioDeviceID, render: @escaping Render) throws {
        try engine.outputNode.auAudioUnit.setDeviceID(device)
        let hw = engine.outputNode.outputFormat(forBus: 0)
        channelCount = Int(hw.channelCount)
        sampleRate = hw.sampleRate
        let format = Self.format(rate: hw.sampleRate, channels: hw.channelCount)
        let src = AVAudioSourceNode(format: format) { _, _, frames, abl in
            render(UnsafeMutableAudioBufferListPointer(abl), Int(frames))
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.outputNode, format: format)
        try engine.start()
    }

    func stop() { engine.stop() }

    static func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)! }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }
}

/// An input-only AVAudioEngine on one device. The closure gets every hardware channel on the render thread.
final class InputStream {
    typealias Capture = (_ channels: UnsafeMutableAudioBufferListPointer, _ frames: Int) -> Void
    let engine = AVAudioEngine()
    let channelCount: Int
    let sampleRate: Double

    init(device: AudioDeviceID, capture: @escaping Capture) throws {
        try engine.inputNode.auAudioUnit.setDeviceID(device)
        let hw = engine.inputNode.inputFormat(forBus: 0)
        channelCount = Int(hw.channelCount)
        sampleRate = hw.sampleRate
        guard channelCount > 0 else { throw NSError(domain: "AutoREQ", code: 1, userInfo: [NSLocalizedDescriptionKey: "The input device has no input channels."]) }
        let sink = AVAudioSinkNode { _, frames, abl in
            capture(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl)), Int(frames))
            return noErr
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: OutputStream.format(rate: hw.sampleRate, channels: hw.channelCount))
        try engine.start()
    }

    func stop() { engine.stop() }
}

extension AudioDevice {
    /// True for an aggregate device from Audio MIDI Setup. Its sub-devices can have separate clocks.
    var isAggregate: Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type) == noErr else { return false }
        return type == kAudioDeviceTransportTypeAggregate
    }
}
