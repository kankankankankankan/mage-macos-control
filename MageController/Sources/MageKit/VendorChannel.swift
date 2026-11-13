// 厂商 HID 控制通道（report ID 0x07），线程安全的请求-响应封装
// 与 MageKeys/mage-led 相同的方案：专用线程跑 CFRunLoop 接收输入报告
// （IOHIDDeviceSetDispatchQueue 方案实测收不到报告）

import Foundation
import IOKit.hid

public final class VendorChannel {
    public static let vendorID = 0x2972
    public static let productName = "SNOWSKY MAGE"

    public enum Error: Swift.Error {
        case deviceNotFound, openFailed(IOReturn), writeFailed(IOReturn), timeout
    }

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuf = [UInt8](repeating: 0, count: 64)
    private var callbackContext = 0

    private var pending: (cmd: UInt8, fulfill: ([UInt8]) -> Void)?
    private let lock = NSLock()

    /// 设备主动推送（按键状态变化等）的回调，参数为 (cmd, payload)，在 IO 线程上调用
    public var onPush: ((UInt8, [UInt8]) -> Void)?

    public private(set) var connectedPID: Int = 0

    private var ioThread: Thread?
    private var runLoop: CFRunLoop?
    private var stopRequested = false

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return device != nil
    }

    public init() {}

    /// 查找并打开设备（seize=true 独占，需要 root；普通模式可与 FIIO Control 网页共存）
    @discardableResult
    public func open(seize: Bool = false) throws -> Bool {
        close()
        stopRequested = false

        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: VendorChannel.vendorID] as CFDictionary)

        // 专用 IO 线程：把 manager 调度到本线程的 RunLoop 上并持续跑
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()!
            IOHIDManagerScheduleWithRunLoop(m, rl, CFRunLoopMode.defaultMode.rawValue)
            self.runLoop = rl
            ready.signal()
            while !self.stopRequested {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.0, false)
            }
            self.runLoop = nil
        }
        t.name = "com.mage.vendorchannel.io"
        t.stackSize = 512 * 1024
        t.start()
        ready.wait()
        ioThread = t
        manager = m

        let opts: IOOptionBits = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : 0
        guard IOHIDManagerOpen(m, 0) == kIOReturnSuccess else {
            IOHIDManagerClose(m, 0)
            manager = nil
            throw Error.openFailed(kIOReturnError)
        }
        let found = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? []).filter {
            (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == VendorChannel.productName
        }
        guard let dev = found.first else {
            IOHIDManagerClose(m, 0)
            manager = nil
            return false
        }

        let r = IOHIDDeviceOpen(dev, opts)
        guard r == kIOReturnSuccess else {
            IOHIDManagerClose(m, 0)
            manager = nil
            throw Error.openFailed(r)
        }

        VendorChannel.active = self
        device = dev
        connectedPID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
        MageProtocol.resetSeq()

        let callback: IOHIDReportCallback = { _, _, _, _, reportId, report, length in
            VendorChannel.sharedCallback(reportId: reportId, report: report, length: length)
        }
        IOHIDDeviceRegisterInputReportCallback(dev, &reportBuf, 64, callback, &callbackContext)
        return true
    }

    // C 回调无法直接捕获 self，用全局中转（同时只用一个通道）
    private static var active: VendorChannel?
    private static func sharedCallback(reportId: UInt32, report: UnsafeMutablePointer<UInt8>?, length: Int) {
        guard reportId == 7, let report, length > 0 else { return }
        active?.handleReport((0..<length).map { report[$0] })
    }

    private func handleReport(_ bytes: [UInt8]) {
        guard let frame = MageProtocol.parseFrame(bytes) else { return }
        lock.lock()
        if let p = pending, p.cmd == frame.cmd {
            let fulfill = p.fulfill
            pending = nil
            lock.unlock()
            fulfill(frame.payload)
        } else {
            lock.unlock()
            onPush?(frame.cmd, frame.payload)
        }
    }

    /// 发送命令并等待匹配的回包（可在任意线程调用）
    @discardableResult
    public func send(cmd: MageProtocol.Cmd, payload: [UInt8] = [],
                     set: Bool = false, timeout: TimeInterval = 1.5) throws -> [UInt8] {
        lock.lock()
        guard let dev = device else { lock.unlock(); throw Error.deviceNotFound }
        lock.unlock()

        let frame = MageProtocol.makeFrame(
            head: set ? MageProtocol.setHead : MageProtocol.getHead,
            start: set ? MageProtocol.setStart : MageProtocol.getStart,
            cmd: cmd.rawValue, payload: payload)

        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 7
        for (i, b) in frame.enumerated() where i < 63 { report[i + 1] = b }

        let semaphore = DispatchSemaphore(value: 0)
        var result: [UInt8] = []
        lock.lock()
        VendorChannel.active = self
        pending = (cmd.rawValue, { result = $0; semaphore.signal() })
        lock.unlock()

        var reportCopy = report
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 7, &reportCopy, 64)
        guard r == kIOReturnSuccess else {
            lock.lock(); pending = nil; lock.unlock()
            throw Error.writeFailed(r)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending = nil; lock.unlock()
            throw Error.timeout
        }
        return result
    }

    public func close() {
        stopRequested = true
        lock.lock(); let dev = device; device = nil; lock.unlock()
        if let dev { IOHIDDeviceClose(dev, 0) }
        if let m = manager { IOHIDManagerClose(m, 0) }
        manager = nil
        VendorChannel.active = nil
        ioThread = nil
    }

    deinit { close() }
}
