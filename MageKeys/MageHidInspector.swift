// MageHidInspector.swift
//
// 枚举指定 VID/PID 设备的全部 HID 接口（IOHIDDevice），打印：
//   - 每个接口的 UsagePage / Usage（判断哪个是键盘/消费键，哪个是厂商控制通道）
//   - Report Descriptor 原始字节（逆向厂商协议用）
//   - 输入/输出/特性 report 的最大长度（判断能否给设备写数据，比如控灯）
//
// 用法：swiftc MageHidInspector.swift -o mage-hid-inspector && ./mage-hid-inspector

import Foundation
import IOKit.hid

let vendorID = 0x2972
let productID = 0

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
var matching: [String: Any] = [kIOHIDVendorIDKey: vendorID]
if productID != 0 { matching[kIOHIDProductIDKey] = productID }
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
    fputs("打开 HID 管理器失败\n", stderr); exit(1)
}

var devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
if productID == 0 {
    devices = devices.filter {
        (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == "SNOWSKY MAGE"
    }
}
guard !devices.isEmpty else {
    fputs("没有匹配到 HID 设备，请确认 MAGE 已连接。\n", stderr); exit(1)
}

func hex(_ data: Data, maxBytes: Int = 512) -> String {
    let shown = data.prefix(maxBytes)
    var s = shown.map { String(format: "%02X ", $0) }.joined()
    if data.count > maxBytes { s += "...(共 \(data.count) 字节)" }
    return s
}

for (i, dev) in devices.enumerated() {
    let prop: (String) -> Any? = { IOHIDDeviceGetProperty(dev, $0 as CFString) }

    let page = prop(kIOHIDDeviceUsagePageKey) as? Int ?? 0
    let usage = prop(kIOHIDDeviceUsageKey) as? Int ?? 0
    let maxIn = prop(kIOHIDMaxInputReportSizeKey) as? Int ?? 0
    let maxOut = prop(kIOHIDMaxOutputReportSizeKey) as? Int ?? 0
    let maxFeat = prop(kIOHIDMaxFeatureReportSizeKey) as? Int ?? 0

    let pageDesc = (0xFF00...0xFFFF).contains(page) ? "← 厂商自定义页（控制通道候选）" : ""
    print("═══ 接口 #\(i) ═══")
    print("  UsagePage = 0x\(String(page, radix: 16))  Usage = 0x\(String(usage, radix: 16)) \(pageDesc)")
    print("  MaxInputReport=\(maxIn)  MaxOutputReport=\(maxOut)  MaxFeatureReport=\(maxFeat)")

    if let desc = prop(kIOHIDReportDescriptorKey) as? Data {
        print("  ReportDescriptor (\(desc.count) 字节):")
        print("    \(hex(desc))")
    } else {
        print("  ReportDescriptor: 读取失败")
    }
    print("")
}

print("共 \(devices.count) 个 HID 接口。0xFF00-0xFFFF 的接口即厂商控制通道（FIIO Control 网页版走的就是它）。")
