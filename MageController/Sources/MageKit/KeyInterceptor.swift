// 按键拦截器：IOKit 独占（seize）MAGE 的 HID 设备，按配置执行动作
// seize 需要 root —— 由 mage-helper 守护进程承担

import Foundation
import CoreGraphics
import IOKit.hid

/// 一个可识别的按键
public enum MageKey: String, Codable, CaseIterable {
    case volumeUp = "volume_up"     // 右键
    case volumeDown = "volume_down" // 左键
    case playPause = "play_pause"   // Menu / 上 / 下（三键同码，见协议笔记）

    public var usage: (page: UInt32, usage: UInt32) {
        switch self {
        case .volumeUp:   return (0x0C, 0xE9)
        case .volumeDown: return (0x0C, 0xEA)
        case .playPause:  return (0x0C, 0xCD)
        }
    }
    public var displayName: String {
        switch self {
        case .volumeUp:   return "右键（音量+）"
        case .volumeDown: return "左键（音量-）"
        case .playPause:  return "Menu / 上 / 下"
        }
    }
}

/// 按键触发后的动作
public enum KeyAction: Codable, Equatable {
    case block                        // 屏蔽，什么都不做
    case shell(String)                // 执行 shell 命令
    case keystroke(key: String, modifiers: [String])  // 模拟快捷键，如 ("space", ["command"])

    private enum CodingKeys: String, CodingKey { case type, command, key, modifiers }
    private enum Kind: String, Codable { case block, shell, keystroke }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .block: self = .block
        case .shell: self = .shell(try c.decode(String.self, forKey: .command))
        case .keystroke:
            self = .keystroke(key: try c.decode(String.self, forKey: .key),
                              modifiers: try c.decode([String].self, forKey: .modifiers))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .block:
            try c.encode(Kind.block, forKey: .type)
        case .shell(let cmd):
            try c.encode(Kind.shell, forKey: .type)
            try c.encode(cmd, forKey: .command)
        case .keystroke(let key, let mods):
            try c.encode(Kind.keystroke, forKey: .type)
            try c.encode(key, forKey: .key)
            try c.encode(mods, forKey: .modifiers)
        }
    }
    public var summary: String {
        switch self {
        case .block: return "屏蔽"
        case .shell(let cmd): return "命令: \(cmd)"
        case .keystroke(let key, let mods):
            return "快捷键: \(mods.map { $0 + "+" }.joined())\(key)"
        }
    }
}

/// 配置文件模型：~/.config/mage-controller/config.json
public struct KeyConfig: Codable {
    public var keys: [String: KeyAction]
    /// 麦克风键动作（厂商通道 cmd 18 推送触发，默认模拟 F13 给语音输入工具用）
    public var micKey: KeyAction
    /// 按麦克风键后自动恢复设备麦克风（抵消固件自带的静音切换，语音输入必开）
    public var micAutoUnmute: Bool
    /// 按键拦截开关是否处于「用户已开启」状态（持久化；守护进程本身不随 App 重启）
    public var helperEnabled: Bool

    public init(keys: [String: KeyAction] = KeyConfig.defaults,
                micKey: KeyAction = .keystroke(key: "f13", modifiers: []),
                micAutoUnmute: Bool = true,
                helperEnabled: Bool = false) {
        self.keys = keys
        self.micKey = micKey
        self.micAutoUnmute = micAutoUnmute
        self.helperEnabled = helperEnabled
    }

    private enum CodingKeys: String, CodingKey { case keys, micKey, micAutoUnmute, helperEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.keys = try c.decodeIfPresent([String: KeyAction].self, forKey: .keys) ?? KeyConfig.defaults
        self.micKey = try c.decodeIfPresent(KeyAction.self, forKey: .micKey)
            ?? .keystroke(key: "f13", modifiers: [])
        self.micAutoUnmute = try c.decodeIfPresent(Bool.self, forKey: .micAutoUnmute) ?? true
        self.helperEnabled = try c.decodeIfPresent(Bool.self, forKey: .helperEnabled) ?? false
    }

    public static let defaults: [String: KeyAction] = [
        MageKey.volumeUp.rawValue: .block,
        MageKey.volumeDown.rawValue: .block,
        MageKey.playPause.rawValue: .block,
    ]
    public func action(for key: MageKey) -> KeyAction? {
        keys[key.rawValue]
    }
}

public final class KeyInterceptor {
    public enum State { case stopped, running, failed(String) }
    public private(set) var state: State = .stopped
    public var onLog: ((String) -> Void)?

    private var manager: IOHIDManager?
    private var config = KeyConfig()

    public init() {}

    public func updateConfig(_ config: KeyConfig) {
        self.config = config
        micAction = config.micKey
        micAutoUnmute = config.micAutoUnmute
    }

