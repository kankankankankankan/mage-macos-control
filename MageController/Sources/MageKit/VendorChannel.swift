// 厂商 HID 控制通道（report ID 0x07），线程安全的请求-响应封装
// 与 MageKeys/mage-led 相同的方案：专用线程跑 CFRunLoop 接收输入报告
// （IOHIDDeviceSetDispatchQueue 方案实测收不到报告）

import Foundation
import IOKit.hid

public final class VendorChannel: @unchecked Sendable {
    public static let vendorID = 0x2972
    public static let productName = "SNOWSKY MAGE"
    public static let virtualKeyboardVendorID = 0xF1F0

    public enum Error: Swift.Error {
        case deviceNotFound, openFailed(IOReturn), writeFailed(IOReturn), timeout
    }

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuf = [UInt8](repeating: 0, count: 64)

    private struct Pending {
        let sequence: UInt16
        let cmd: UInt8
        let fulfill: ([UInt8]) -> Void
    }

    private var pending: Pending?
    private var retiredSequences = Set<UInt16>()
    private let lock = NSLock()
    private let transactionQueue = DispatchQueue(label: "com.mage.vendorchannel.transactions")

    private final class IOThreadState {
        private let lock = NSLock()
        private var stopped = false
        private var loop: CFRunLoop?

        var runLoop: CFRunLoop? {
            lock.lock(); defer { lock.unlock() }
            return loop
        }

        func setRunLoop(_ runLoop: CFRunLoop?) {
            lock.lock()
            loop = runLoop
            lock.unlock()
        }

        func requestStop() {
            lock.lock()
            stopped = true
            let runLoop = loop
            lock.unlock()
            if let runLoop { CFRunLoopStop(runLoop) }
        }

        var shouldStop: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }
    }

    /// 设备主动推送（按键状态变化等）的回调，参数为 (cmd, payload)，在 IO 线程上调用
    public var onPush: ((UInt8, [UInt8]) -> Void)?

    private var pid = 0
    public var connectedPID: Int {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    private var ioThread: Thread?
    private var ioState: IOThreadState?

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return device != nil
    }

    public init() {}

    /// Matching is applied before IOHIDManagerOpen so seize cannot include
    /// another HID product from the same vendor.
    public static var deviceMatching: [String: Any] {
        [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductKey: productName,
        ]
    }

    /// 查找并打开设备（seize=true 独占；普通模式可与 FIIO Control 网页共存）
    @discardableResult
    public func open(seize: Bool = false) throws -> Bool {
        try transactionQueue.sync {
            closeSerialized()
            return try openSerialized(seize: seize)
        }
    }

    private func openSerialized(seize: Bool) throws -> Bool {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, VendorChannel.deviceMatching as CFDictionary)

        // 专用 IO 线程：把 manager 调度到本线程的 RunLoop 上并持续跑
        let ready = DispatchSemaphore(value: 0)
        let state = IOThreadState()
        let t = Thread {
            let rl = CFRunLoopGetCurrent()!
            IOHIDManagerScheduleWithRunLoop(m, rl, CFRunLoopMode.defaultMode.rawValue)
            state.setRunLoop(rl)
            ready.signal()
            while !state.shouldStop {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.0, false)
            }
            state.setRunLoop(nil)
        }
        t.name = "com.mage.vendorchannel.io"
        t.stackSize = 512 * 1024
        t.start()
        ready.wait()
        ioThread = t
        ioState = state
        manager = m

        let opts: IOOptionBits = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : 0
        guard IOHIDManagerOpen(m, 0) == kIOReturnSuccess else {
            closeSerialized()
            throw Error.openFailed(kIOReturnError)
        }
        let found = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? [])
        guard let dev = found.first else {
            closeSerialized()
            return false
        }

        let r = IOHIDDeviceOpen(dev, opts)
        guard r == kIOReturnSuccess else {
            closeSerialized()
            throw Error.openFailed(r)
        }

        lock.lock()
        device = dev
        pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
        lock.unlock()
        MageProtocol.resetSeq()

        let callback: IOHIDReportCallback = { context, _, _, _, reportId, report, length in
            guard let context else { return }
            let channel = Unmanaged<VendorChannel>.fromOpaque(context).takeUnretainedValue()
            guard reportId == 7, length > 0 else { return }
            channel.handleReport((0..<length).map { report[$0] })
        }
        IOHIDDeviceRegisterInputReportCallback(
            dev, &reportBuf, 64, callback, Unmanaged.passUnretained(self).toOpaque()
        )
        return true
    }

    private func handleReport(_ bytes: [UInt8]) {
        guard let frame = MageProtocol.parseDetailedFrame(bytes) else { return }
        lock.lock()
        if let p = pending, p.sequence == frame.sequence, p.cmd == frame.cmd {
            let fulfill = p.fulfill
            pending = nil
            lock.unlock()
            fulfill(frame.payload)
        } else if retiredSequences.remove(frame.sequence) != nil {
            // A timed-out response must never be mistaken for the next
            // request with the same command.
            lock.unlock()
        } else {
            lock.unlock()
            onPush?(frame.cmd, frame.payload)
        }
    }

    /// 发送命令并等待匹配的回包（可在任意线程调用）
    @discardableResult
    public func send(cmd: MageProtocol.Cmd, payload: [UInt8] = [],
                     set: Bool = false, timeout: TimeInterval = 1.5) throws -> [UInt8] {
        try transactionQueue.sync {
            try sendSerialized(cmd: cmd, payload: payload, set: set, timeout: timeout)
        }
    }

    private func sendSerialized(cmd: MageProtocol.Cmd, payload: [UInt8],
                                set: Bool, timeout: TimeInterval) throws -> [UInt8] {
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
        let sequence = UInt16(frame[2]) << 8 | UInt16(frame[3])

        let semaphore = DispatchSemaphore(value: 0)
        var result: [UInt8] = []
        var completed = false
        lock.lock()
        retiredSequences.remove(sequence)
        pending = Pending(sequence: sequence, cmd: cmd.rawValue) {
            self.lock.lock()
            result = $0
            completed = true
            self.lock.unlock()
            semaphore.signal()
        }
        lock.unlock()

        var reportCopy = report
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 7, &reportCopy, 64)
        guard r == kIOReturnSuccess else {
            clearPending(sequence: sequence)
            throw Error.writeFailed(r)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            if completed {
                let response = result
                lock.unlock()
                return response
            } else if pending?.sequence == sequence {
                pending = nil
                retiredSequences.insert(sequence)
            }
            lock.unlock()
            throw Error.timeout
        }
        return result
    }

    public func close() {
        transactionQueue.sync {
            closeSerialized()
        }
    }

    private func closeSerialized() {
        lock.lock()
        let state = ioState
        ioState = nil
        let dev = device
        device = nil
        pid = 0
        pending = nil
        retiredSequences.removeAll()
        lock.unlock()
        state?.requestStop()
        if let dev { IOHIDDeviceClose(dev, 0) }
        if let m = manager { IOHIDManagerClose(m, 0) }
        manager = nil
        ioThread = nil
    }

    private func clearPending(sequence: UInt16) {
        lock.lock()
        if pending?.sequence == sequence { pending = nil }
        lock.unlock()
    }

    deinit { close() }
}
