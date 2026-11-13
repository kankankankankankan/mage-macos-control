// 软件虚拟键盘（IOHIDUserDevice）：把设备按键翻译成硬件级键盘事件
// 对 macOS 和任何应用来说与真实键盘无异：
//   - 修饰键区分左右（修饰键字节有独立比特）
//   - 支持 F13-F24 等完整键码
//   - 可被 Typeless 等应用直接录制/识别
// 这是 CGEvent 合成做不到的（CGEvent 无左右侧信息，且可能被应用过滤）
// 注意：IOHIDUserDevice 是 IOKit 半私有 API，SDK 无头文件，通过 dlsym 动态取符号

import Foundation
import IOKit.hid

public final class VirtualKeyboard {
    public enum VKError: Swift.Error {
        case apiUnavailable, createFailed, notRunning
    }

    private typealias CreateFn = @convention(c) (CFAllocator?, CFDictionary, IOOptionBits)
        -> UnsafeMutableRawPointer?
    private typealias ReportFn = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>, CFIndex)
        -> IOReturn

    private var device: UnsafeMutableRawPointer?
    private let createFn: CreateFn?
    private let reportFn: ReportFn?

    // 启动键盘协议描述符（8 字节报告）：
    // [0] 修饰键字节（左Ctrl/左Shift/左Opt/左Cmd/右Ctrl/右Shift/右Opt/右Cmd 各占 1 bit）
    // [1] 保留
    // [2...7] 6 键数组（按下键的 usage）
    private static let descriptor: [UInt8] = [
        0x05, 0x01,              // Usage Page (Generic Desktop)
        0x09, 0x06,              // Usage (Keyboard)
        0xA1, 0x01,              // Collection (Application)
        0x05, 0x07,              //   Usage Page (Keyboard/Keypad)
        0x19, 0xE0,              //   Usage Min (Left Control)
        0x29, 0xE7,              //   Usage Max (Right GUI)
        0x15, 0x00,              //   Logical Min (0)
        0x25, 0x01,              //   Logical Max (1)
        0x75, 0x01,              //   Report Size (1)
        0x95, 0x08,              //   Report Count (8)
        0x81, 0x02,              //   Input (Data, Variable, Absolute) ← 修饰键字节
        0x95, 0x01,              //   Report Count (1)
        0x75, 0x08,              //   Report Size (8)
        0x81, 0x01,              //   Input (Constant) ← 保留字节
        0x19, 0x00,              //   Usage Min (0)
        0x29, 0xE7,              //   Usage Max (231)
        0x15, 0x00,              //   Logical Min (0)
        0x25, 0xE7,              //   Logical Max (231)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x06,              //   Report Count (6)
        0x81, 0x00,              //   Input (Data, Array) ← 6 键数组
        0xC0                     // End Collection
    ]

    public init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        guard let handle,
              let createSym = dlsym(handle, "IOHIDUserDeviceCreate"),
              let reportSym = dlsym(handle, "IOHIDUserDeviceHandleReport") else {
            createFn = nil; reportFn = nil
            return
        }
        createFn = unsafeBitCast(createSym, to: CreateFn.self)
        reportFn = unsafeBitCast(reportSym, to: ReportFn.self)
    }

    public var isRunning: Bool { device != nil }

    /// 在系统中注册虚拟键盘设备
    public func start() throws {
        if device != nil { return }
        guard let createFn, let reportFn else { throw VKError.apiUnavailable }
        let props: [String: Any] = [
            kIOHIDVendorIDKey: 0x2972,
            kIOHIDProductIDKey: 0x4D4B,              // "MK"
            kIOHIDProductKey: "MAGE Virtual Keyboard",
            kIOHIDReportDescriptorKey: Data(Self.descriptor) as CFData,
            kIOHIDPrimaryUsagePageKey: 0x01,          // Generic Desktop
            kIOHIDPrimaryUsageKey: 0x06,              // Keyboard
            kIOHIDVersionNumberKey: 1,
            kIOHIDSerialNumberKey: "MAGE-VK-001",
            kIOHIDManufacturerKey: "MAGE Controller",
            kIOHIDLocationIDKey: 0x4D4B0001,
            "DoNotRemap": true,
        ]
        guard let d = createFn(kCFAllocatorDefault, props as CFDictionary, 0) else {
            throw VKError.createFailed
        }
        device = d
    }

    public func stop() {
        device = nil  // 释放即注销
    }

    private func sendReport(modifiers: UInt8, key: UInt8) throws {
        guard let dev = device, let reportFn else { throw VKError.notRunning }
        var report: [UInt8] = [modifiers, 0, key, 0, 0, 0, 0, 0]
        let r = report.withUnsafeBytes { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return reportFn(dev, base.assumingMemoryBound(to: UInt8.self), report.count)
        }
        guard r == kIOReturnSuccess else { throw VKError.createFailed }
    }

    /// 按一下普通键（usage 见 HID 键盘 usage 表，如 0x2C=空格、0x68=F13）
    public func tap(key usage: UInt8, modifiers: UInt8 = 0, holdMicros: useconds_t = 20000) {
        try? sendReport(modifiers: modifiers, key: usage)
        usleep(holdMicros)
        try? sendReport(modifiers: 0, key: 0)
    }

    /// 只按修饰键（如左⌥+左⌘+左⌃ = 0x04|0x08|0x01）
    public func tap(modifiers: UInt8, holdMicros: useconds_t = 60000) {
        try? sendReport(modifiers: modifiers, key: 0)
        usleep(holdMicros)
        try? sendReport(modifiers: 0, key: 0)
    }
}