    /// 启动拦截（seize 设备）。必须在有 root 权限的进程中调用。
    public func start() -> Bool {
        stop()
        let m = IOHIDManagerCreate(kCFAllocatorDefault,
                                   IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: VendorChannel.vendorID] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard r == kIOReturnSuccess else {
            state = .failed("无法独占设备（需要 root）: 0x\(String(r, radix: 16))")
            return false
        }
        let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? []).filter {
            (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == VendorChannel.productName
        }
        guard !devices.isEmpty else {
            IOHIDManagerClose(m, 0)
            state = .failed("未找到 MAGE 设备")
            return false
        }
        // 不做 value matching，原始报告回调里自行过滤（value matching 可能干扰 report callback）
        IOHIDManagerRegisterInputValueCallback(m, KeyInterceptor.callback, Unmanaged.passUnretained(self).toOpaque())
        self.manager = m
        self.vendorDevice = devices.first
        if let dev = self.vendorDevice {
            let cb: IOHIDReportCallback = { _, _, _, _, reportId, report, length in
                KeyInterceptor.vendorReportCallback(reportId: reportId, report: report, length: length)
            }
            IOHIDDeviceRegisterInputReportCallback(dev, &vendorReportBuf, 64, cb, &callbackContext)
        }
        KeyInterceptor.active = self
        state = .running
        log("拦截已启动，设备按键将被接管")
        return true
    }

    public func stop() {
        if let m = manager {
            IOHIDManagerRegisterInputValueCallback(m, nil, nil)
            IOHIDManagerClose(m, 0)
            manager = nil
        }
        vendorDevice = nil
        KeyInterceptor.active = nil
        state = .stopped
    }

    private static let callback: IOHIDValueCallback = { ctx, _, _, value in
        guard let ctx else { return }
        Unmanaged<KeyInterceptor>.fromOpaque(ctx).takeUnretainedValue().handle(value)
    }

    private func handle(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(el)
        let usage = IOHIDElementGetUsage(el)
        guard page == 0x0C, IOHIDValueGetIntegerValue(value) != 0 else { return }  // 只在按下沿触发
        guard let key = MageKey.allCases.first(where: { $0.usage.usage == usage }) else { return }
        guard let action = config.action(for: key) else { return }
        log("拦截 \(key.displayName) → \(action.summary)")
        run(action: action)
    }

    /// 执行按键动作
    public func run(action: KeyAction) {
        switch action {
        case .block:
            break
        case .shell(let cmd):
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/zsh")
            t.arguments = ["-c", cmd]
            t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
            try? t.run()
        case .keystroke(let keyName, let mods):
            KeystrokeSimulator.post(key: keyName, modifiers: mods)
        }
    }

    // MARK: - 麦克风键（厂商通道 cmd 18 推送；独占模式下 HID 按键与厂商报告都归本进程）

    public private(set) var micAction: KeyAction = .keystroke(key: "f13", modifiers: [])
    public var micAutoUnmute = true

    private static var active: KeyInterceptor?
    private var vendorDevice: IOHIDDevice?
    private var vendorReportBuf = [UInt8](repeating: 0, count: 64)
    private var callbackContext = 0
    private var lastMicState = -1
    private var micStateKnown = false

    private static func vendorReportCallback(reportId: UInt32, report: UnsafeMutablePointer<UInt8>?, length: Int) {
        guard reportId == 7, let report, length > 0 else { return }
        KeyInterceptor.active?.handleVendorReport((0..<length).map { report[$0] })
    }

    private func handleVendorReport(_ bytes: [UInt8]) {
        guard let frame = MageProtocol.parseFrame(bytes) else { return }
        guard frame.cmd == MageProtocol.Cmd.micSwitch.rawValue else { return }
        let state = Int(frame.payload.first ?? 0)
        // 第一条 cmd 18 报告当作初始状态，避免启动时误触发
        if !micStateKnown {
            micStateKnown = true
            lastMicState = state
            return
        }
        guard state != lastMicState else { return }  // 状态没变 = 回声/重复
        lastMicState = state
        handleMicKeyPress()
    }

    private func handleMicKeyPress() {
        log("麦克风键 → \(micAction.summary)")
        run(action: micAction)
        if micAutoUnmute {
            // 发送即可，响应到达时 lastMicState 已是 1，会被状态守卫忽略
            vendorSendNoWait(cmd: .micSwitch, payload: [1], set: true)
            lastMicState = 1
        }
    }

    /// 发厂商命令（不等回包；在 RunLoop 线程上不能同步等待，否则收不到响应死锁）
    private func vendorSendNoWait(cmd: MageProtocol.Cmd, payload: [UInt8] = [], set: Bool = false) {
        guard let dev = vendorDevice else { return }
        let frame = MageProtocol.makeFrame(
            head: set ? MageProtocol.setHead : MageProtocol.getHead,
            start: set ? MageProtocol.setStart : MageProtocol.getStart,
            cmd: cmd.rawValue, payload: payload)
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 7
        for (i, b) in frame.enumerated() where i < 63 { report[i + 1] = b }
        var reportCopy = report
        _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 7, &reportCopy, 64)
    }

    private func log(_ s: String) { onLog?("[" + isoTime() + "] " + s) }
    private func isoTime() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

