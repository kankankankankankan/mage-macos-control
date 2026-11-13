// MageLed.swift
//
// MAGE 厂商 HID 控制通道工具（report ID 0x07，协议逆向自 FIIO Control 网页版）
//
// 帧格式:  [HEAD][START][seqHi][seqLo][cmd][len][payload...][crc8][0xEE]
//   HEAD:  0xAA=设置 / 0xBB=查询    START: 0x0A/0x0B
//   crc8:  自定义 CRC-8（表见下，初值0，t=table[(t^byte)&255]）
//
// 用法:
//   ./mage-led status                  查询 LED 开关/麦克风状态，并监听 3 秒回包
//   ./mage-led led on|off              设置指示灯总开关
//   ./mage-led mic on|off              设置麦克风开关（等同麦克风键）
//   ./mage-led color <idx> <bri> <r> <g> <b> <mode>   尝试 RGB 控灯（LED_CTRL）

import Foundation
import IOKit.hid

// MARK: - CRC8 表（与 FIIO 网页版一致）
let crcTable: [UInt8] = [
    0,94,188,226,97,63,221,131,194,156,126,32,163,253,31,65,
    157,195,33,127,252,162,64,30,95,1,227,189,62,96,130,220,
    35,125,159,193,66,28,254,160,225,191,93,3,128,222,60,98,
    190,224,2,92,223,129,99,61,124,34,192,158,29,67,161,255,
    70,24,250,164,39,121,155,197,132,218,56,102,229,187,89,7,
    219,133,103,57,186,228,6,88,25,71,165,251,120,38,196,154,
    101,59,217,135,4,90,184,230,167,249,27,69,198,152,122,36,
    248,166,68,26,153,199,37,123,58,100,134,216,91,5,231,185,
    140,210,48,110,237,179,81,15,78,16,242,172,47,113,147,205,
    17,79,173,243,112,46,204,146,211,141,111,49,178,236,14,80,
    175,241,19,77,206,144,114,44,109,51,209,143,12,82,176,238,
    50,108,142,208,83,13,239,177,240,174,76,18,145,207,45,115,
    202,148,118,40,171,245,23,73,8,86,180,234,105,55,213,139,
    87,9,235,181,54,104,138,212,149,203,41,119,244,170,72,22,
    233,183,85,11,136,214,52,106,43,117,151,201,74,20,246,168,
    116,42,200,150,21,75,169,247,182,232,10,84,215,137,107,53]

func crc8(_ data: [UInt8]) -> UInt8 {
    var t: UInt8 = 0
    for b in data { t = crcTable[Int((t ^ b) & 255)] }
    return t
}

enum Frame {
    static let setHead: UInt8 = 0xAA, getHead: UInt8 = 0xBB
    static let setStart: UInt8 = 0x0A, getStart: UInt8 = 0x0B
    static let stop: UInt8 = 0xEE
    // 命令
    static let ledLight: UInt8 = 6      // LED 总开关
    static let micSwitch: UInt8 = 18    // 麦克风开关
    static let ledCtrl: UInt8 = 51      // LED RGB 控制
}

var seq: Int = 0
func makeFrame(head: UInt8, start: UInt8, cmd: UInt8, payload: [UInt8]) -> [UInt8] {
    let s = seq; seq += 1
    var body = [head, start, UInt8((s >> 8) & 255), UInt8(s & 255), cmd, UInt8(payload.count)] + payload
    body.append(crc8(body))
    body.append(Frame.stop)
    return body
}

// MARK: - 设备
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x2972] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
    fputs("打开 HID 管理器失败\n", stderr); exit(1)
}
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter {
    (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == "SNOWSKY MAGE"
}
guard let dev = devices.first else {
    fputs("未找到 MAGE，请插好设备。\n", stderr); exit(1)
}
guard IOHIDDeviceOpen(dev, 0) == kIOReturnSuccess else {
    fputs("打开设备失败（可能被其他程序占用，如 FIIO Control 网页）\n", stderr); exit(1)
}

// MARK: - 回包监听（直接收原始 input report）
var listenUntil = Date().addingTimeInterval(0)
let inputCallback: IOHIDReportCallback = { ctx, _, _, _, reportId, report, reportLength in
    guard Date() < listenUntil else { return }
    let bytes = (0..<reportLength).map { report[$0] }
    guard reportId == 7 else { return }
    var payload = bytes.count > 1 ? Array(bytes.dropFirst()) : []
    while payload.last == 0 { payload.removeLast() }
    print("<< 回包: \(payload.map { String(format: "%02X", $0) }.joined(separator: " "))")
}
var callbackContext = 0
var reportBuf = [UInt8](repeating: 0, count: 64)
IOHIDDeviceRegisterInputReportCallback(dev, &reportBuf, 64, inputCallback, &callbackContext)

func send(_ frame: [UInt8]) -> Bool {
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 7
    for (i, b) in frame.enumerated() where i < 63 { report[i + 1] = b }
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 7, &report, 64)
    print(">> 发送: \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))" +
          (r == kIOReturnSuccess ? "" : "  (失败 0x\(String(r, radix: 16)))"))
    return r == kIOReturnSuccess
}

