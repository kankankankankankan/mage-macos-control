// MageSetRate.swift
//
// 设置 MAGE 音频输出的采样率（观察指示灯颜色变化用）
// 用法：
//   swiftc MageSetRate.swift -o mage-set-rate
//   ./mage-set-rate 96000     # 切换到 96kHz，模式灯应变黄色（PCM>48k）
//   ./mage-set-rate 48000     # 切回 48kHz，应变浅蓝色
//   ./mage-set-rate           # 只打印当前支持的采样率列表

import Foundation
import CoreAudio

// 找到 MAGE 的音频输出设备
var deviceID: AudioDeviceID = 0
var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

// 先列出所有设备，找名字含 "MAGE" 的
var listAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

var deviceCount: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                               &listAddress, 0, nil, &deviceCount)
let numDevices = Int(deviceCount) / MemoryLayout<AudioDeviceID>.size
var devices = [AudioDeviceID](repeating: 0, count: numDevices)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                           &listAddress, 0, nil, &deviceCount, &devices)

for dev in devices {
    var name: CFString = "" as CFString
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, &name)
    let nameStr = name as String
    print("设备 \(dev): \(nameStr)")
    if nameStr.uppercased().contains("MAGE") {
        deviceID = dev
        var rAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(dev, &rAddr, 0, nil, &rSize)
        let n = Int(rSize) / MemoryLayout<AudioValueRange>.size
        var rs = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: n)
        AudioObjectGetPropertyData(dev, &rAddr, 0, nil, &rSize, &rs)
        print("  -> 采样率: \(rs.map { "\(Int($0.mMinimum))" }.joined(separator: ", "))")
    }
}

guard deviceID != 0 else {
    fputs("没找到 MAGE 音频设备（可能没选为输出，但仍应能枚举到）。\n", stderr)
    exit(1)
}

// 打印支持的采样率
var ratesAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var ratesSize: UInt32 = 0
AudioObjectGetPropertyDataSize(deviceID, &ratesAddr, 0, nil, &ratesSize)
let rateCount = Int(ratesSize) / MemoryLayout<AudioValueRange>.size
var rates = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
                              count: rateCount)
AudioObjectGetPropertyData(deviceID, &ratesAddr, 0, nil, &ratesSize, &rates)
print("支持的采样率: \(rates.map { "\(Int($0.mMinimum))" }.joined(separator: ", "))")

if CommandLine.arguments.count > 2, let dev = UInt32(CommandLine.arguments[1]) {
    deviceID = AudioDeviceID(dev)   // 显式指定设备
}
guard CommandLine.arguments.count > 1, let targetRate = Double(CommandLine.arguments.last!) else {
    exit(0)
}

var setAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyNominalSampleRate,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var rate = targetRate
let status = AudioObjectSetPropertyData(deviceID, &setAddr, 0, nil,
                                        UInt32(MemoryLayout<Double>.size), &rate)
if status != noErr {
    fputs("设置采样率失败，错误码 \(status)\n", stderr)
    exit(1)
}
print("已将 MAGE 采样率设置为 \(Int(targetRate)) Hz，看指示灯颜色变化。")
