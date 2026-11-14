// 免拦截 v2：App 内完成按键自定义，替代旧的 seize + helper 双进程方案。
// 原理（POC 已实测验证，见项目 AGENTS.md 第七节）：
//   1. IOHIDManager 共享模式（不 seize）监听 MAGE 的 consumer 按键 —— 厂商通道保持在线；
//   2. CGEventTap 拦截 NSSystemDefined 媒体键事件，与 HID 命中做 300ms 时间窗相关性匹配：
//      判定为设备键 → 返回 nil 抑制（macOS 音量条/播放不触发）；否则放行（MacBook 音量键不受影响）。
// 踩坑记录（勿重犯）：
//   - run loop source 必须加 .defaultMode；
//   - 不要读 CGEvent 字段 46/47（本系统取不到值），必须用 NSEvent(cgEvent:) 读 subtype/data1；
//   - tap 被系统禁用后要 CGEvent.tapEnable 自动恢复。

import Foundation
import CoreGraphics
import AppKit
import IOKit.hid

public final class KeyTapV2 {
    public enum State { case stopped, running, failed(String) }

    public private(set) var state: State = .stopped
    public var onLog: ((String) -> Void)?
    public var onActionError: ((String) -> Void)?

    private var manager: IOHIDManager?
    private var tapPort: CFMachPort?
    /// 已订阅按键事件的设备（stop 时逐个关闭）
    private var openedDevices: [IOHIDDevice] = []
    private var config = KeyConfig()
    private var lastHIDUsage: UInt32 = 0
    private var lastHIDTime = Date.distantPast
    /// 最近 HID 命中对应的 NX 键码 + 时间（用于长按重复滑窗抑制）
    private var lastMatchKeyCode: Int?
    private var lastMatchTime = Date.distantPast
    /// 设备离线/切换期间为 true：抑制一切音量/播放媒体键（此期间媒体键几乎只可能是设备泄漏）
    public var suppressAllMediaKeys = false
    /// 放行诊断日志限频（连按洪水时最多 2 秒一条）
    private var lastLeakLogTime = Date.distantPast

    private static var active: KeyTapV2?

    public init() {}

    public func updateConfig(_ config: KeyConfig) {
        self.config = config
    }

