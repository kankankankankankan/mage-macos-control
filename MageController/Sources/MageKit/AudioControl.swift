// CoreAudio 控制：设备枚举、采样率读取/设置、默认输出切换
import Foundation
import CoreAudio

public struct AudioDeviceInfo: Identifiable {
    public let id: UInt32
    public let name: String
    public let isOutput: Bool
    public let sampleRates: [Double]
}

public enum AudioControl {
    public static func mageDevices() -> [AudioDeviceInfo] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &devices) == noErr else { return [] }

        return devices.compactMap { dev -> AudioDeviceInfo? in
            guard name(of: dev).uppercased().contains("MAGE") else { return nil }
            let out = hasOutputStreams(dev)
            return AudioDeviceInfo(id: dev, name: name(of: dev), isOutput: out,
                                   sampleRates: out ? availableRates(of: dev) : [])
        }
    }

    public static func outputDevice() -> AudioDeviceInfo? {
        mageDevices().first(where: { $0.isOutput })
    }

    @discardableResult
    public static func setSampleRate(_ rate: Double, device: AudioDeviceInfo) -> Bool {
        var d = device.id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var r = rate
        return AudioObjectSetPropertyData(d, &addr, 0, nil,
                                          UInt32(MemoryLayout<Double>.size), &r) == noErr
    }

    public static func currentSampleRate(device: AudioDeviceInfo) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &rate)
        return rate
    }

    static func name(of dev: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name)
        return name as String
    }

    static func hasOutputStreams(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func availableRates(of dev: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return [] }
        let n = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: n)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { $0.mMinimum }
    }
}