func listen(_ seconds: TimeInterval) {
    listenUntil = Date().addingTimeInterval(seconds)
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false)
}

// MARK: - 命令行
let args = CommandLine.arguments
guard args.count > 1 else {
    print("用法: mage-led status | led on|off | mic on|off | color <idx> <bri> <r> <g> <b> <mode>")
    exit(0)
}

switch args[1] {
case "status":
    _ = send(makeFrame(head: Frame.getHead, start: Frame.getStart, cmd: Frame.ledLight, payload: []))
    _ = send(makeFrame(head: Frame.getHead, start: Frame.getStart, cmd: Frame.micSwitch, payload: []))
    listen(3)
case "led":
    guard args.count > 2, let v: UInt8 = args[2] == "on" ? 1 : (args[2] == "off" ? 0 : nil) else {
        fputs("用法: mage-led led on|off\n", stderr); exit(1)
    }
    _ = send(makeFrame(head: Frame.setHead, start: Frame.setStart, cmd: Frame.ledLight, payload: [v]))
    listen(2)
case "mic":
    guard args.count > 2, let v: UInt8 = args[2] == "on" ? 1 : (args[2] == "off" ? 0 : nil) else {
        fputs("用法: mage-led mic on|off\n", stderr); exit(1)
    }
    _ = send(makeFrame(head: Frame.setHead, start: Frame.setStart, cmd: Frame.micSwitch, payload: [v]))
    listen(2)
case "color":
    guard args.count > 7,
          let idx = UInt8(args[2]), let bri = UInt8(args[3]),
          let r = UInt8(args[4]), let g = UInt8(args[5]), let b = UInt8(args[6]),
          let mode = UInt8(args[7]) else {
        fputs("用法: mage-led color <idx> <bri> <r> <g> <b> <mode>\n", stderr); exit(1)
    }
    _ = send(makeFrame(head: Frame.setHead, start: Frame.setStart, cmd: Frame.ledCtrl,
                       payload: [idx, bri, r, g, b, mode]))
    listen(2)
case "71":
    guard args.count > 2, let v: UInt8 = args[2] == "on" ? 1 : (args[2] == "off" ? 0 : nil) else {
        fputs("用法: mage-led 71 on|off  (7.1 开关，切换后设备会重新枚举)\n", stderr); exit(1)
    }
    _ = send(makeFrame(head: Frame.setHead, start: Frame.setStart, cmd: 56, payload: [v]))
    listen(2)
case "scan":
    // 扫描 cmd 0...80：发查询帧，收集回包，摸清设备支持的命令空间
    let lo: UInt8 = args.count > 3 ? (UInt8(args[3]) ?? 0) : 0
    let hi: UInt8 = args.count > 4 ? (UInt8(args[4]) ?? 80) : 80
    for cmd: UInt8 in lo...hi {
        print(String(format: "--- CMD %d (0x%02X) ---", cmd, cmd))
        fflush(stdout)
        _ = send(makeFrame(head: Frame.getHead, start: Frame.getStart, cmd: cmd, payload: []))
        listen(0.3)
    }
case "raw":
    guard args.count > 2, let cmd = UInt8(args[2], radix: 16) ?? UInt8(args[2]) else {
        fputs("用法: mage-led raw <cmd十进制或十六进制> [payload字节...]\n", stderr); exit(1)
    }
    let payload = args.dropFirst(3).compactMap { UInt8($0) }
    _ = send(makeFrame(head: Frame.setHead, start: Frame.setStart, cmd: cmd, payload: payload))
    listen(3)
default:
    fputs("未知命令\n", stderr); exit(1)
}
