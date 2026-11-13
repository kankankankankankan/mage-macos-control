// MageMonitor.swift
// 播放指定文件期间，每 0.5 秒打印 MAGE 输出设备的实际流格式（采样率/位深/声道）
// 用法: ./mage-monitor /tmp/tone96k.wav
import Foundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)

func devName(_ dev: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name)
    return name as String
}

func getDefaultOutput() -> AudioDeviceID {
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &dev)
    return dev
}

func setDefaultOutput(_ dev: AudioDeviceID) {
    var d = dev
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d)
}

// 找 MAGE 输出设备
var listAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size)
let count = Int(size) / MemoryLayout<AudioDeviceID>.size
var devices = [AudioDeviceID](repeating: 0, count: count)
AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &devices)

var mageOut: AudioDeviceID = 0
for dev in devices where devName(dev).uppercased().contains("MAGE") {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var s: UInt32 = 0
    if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &s) == noErr, s > 0 {
        mageOut = dev
        print("MAGE 输出设备: \(dev)")
    } else {
        print("MAGE 非输出设备: \(dev)")
    }
}
guard mageOut != 0 else { fputs("没找到 MAGE 输出\n", stderr); exit(1) }

let file = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/tone96k.wav"
let saved = getDefaultOutput()
setDefaultOutput(mageOut)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
task.arguments = [file]
try? task.run()

var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
    mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
for i in 0..<16 {
    var fmt = AudioStreamBasicDescription()
    var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let r = AudioObjectGetPropertyData(mageOut, &fmtAddr, 0, nil, &fmtSize, &fmt)
    if r == noErr {
        print(String(format: "t=%.1fs 实际流: %.0f Hz / %d bit / %d ch",
                     Double(i) * 0.5, fmt.mSampleRate, fmt.mBitsPerChannel, fmt.mChannelsPerFrame))
    } else {
        print("t=\(Double(i)*0.5)s 读取流格式失败 \(r)")
    }
    if !task.isRunning { break }
    Thread.sleep(forTimeInterval: 0.5)
}
task.waitUntilExit()
setDefaultOutput(saved)
print("已恢复原输出。")