/// 模拟键盘快捷键：优先走虚拟键盘（硬件级事件，区分左右修饰键、可被 Typeless 直接录制），
/// 虚拟键盘不可用时退回 CGEvent
public enum KeystrokeSimulator {
    private static let vk = VirtualKeyboard()
    private static var vkReady = false
    private static let vkLock = NSLock()

    /// 键名 → HID 键盘 usage
    private static let keyUsage: [String: UInt8] = [
        "a": 0x04, "b": 0x05, "c": 0x06, "d": 0x07, "e": 0x08, "f": 0x09,
        "g": 0x0A, "h": 0x0B, "i": 0x0C, "j": 0x0D, "k": 0x0E, "l": 0x0F,
        "m": 0x10, "n": 0x11, "o": 0x12, "p": 0x13, "q": 0x14, "r": 0x15,
        "s": 0x16, "t": 0x17, "u": 0x18, "v": 0x19, "w": 0x1A, "x": 0x1B,
        "y": 0x1C, "z": 0x1D,
        "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22, "6": 0x23,
        "7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27,
        "return": 0x28, "enter": 0x28, "escape": 0x29, "backspace": 0x2A,
        "tab": 0x2B, "space": 0x2C,
        "left": 0x50, "right": 0x4F, "up": 0x52, "down": 0x51,
        "f1": 0x3A, "f2": 0x3B, "f3": 0x3C, "f4": 0x3D, "f5": 0x3E, "f6": 0x3F,
        "f7": 0x40, "f8": 0x41, "f9": 0x42, "f10": 0x43, "f11": 0x44, "f12": 0x45,
        "f13": 0x68, "f14": 0x69, "f15": 0x6A, "f16": 0x6B, "f17": 0x6C,
        "f18": 0x6D, "f19": 0x6E, "f20": 0x6F, "f21": 0x70, "f22": 0x71,
        "f23": 0x72, "f24": 0x73,
    ]

    /// 修饰键名 → 虚拟键盘修饰键字节（默认左侧，可显式指定 right_ 前缀）
    private static let modBits: [String: UInt8] = [
        "control": 0x01, "left_control": 0x01, "lctl": 0x01,
        "shift": 0x02, "left_shift": 0x02, "lshift": 0x02,
        "option": 0x04, "left_option": 0x04, "lopt": 0x04,
        "command": 0x08, "left_command": 0x08, "lcmd": 0x08,
        "right_control": 0x10, "rctl": 0x10,
        "right_shift": 0x20, "rshift": 0x20,
        "right_option": 0x40, "ropt": 0x40,
        "right_command": 0x80, "rcmd": 0x80,
    ]

    /// key 为空字符串 = 只按修饰键
    public static func post(key: String, modifiers: [String]) {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        var mods: UInt8 = 0
        for m in modifiers {
            if let b = modBits[m.trimmingCharacters(in: .whitespaces).lowercased()] { mods |= b }
        }
        let usage = k.isEmpty ? UInt8(0) : (keyUsage[k] ?? 0)

        if !k.isEmpty && usage == 0 {
            legacyPost(key: k, modifiers: modifiers)  // 未知键退回 CGEvent
            return
        }

        vkLock.lock()
        if !vkReady { vkReady = ((try? vk.start()) != nil) }
        let ready = vkReady
        vkLock.unlock()

        if ready {
            if k.isEmpty {
                vk.tap(modifiers: mods)
            } else {
                vk.tap(key: usage, modifiers: mods)
            }
        } else {
            legacyPost(key: k, modifiers: modifiers)
        }
    }

    // MARK: - CGEvent 退路（无左右侧信息）

    private static let legacyKeyMap: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "space": 49, "tab": 48, "escape": 53,
        "backspace": 51,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113,
        "left": 123, "right": 124, "up": 126, "down": 125,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "m": 46, "n": 45,
        "p": 35, "q": 12, "s": 1, "v": 9, "x": 7, "z": 6,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25, "0": 29,
    ]
    private static let legacyModMap: [String: CGEventFlags] = [
        "shift": .maskShift, "command": .maskCommand, "option": .maskAlternate,
        "control": .maskControl, "fn": .maskSecondaryFn,
        "left_shift": .maskShift, "left_command": .maskCommand,
        "left_option": .maskAlternate, "left_control": .maskControl,
        "right_shift": .maskShift, "right_command": .maskCommand,
        "right_option": .maskAlternate, "right_control": .maskControl,
    ]

    private static func legacyPost(key: String, modifiers: [String]) {
        var flags: CGEventFlags = []
        for m in modifiers {
            if let f = legacyModMap[m.trimmingCharacters(in: .whitespaces).lowercased()] { flags.insert(f) }
        }
        if key.isEmpty {
            // 纯修饰键：flagsChanged
            if let down = CGEvent(source: nil) {
                down.type = .flagsChanged
                down.flags = flags
                down.post(tap: .cghidEventTap)
            }
            usleep(60000)
            if let up = CGEvent(source: nil) {
                up.type = .flagsChanged
                up.flags = []
                up.post(tap: .cghidEventTap)
            }
            return
        }
        guard let code = legacyKeyMap[key] else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(20000)
        up?.post(tap: .cghidEventTap)
    }
}