    /// 启动失败时的原因（state == .failed）
    public var failureReason: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    @discardableResult
    public func start() -> Bool {
        stop()

        // 1) 共享模式监听 HID 按键（不 seize，厂商通道不受影响）
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, VendorChannel.deviceMatching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, 0)
        guard r == kIOReturnSuccess else {
            state = .failed("无法打开 MAGE 设备: 0x\(String(r, radix: 16))")
            return false
        }
        // 管理器级 value 回调对「打开时已连接」的设备不投递事件（必须重插才触发），
        // 改为设备匹配回调：对每台设备单独打开 + 订阅，已连接和热插拔都能收到。
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, KeyTapV2.deviceMatched, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, KeyTapV2.deviceRemoved, ctx)

        // 2) CGEventTap 抑制系统媒体键（mask 只收 systemDefined）
        let mask = CGEventMask(1 << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: KeyTapV2.tapCallback,
                                          userInfo: nil) else {
            IOHIDManagerClose(m, 0)
            state = .failed("无法创建事件监听（请在 系统设置 → 隐私与安全性 → 辅助功能 中允许本应用）")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        manager = m
        tapPort = tap
        KeyTapV2.active = self
        state = .running
        startTapHealthCheck()
        log("按键自定义已启动（免拦截 v2，App 内）")
        return true
    }

    /// tap 健康检查：系统会在高频事件时禁用 tap（tapDisabledByTimeout），
    /// 仅靠回调内恢复有漏网窗口；这里每 3 秒主动确认一次并恢复。
    private var healthTimer: DispatchSourceTimer?
    private func startTapHealthCheck() {
        healthTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self, let port = self.tapPort, self.state.isRunning else { return }
            if !CGEvent.tapIsEnabled(tap: port) {
                self.log("健康检查发现事件监听被禁用，自动恢复")
                CGEvent.tapEnable(tap: port, enable: true)
            }
        }
        t.resume()
        healthTimer = t
    }

    public func stop() {
        for device in openedDevices { unsubscribe(device) }
        openedDevices.removeAll()
        if let m = manager {
            IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
            IOHIDManagerClose(m, 0)
            manager = nil
        }
        healthTimer?.cancel()
        healthTimer = nil
        if let tap = tapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            tapPort = nil
        }
        if KeyTapV2.active === self { KeyTapV2.active = nil }
        state = .stopped
    }

    // MARK: - HID 共享监听（识别按键 + 触发用户自定义动作）

    /// 设备匹配（含启动时已在桌上的设备）→ 打开并订阅按键事件
    private static let deviceMatched: IOHIDDeviceCallback = { ctx, _, _, device in
        guard let ctx else { return }
        Unmanaged<KeyTapV2>.fromOpaque(ctx).takeUnretainedValue().subscribe(device)
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { ctx, _, _, device in
        guard let ctx else { return }
        Unmanaged<KeyTapV2>.fromOpaque(ctx).takeUnretainedValue().unsubscribe(device)
    }

    private func subscribe(_ device: IOHIDDevice) {
        guard !openedDevices.contains(where: { $0 === device }) else { return }
        // 同一进程里 VendorChannel 也开着设备；共享模式（0）可并存
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            log("订阅设备失败: 0x\(String(r, radix: 16))")
            return
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputValueCallback(device, KeyTapV2.hidCallback,
                                              Unmanaged.passUnretained(self).toOpaque())
        openedDevices.append(device)
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "MAGE"
        log("已订阅设备按键: \(name)")
    }

    private func unsubscribe(_ device: IOHIDDevice) {
        guard openedDevices.contains(where: { $0 === device }) else { return }
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        openedDevices.removeAll { $0 === device }
        log("设备已移除，取消订阅")
    }

    private static let hidCallback: IOHIDValueCallback = { ctx, _, _, value in
        guard let ctx else { return }
        Unmanaged<KeyTapV2>.fromOpaque(ctx).takeUnretainedValue().handleHID(value)
    }

    private func handleHID(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(el) == 0x0C else { return }
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }   // 只在按下沿触发
        let usage = IOHIDElementGetUsage(el)
        guard MageKey.allCases.contains(where: { $0.usage.usage == usage }) else { return }

        // 记录给 CGEventTap 做时间窗相关性匹配（判定「设备键」还是「外部键盘」）
        lastHIDUsage = usage
        lastHIDTime = Date()

        guard let key = MageKey.allCases.first(where: { $0.usage.usage == usage }),
              let action = config.action(for: key) else { return }
        log("\(key.displayName) → \(action.summary)")
        // 挪到串行后台队列执行：post 事件里的 usleep 会阻塞 main runloop，
        // 阻塞期间 HID 设备事件可能丢失（日志里偶发「按了没反应」）。
        Self.actionQueue.async { self.run(action: action) }
    }

    private static let actionQueue = DispatchQueue(label: "mage.keyaction")

    // MARK: - 系统事件抑制

    private static let tapCallback: CGEventTapCallBack = { _, type, event, _ in
        guard let active = KeyTapV2.active else { return Unmanaged.passRetained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            active.log("事件监听被系统禁用（type=\(type.rawValue)），尝试自动恢复")
            if let port = active.tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
                active.log("事件监听已恢复: \(CGEvent.tapIsEnabled(tap: port))")
            }
            return nil
        }
        guard type.rawValue == 14 else { return Unmanaged.passRetained(event) }  // systemDefined
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {   // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            return Unmanaged.passRetained(event)
        }
        let keyCode = (ns.data1 & 0xFFFF_0000) >> 16
        let flags = ns.data1 & 0xFFFF
        guard (flags & 0xFF00) == 0x0A00 else { return Unmanaged.passRetained(event) }  // 只处理按下沿

        let now = Date()

        // 1) HID 命中（300ms 窗口）—— 设备按下沿与系统事件时间相关
        if now.timeIntervalSince(active.lastHIDTime) < 0.3,
           KeyTapV2.nxKeyCode(forUsage: active.lastHIDUsage) == keyCode {
            active.lastMatchKeyCode = keyCode
            active.lastMatchTime = now
            active.log("系统媒体键 \(keyCode) ← 已抑制（设备键）")
            return nil                                            // 抑制：系统收不到
        }
        // 2) 同键长按重复：按住设备键时系统以 ~83ms 间隔自动重复发事件，
        //    HID 只有按下沿，500ms 后原匹配窗口过期会泄漏音量/播放——
        //    对同键码事件用 1.2s 滑窗续期抑制（代价：设备键后 1.2s 内按 MacBook 同功能键会丢一拍）
        if keyCode == active.lastMatchKeyCode,
           now.timeIntervalSince(active.lastMatchTime) < 1.2 {
            active.lastMatchTime = now
            return nil                                            // 抑制：不逐条记日志（12Hz 太吵）
        }
        // 3) 设备离线/切换期：全抑制音量/播放类（此时设备键洪水是唯一来源，防 Apple Music 弹出）
        if active.suppressAllMediaKeys && (keyCode == 0 || keyCode == 1 || keyCode == 16) {
            if now.timeIntervalSince(active.lastLeakLogTime) > 2 {
                active.lastLeakLogTime = now
                active.log("系统媒体键 \(keyCode) ← 已抑制（离线/切换期全抑制）")
            }
            return nil
        }
        // 音量/播放类事件未被匹配（放行）：频繁出现说明 HID 与系统事件不同步，需要排查
        if keyCode == 0 || keyCode == 1 || keyCode == 16 {
            if now.timeIntervalSince(active.lastLeakLogTime) > 2 {
                active.lastLeakLogTime = now
                active.log("系统媒体键 \(keyCode) ← 放行（未匹配设备键，lastUsage=0x\(String(active.lastHIDUsage, radix: 16))，窗口=\(String(format: "%.3f", now.timeIntervalSince(active.lastHIDTime)))s）")
            }
        }
        return Unmanaged.passRetained(event)                      // 放行：MacBook 音量键等
    }

    /// 设备 consumer usage → NX 系统媒体键码（POC 实测：0xE9 对应 SOUND_UP 事件）
    private static func nxKeyCode(forUsage usage: UInt32) -> Int? {
        switch usage {
        case 0xE9: return 0     // NX_KEYTYPE_SOUND_UP
        case 0xEA: return 1     // NX_KEYTYPE_SOUND_DOWN
        case 0xCD: return 16    // NX_KEYTYPE_PLAY（Menu/上/下同码）
        default: return nil
        }
    }

    // MARK: - 动作执行（与旧 KeyInterceptor 同语义）

    private func run(action: KeyAction) {
        switch action {
        case .block:
            break
        case .shell(let cmd):
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/bin/zsh")
            t.arguments = ["-c", cmd]
            t.standardOutput = FileHandle.nullDevice
            t.standardError = FileHandle.nullDevice
            do {
                try t.run()
            } catch {
                report("命令启动失败：\(error.localizedDescription)")
            }
        case .keystroke(let keyName, let mods):
            if case .failure(let error) = KeystrokeSimulator.post(key: keyName, modifiers: mods) {
                report("快捷键回放失败：\(error.localizedDescription)")
            }
        }
    }

    private func report(_ message: String) {
        log(message)
        onActionError?(message)
    }

    private func log(_ s: String) { onLog?("[" + isoTime() + "] " + s) }
    private func isoTime() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

extension KeyTapV2.State {
    var isRunning: Bool { if case .running = self { return true }; return false }
}
