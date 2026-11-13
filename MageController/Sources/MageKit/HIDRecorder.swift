// 硬件键盘录制器：用 IOHIDManager 直接监听真实键盘（IOKit HID 层）
// 相比 NSEvent.addGlobalMonitorForEvents 的优势：
//   - 不受"输入监控"TCC 项控制（走的是 ListenEvent 授权，本机已授予）
//   - 修饰键能区分左右（0xE0-0xE7 独立 usage）
// 只在 App 里用于"录制"：按一次真实键盘（含组合键）→ 捕获键名+修饰键

import Foundation
import IOKit.hid

public final class HIDRecorder {
    public var onCapture: ((String, [String]) -> Void)?

    private var manager: IOHIDManager?
    private var mods: Set<String> = []
    private var comboMods: Set<String> = []

    public init() {}

    public var isRecording: Bool { manager != nil }

    public func start() {
        stop()
        mods = []
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 0x07] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(m, 0) == kIOReturnSuccess else { return }
        IOHIDManagerRegisterInputValueCallback(m, HIDRecorder.callback, Unmanaged.passUnretained(self).toOpaque())
        manager = m
    }

    public func stop() {
        if let m = manager {
            IOHIDManagerRegisterInputValueCallback(m, nil, nil)
            IOHIDManagerClose(m, 0)
            manager = nil
        }
    }

    private static let callback: IOHIDValueCallback = { ctx, _, _, value in
        guard let ctx else { return }
        Unmanaged<HIDRecorder>.fromOpaque(ctx).takeUnretainedValue().handle(value)
    }

    /// usage → 键名
    private static let names: [Int: String] = [
        0x04: "a", 0x05: "b", 0x06: "c", 0x07: "d", 0x08: "e", 0x09: "f",
        0x0A: "g", 0x0B: "h", 0x0C: "i", 0x0D: "j", 0x0E: "k", 0x0F: "l",
        0x10: "m", 0x11: "n", 0x12: "o", 0x13: "p", 0x14: "q", 0x15: "r",
        0x16: "s", 0x17: "t", 0x18: "u", 0x19: "v", 0x1A: "w", 0x1B: "x",
        0x1C: "y", 0x1D: "z",
        0x1E: "1", 0x1F: "2", 0x20: "3", 0x21: "4", 0x22: "5", 0x23: "6",
        0x24: "7", 0x25: "8", 0x26: "9", 0x27: "0",
        0x28: "return", 0x29: "escape", 0x2A: "backspace", 0x2B: "tab", 0x2C: "space",
        0x4F: "right", 0x50: "left", 0x51: "down", 0x52: "up",
        0x3A: "f1", 0x3B: "f2", 0x3C: "f3", 0x3D: "f4", 0x3E: "f5", 0x3F: "f6",
        0x40: "f7", 0x41: "f8", 0x42: "f9", 0x43: "f10", 0x44: "f11", 0x45: "f12",
        0x68: "f13", 0x69: "f14", 0x6A: "f15", 0x6B: "f16", 0x6C: "f17",
        0x6D: "f18", 0x6E: "f19", 0x6F: "f20", 0x70: "f21", 0x71: "f22",
        0x72: "f23", 0x73: "f24",
    ]

    /// 修饰键 usage → 带侧边的名字
    private static let modNames: [Int: String] = [
        0xE0: "left_control", 0xE1: "left_shift", 0xE2: "left_option", 0xE3: "left_command",
        0xE4: "right_control", 0xE5: "right_shift", 0xE6: "right_option", 0xE7: "right_command",
    ]

    private func handle(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(el) == 0x07 else { return }
        let usage = Int(IOHIDElementGetUsage(el))
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        if let mod = HIDRecorder.modNames[usage] {
            if pressed {
                mods.insert(mod)
                comboMods.insert(mod)   // 累积整段组合里出现过的修饰键
            } else {
                mods.remove(mod)
            }
            // 只按修饰键又全部松开 → 作为纯修饰键组合捕获
            if !pressed && mods.isEmpty {
                let captured = Array(comboMods).sorted()
                stop()
                onCapture?("", captured)
            }
            return
        }

        guard pressed, let name = HIDRecorder.names[usage] else { return }
        let captured = Array(comboMods.union(mods)).sorted()
        stop()
        onCapture?(name, captured)
    }
}
