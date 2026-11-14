// 免拦截 v2 架构 POC：只读 HID 监听 + CGEventTap 抑制系统媒体键
// 验证点：
//  1. 共享模式（非 seize）打开 MAGE，HID 回调能收到音量/播放键（usage page 0x0C）
//  2. 300ms 时间窗内对应的系统媒体键事件被抑制（返回 nil），macOS 音量不弹
//  3. MacBook 自带音量键（无 HID 前置事件）正常放行
//  4. 全程无 seize，厂商通道不被独占
// 用法：swift run；首次需要在 系统设置→隐私与安全性→辅助功能 授权终端；
//       然后重插 MAGE，按设备键观察输出。

import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import IOKit.hid

// MARK: - 共享状态

final class State {
    static let shared = State()
    /// 最近一次 HID 监听事件（usage page 0x0C 的 usage + 时间）
    var lastHIDUsage: Int = -1
    var lastHIDTime = Date.distantPast
    var suppressCount = 0
    var passCount = 0
    var tapEventCount = 0
    var tapPort: CFMachPort?
}

func ts() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

/// stdout 重定向到文件后会块缓冲，定时 flush 保证日志实时可见
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in fflush(stdout) }

/// 设备 consumer 键 usage → NX_KEYTYPE 媒体键码
func nxKeyCode(forUsage usage: Int) -> Int? {
    switch usage {
    case 0xE9: return 0      // NX_KEYTYPE_SOUND_UP    ← 设备右键
    case 0xEA: return 1      // NX_KEYTYPE_SOUND_DOWN  ← 设备左键
    case 0xCD: return 16     // NX_KEYTYPE_PLAY        ← 设备 Menu/上/下
    default: return nil
    }
}

// MARK: - 1) 只读 HID 监听（共享模式，不 seize）

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)   // 0 = 不 seize
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x2972] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let hidCallback: IOHIDValueCallback = { _, _, _, value in
    let el = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el)
    let usage = IOHIDElementGetUsage(el)
    let v = IOHIDValueGetIntegerValue(value)
    guard page == 0x0C, v != 0 else { return }          // 只关心 consumer 页按下沿
    State.shared.lastHIDUsage = Int(usage)
    State.shared.lastHIDTime = Date()
    let name: String
    switch usage {
    case 0xE9: name = "右键/音量+"
    case 0xEA: name = "左键/音量-"
    case 0xCD: name = "Menu/上/下"
    default:   name = String(format: "0x%02X", usage)
    }
    print("[HID 监听] \(name) (usage=0x\(String(usage, radix: 16))) @\(ts())")
}

let ctx = Unmanaged.passUnretained(State.shared).toOpaque()
IOHIDManagerRegisterInputValueCallback(manager, hidCallback, ctx)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(0))  // 共享打开
print("[POC] HID manager 共享打开: \(openResult == kIOReturnSuccess ? "成功" : "失败 0x\(String(openResult, radix: 16))")")
if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
    for d in devices {
        let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
        let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? UInt32 ?? 0
        print("[POC] 发现设备: \(name) PID=0x\(String(pid, radix: 16))")
    }
}

// MARK: - 2) CGEventTap 抑制系统媒体键

let tapCallback: CGEventTapCallBack = { proxy, type, event, _ in
    // 权限被收回等情况下自动重新启用
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("[POC] tap 被禁用（type=\(type.rawValue)），尝试重新启用")
        if let port = State.shared.tapPort { CGEvent.tapEnable(tap: port, enable: true) }
        return nil
    }
    State.shared.tapEventCount += 1
    print("[tap 调试] 收到事件 type.rawValue=\(type.rawValue)（第 \(State.shared.tapEventCount) 个）")
    guard type.rawValue == 14 else { return Unmanaged.passRetained(event) }  // kCGEventSystemDefined

    // 通过 NSEvent 读系统定义事件的 subtype/data1（直接读 CGEvent 字段 46/47 在本系统上取不到值）
    if let ns = NSEvent(cgEvent: event) {
        print("[tap 调试] NSEvent subtype=\(ns.subtype.rawValue) data1=0x\(String(ns.data1, radix: 16)) data2=0x\(String(ns.data2, radix: 16))")
    } else {
        print("[tap 调试] NSEvent(cgEvent:) 转换失败")
        return Unmanaged.passRetained(event)
    }
    guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    else { return Unmanaged.passRetained(event) }

    let keyCode = (ns.data1 & 0xFFFF_0000) >> 16
    let flags = ns.data1 & 0xFFFF
    let pressed = (flags & 0xFF00) == 0x0A00          // 按下/重复沿
    let keyNames = [0: "音量+", 1: "音量-", 7: "静音", 16: "播放/暂停"]
    let keyName = keyNames[keyCode] ?? "key \(keyCode)"

    guard pressed else { return Unmanaged.passRetained(event) }   // 只处理按下沿

    // 与 HID 监听事件做时间窗相关性匹配
    let s = State.shared
    let match = nxKeyCode(forUsage: s.lastHIDUsage) == keyCode
        && Date().timeIntervalSince(s.lastHIDTime) < 0.3

    if match {
        s.suppressCount += 1
        print("[系统事件] \(keyName) ← 已抑制（设备键，第 \(s.suppressCount) 次）")
        return nil                                            // ← 抑制：系统收不到
    } else {
        s.passCount += 1
        print("[系统事件] \(keyName) ← 放行（外部键盘，第 \(s.passCount) 次）")
        return Unmanaged.passRetained(event)
    }
}

let eventMask = ~CGEventMask(0)   // 调试期监听全部事件类型
if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                               place: .headInsertEventTap,
                               options: .defaultTap,
                               eventsOfInterest: eventMask,
                               callback: tapCallback,
                               userInfo: nil) {
    State.shared.tapPort = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    print("[POC] tap source 已加入 defaultMode")
    let trusted = AXIsProcessTrusted()
    print("[POC] CGEventTap 已创建。辅助功能权限: \(trusted ? "已授权" : "未授权——请在系统设置中授权本终端后重启 POC")")
    print("[POC] 就绪。请重插 MAGE 后按设备键；按 MacBook 音量键应显示「放行」。")
    print("[POC] Ctrl+C 退出。\n")
} else {
    print("[POC] tap 创建失败：请先给终端「辅助功能」权限。")
}

CFRunLoopRun()
