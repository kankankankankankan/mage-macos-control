// CoreAudio 控制：设备枚举、采样率读取/设置、默认输出切换
import Foundation
import CoreAudio

public struct AudioDeviceInfo: Identifiable {
    public let id: UInt32
    public let name: String
    public let transportType: UInt32?
    public let deviceUID: String?
    public let modelUID: String?
    public let isAlive: Bool
    public let hasInputStreams: Bool
    public let hasOutputStreams: Bool
    public let nominalSampleRate: Double?
    public let sampleRates: [Double]

    public var isOutput: Bool { hasOutputStreams }

    public init(
        id: UInt32,
        name: String,
        transportType: UInt32? = nil,
        deviceUID: String? = nil,
        modelUID: String? = nil,
        isAlive: Bool,
        hasInputStreams: Bool,
        hasOutputStreams: Bool,
        nominalSampleRate: Double?,
        sampleRates: [Double]
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.deviceUID = deviceUID
        self.modelUID = modelUID
        self.isAlive = isAlive
        self.hasInputStreams = hasInputStreams
        self.hasOutputStreams = hasOutputStreams
        self.nominalSampleRate = nominalSampleRate
        self.sampleRates = sampleRates
    }
}

public struct MageAudioRecoverySnapshot: Equatable {
    public let sampleRate: Double
    public let availableRates: [Double]

    public init(sampleRate: Double, availableRates: [Double]) {
        self.sampleRate = sampleRate
        self.availableRates = availableRates
    }
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
            guard let deviceName = name(of: dev), isMageDeviceName(deviceName) else { return nil }
            guard let transport = transportType(of: dev),
                  transport == kAudioDeviceTransportTypeUSB else { return nil }
            let output = hasStreams(dev, scope: kAudioDevicePropertyScopeOutput)
            let input = hasStreams(dev, scope: kAudioDevicePropertyScopeInput)
            guard output || input else { return nil }
            return AudioDeviceInfo(
                id: dev,
                name: deviceName,
                transportType: transport,
                deviceUID: stringProperty(
                    of: dev, selector: kAudioDevicePropertyDeviceUID
                ),
                modelUID: stringProperty(
                    of: dev, selector: kAudioDevicePropertyModelUID
                ),
                isAlive: isAlive(dev) == true,
                hasInputStreams: input,
                hasOutputStreams: output,
                nominalSampleRate: currentSampleRate(deviceID: dev),
                sampleRates: output ? availableRates(of: dev) : []
            )
        }
    }

    public static func outputDevice() -> AudioDeviceInfo? {
        mageDevices().first(where: { $0.isAlive && $0.isOutput })
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

    public static func currentSampleRate(device: AudioDeviceInfo) -> Double? {
        currentSampleRate(deviceID: device.id)
    }

    public static func recoverySnapshot(
        from devices: [AudioDeviceInfo]
    ) -> MageAudioRecoverySnapshot? {
        let liveDevices = devices.filter {
            $0.isAlive
                && isMageDeviceName($0.name)
                && $0.transportType == kAudioDeviceTransportTypeUSB
                && !($0.modelUID?.isEmpty ?? true)
        }
        let families = Dictionary(grouping: liveDevices, by: { $0.modelUID! })
        guard let family = families.values.first(where: { devices in
                  devices.contains(where: { $0.hasInputStreams })
                      && devices.contains(where: {
                          $0.hasOutputStreams && $0.nominalSampleRate != nil
                      })
              }),
              let output = family.first(where: {
                  $0.hasOutputStreams && $0.nominalSampleRate != nil
              }),
              let sampleRate = output.nominalSampleRate else {
            return nil
        }
        return MageAudioRecoverySnapshot(
            sampleRate: sampleRate,
            availableRates: output.sampleRates
        )
    }

    static func isMageDeviceName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(VendorChannel.productName) == .orderedSame
    }

    private static func currentSampleRate(deviceID: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    static func name(of dev: AudioDeviceID) -> String? {
        stringProperty(of: dev, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func stringProperty(
        of dev: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String
    }

    private static func transportType(of dev: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport
    }

    private static func isAlive(_ dev: AudioDeviceID) -> Bool? {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &alive) == noErr else {
            return nil
        }
        return alive != 0
    }

    private static func hasStreams(
        _ dev: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
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
