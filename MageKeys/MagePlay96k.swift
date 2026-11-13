// MagePlay96k.swift
// 把 MAGE 临时设为默认输出，播放 96kHz 测试音约 8 秒，然后恢复原输出。
// 用途：观察模式指示灯随采样率变化（≤48k 浅蓝，>48k 黄色，DSD 绿色）

import Foundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)

func getDefaultOutput() -> AudioDeviceID {
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &dev)
    return dev
}

func setDefaultOutput(_ dev: AudioDeviceID) {
    var d = dev
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let r = AudioObjectSetPropertyData(system, &addr, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &d)
    print("设置默认输出 -> 设备 \(dev): \(r == noErr ? "OK" : "失败 \(r)")")
}

func deviceName(_ dev: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name)
    return name as String
}

func isOutputDevice(_ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return false }
    return size > 0
}

// 找 MAGE 的输出设备
var listAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size)
let count = Int(size) / MemoryLayout<AudioDeviceID>.size
var devices = [AudioDeviceID](repeating: 0, count: count)
AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &devices)

var mageOut: AudioDeviceID = 0
for dev in devices where deviceName(dev).uppercased().contains("MAGE") {
    if isOutputDevice(dev) { mageOut = dev; break }
}
guard mageOut != 0 else { fputs("没找到 MAGE 输出设备\n", stderr); exit(1) }
print("MAGE 输出设备: \(mageOut)")

let saved = getDefaultOutput()
print("当前默认输出: \(saved) (\(deviceName(saved)))")

setDefaultOutput(mageOut)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
let file = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/tone96k.wav"
task.arguments = ["-t", "10", file]
try? task.run()
print("正在播放 \(file)（约6秒），请看 MAGE 模式灯颜色…")
task.waitUntilExit()

setDefaultOutput(saved)
print("已恢复原输出设备。")
