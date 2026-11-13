// MageKeys.swift
//
// FiiO MAGE（雪漫天 法师）USB HID 按键拦截/自定义守护进程
//
// 原理：以 kIOHIDOptionsTypeSeizeDevice 独占（seize）设备的 HID 接口，
// 这样系统（以及其他所有客户端）都收不到原始按键事件，
// 由本进程决定：忽略（屏蔽默认行为）或执行自定义 shell 命令。
//
// 用法：
//   1. 查询设备的 VID / PID：
//        system_profiler SPUSBDataType | grep -i -A 6 -E "fiio|xmos|mage"
//      （FiiO/XMOS 方案常见 VID = 0x20B1，以实际输出为准）
//   2. 编译：
//        swiftc MageKeys.swift -o mage-keys
//   3. 先识别每个键的 usage（打印所有事件，不做映射）：
//        sudo ./mage-keys --learn
//      依次按下 上/下/左/右/Menu/麦克风，记录打印出的 usagePage:usage
//   4. 编辑下方 keymap，然后正常运行：
//        sudo ./mage-keys
//
// 注意：seize 需要 root 权限（sudo）。按住设备上任意键可临时放行系统快捷键：
// 默认对 usagePage 0x07（键盘）和 0x0C（消费控制，音量/播放/静音等）感兴趣，
// 其余 report 一律原样转发，不会影响 USB 音频功能。

import Foundation
import IOKit.hid

// MARK: - 配置区 -----------------------------------------------------------

// 本机实测：SNOWSKY MAGE 的 VID 固定为 0x2972。
// 注意：PID 会随设备模式变化（实测见过 0x4022 / 0x4026），因此按厂商 ID + 产品名匹配。
let targetVendorID: Int = 0x2972   // FIIO
let targetProductID: Int = 0       // 0 = 不限制 PID

// 只监听这两个 usage page 的事件；其他所有 HID report 原样转发。
let watchedUsagePages: [Int] = [0x07, 0x0C]

// keymap: "usagePage:usage"（十进制） -> 自定义 shell 命令。
// 值为空字符串表示"屏蔽该键（什么都不做）"。
// 实测映射（report ID 3）：
//   右=12:233 音量+   左=12:234 音量-   Menu/上/下=12:205 播放暂停（上/下按住会连发）
//   麦克风键=无标准事件（走厂商通道 cmd 18，见 MageLed）
let keymap: [String: String] = [
    "12:233": "",                 // 右键（音量+）→ 屏蔽，自定义请改成命令
    "12:234": "",                 // 左键（音量-）→ 屏蔽
    "12:205": "",                 // Menu/上/下（play/pause）→ 屏蔽
    // 示例："12:233": "open -a Terminal",
]

let learnMode = CommandLine.arguments.contains("--learn")
let bootTime = Date()

// --seconds N：运行 N 秒后自动退出（配合 --learn 收集一段按键样本）
var runSeconds = 0
if let idx = CommandLine.arguments.firstIndex(of: "--seconds"),
   idx + 1 < CommandLine.arguments.count {
    runSeconds = Int(CommandLine.arguments[idx + 1]) ?? 0
}

// MARK: - 事件回调 ---------------------------------------------------------

func handleInput(_ context: UnsafeMutableRawPointer?,
                 _ result: IOReturn,
                 _ sender: UnsafeMutableRawPointer?,
                 _ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let pressed = IOHIDValueGetIntegerValue(value) != 0

    // 只在按下沿（非 learn 模式）触发，松开忽略
    guard pressed || learnMode else { return }

    let key = "\(usagePage):\(usage)"
    if learnMode {
        let name = usageName(usagePage: usagePage, usage: usage)
        let len = IOHIDValueGetLength(value)
        let bytes = (0..<len).map {
            String(format: "%02X", IOHIDValueGetBytePtr(value)[$0])
        }.joined(separator: " ")
        print(String(format: "[learn] t=%.1fs ", Date().timeIntervalSince(bootTime)) +
              "page=0x\(String(usagePage, radix: 16)) " +
              "usage=0x\(String(usage, radix: 16)) (\(usagePage):\(usage))" +
              (name.isEmpty ? "" : "  ≈ \(name)") +
              " value=\(IOHIDValueGetIntegerValue(value))" +
              " reportID=\(IOHIDElementGetReportID(element))" +
              (len > 0 ? "  bytes=[\(bytes)]" : ""))
        fflush(stdout)
        return
    }

    let name = usageName(usagePage: usagePage, usage: usage)
    guard let command = keymap[key] else { return }  // 未配置的键：直接吞掉
    print("[拦截] \(key)\(name.isEmpty ? "" : " (\(name))")" +
          (command.isEmpty ? " → 已屏蔽" : " → 执行: \(command)"))
    fflush(stdout)
    if command.isEmpty { return }                    // 配置为空：屏蔽

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", command]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
}

func usageName(usagePage: UInt32, usage: UInt32) -> String {
    if usagePage == 0x07 {
        let map: [UInt32: String] = [0x50: "left_arrow", 0x4F: "right_arrow",
                                     0x52: "up_arrow", 0x51: "down_arrow"]
        return map[usage] ?? ""
    }
    if usagePage == 0x0C {
        let map: [UInt32: String] = [0xE9: "volume_up", 0xEA: "volume_down",
                                     0xCD: "play/pause", 0xD9: "mic_mute"]
        return map[usage] ?? ""
    }
    return ""
}

// MARK: - 主流程 -----------------------------------------------------------

// --learn 模式只做被动监听（不需要 root）；正常运行才独占设备（需要 sudo）
let seizeOption = learnMode ? IOOptionBits(0) : IOOptionBits(kIOHIDOptionsTypeSeizeDevice)

let manager = IOHIDManagerCreate(kCFAllocatorDefault, seizeOption)

var matching: [String: Any] = [kIOHIDVendorIDKey: targetVendorID]
if targetProductID != 0 { matching[kIOHIDProductIDKey] = targetProductID }
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

IOHIDManagerRegisterInputValueCallback(manager, handleInput, nil)

if !learnMode {
    // 正常运行：只接收我们关心的 usage page，其余 report 原样留给系统
    for page in watchedUsagePages {
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDDeviceUsagePageKey: page,
        ] as CFDictionary)
    }
}
// learn 模式不设过滤：所有 report（含厂商 0xFF01 通道）全部打印

IOHIDManagerScheduleWithRunLoop(manager,
                                CFRunLoopGetCurrent(),
                                CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, seizeOption)
guard openResult == kIOReturnSuccess else {
    fputs("无法打开设备（错误码 0x\(String(openResult, radix: 16))）。" +
          "请检查 VID/PID 是否正确，并用 sudo 运行。\n", stderr)
    exit(1)
}

var rawDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
let devices = targetProductID == 0
    ? rawDevices.filter {
        (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == "SNOWSKY MAGE"
      }
    : rawDevices
rawDevices = devices
guard !devices.isEmpty else {
    fputs("没有匹配到设备。请插好 MAGE。\n", stderr)
    exit(1)
}

let detectedPID = IOHIDDeviceGetProperty(devices.first!,
                                         kIOHIDProductIDKey as CFString) as? Int ?? -1

print("已连接 PID=0x\(String(detectedPID, radix: 16))，共 \(devices.count) 个 HID 接口。" +
      (learnMode ? " --learn 模式：请依次按每个按键，观察输出。\n"
                 : "按键事件将被拦截，按 keymap 处理。\n"))

signal(SIGINT) { _ in exit(0) }
if runSeconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(runSeconds)) {
        exit(0)
    }
}
CFRunLoopRun()
