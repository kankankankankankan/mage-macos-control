// 厂商 HID 控制通道（report ID 0x07），线程安全的请求-响应封装
// 与 MageKeys/mage-led 相同的方案：专用线程跑 CFRunLoop 接收输入报告
// （IOHIDDeviceSetDispatchQueue 方案实测收不到报告）

import Foundation
import IOKit.hid

final class VendorRunLoopWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var stopRequested = false
    private var cleanup: ((CFRunLoop) -> Void)?

    func start(setup: @escaping (CFRunLoop) -> Void) {
        let worker = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            setup(loop)

            lock.lock()
            runLoop = loop
            lock.unlock()
            ready.signal()

            while true {
                lock.lock()
                let shouldStop = stopRequested
                lock.unlock()
                if shouldStop { break }
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.0, false)
            }

            lock.lock()
            let cleanup = cleanup
            lock.unlock()
            cleanup?(loop)

            lock.lock()
            runLoop = nil
            thread = nil
            lock.unlock()
            finished.signal()
        }
        worker.name = "com.mage.vendorchannel.io"
        worker.stackSize = 512 * 1024

        lock.lock()
        precondition(thread == nil, "run-loop worker can only be started once")
        thread = worker
        lock.unlock()
        worker.start()
        ready.wait()
    }

    func stopAndWait(cleanup: @escaping (CFRunLoop) -> Void) {
        lock.lock()
        guard let worker = thread else {
            lock.unlock()
            return
        }
        self.cleanup = cleanup
        stopRequested = true
        let loop = runLoop
        let calledFromWorker = Thread.current === worker
        lock.unlock()

        if let loop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        }
        if !calledFromWorker {
            finished.wait()
        }
    }
}

public final class VendorChannel: @unchecked Sendable {
    public static let vendorID = 0x2972
    public static let productName = "SNOWSKY MAGE"
    public static let virtualKeyboardVendorID = 0xF1F0

    public enum Error: Swift.Error, LocalizedError {
        case deviceNotFound, openFailed(IOReturn), writeFailed(IOReturn), timeout

        public var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "未发现 SNOWSKY MAGE"
            case .openFailed(let code):
                return "无法打开 MAGE HID 通道（0x\(String(UInt32(bitPattern: code), radix: 16))）"
            case .writeFailed(let code):
                return "MAGE HID 命令写入失败（0x\(String(UInt32(bitPattern: code), radix: 16))）"
            case .timeout:
                return "MAGE HID 响应超时"
            }
        }
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
    private let lock = NSLock()
    private let transactionQueue = DispatchQueue(label: "com.mage.vendorchannel.transactions")

    /// 设备主动推送（按键状态变化等）的回调，参数为 (cmd, payload)，在 IO 线程上调用
    public var onPush: ((UInt8, [UInt8]) -> Void)?

    private var pid = 0
    public var connectedPID: Int {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    private var ioWorker: VendorRunLoopWorker?

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

        let worker = VendorRunLoopWorker()
        ioWorker = worker
        manager = m

        let opts: IOOptionBits = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : 0
        var openResult: Result<(IOHIDDevice, Int)?, Error>!
        worker.start { [unowned self] runLoop in
            IOHIDManagerScheduleWithRunLoop(m, runLoop, CFRunLoopMode.defaultMode.rawValue)

            let managerResult = IOHIDManagerOpen(m, 0)
            guard managerResult == kIOReturnSuccess else {
                openResult = .failure(.openFailed(managerResult))
                return
            }
            let found = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? [])
            guard let dev = found.first else {
                openResult = .success(nil)
                return
            }

            let deviceResult = IOHIDDeviceOpen(dev, opts)
            guard deviceResult == kIOReturnSuccess else {
                openResult = .failure(.openFailed(deviceResult))
                return
            }

            let callback: IOHIDReportCallback = { context, _, _, _, reportId, report, length in
                guard let context else { return }
                let channel = Unmanaged<VendorChannel>.fromOpaque(context).takeUnretainedValue()
                guard reportId == 7, length > 0 else { return }
                channel.handleReport((0..<length).map { report[$0] })
            }
            IOHIDDeviceRegisterInputReportCallback(
                dev, &reportBuf, 64, callback, Unmanaged.passUnretained(self).toOpaque()
            )
            let productID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
            openResult = .success((dev, productID))
        }

        let opened: (IOHIDDevice, Int)?
        switch openResult! {
        case .success(let result):
            opened = result
        case .failure(let error):
            closeSerialized()
            throw error
        }
        guard let (dev, productID) = opened else {
            closeSerialized()
            return false
        }

        lock.lock()
        device = dev
        pid = productID
        lock.unlock()
        MageProtocol.resetSeq()
        return true
    }

    private func handleReport(_ bytes: [UInt8]) {
        guard let frame = MageProtocol.parseDetailedFrame(bytes) else { return }
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
        try transactionQueue.sync {
            try sendSerialized(cmd: cmd, payload: payload, set: set, timeout: timeout)
        }
    }

    /// Write a command without treating a response as completion. Use this for
    /// commands that intentionally restart the USB device, then close this
    /// connection and verify the requested state through a new connection.
    public func sendWithoutResponse(cmd: MageProtocol.Cmd, payload: [UInt8] = [],
                                    set: Bool = false) throws {
        try transactionQueue.sync {
            let output = VendorChannel.makeOutputReport(cmd: cmd, payload: payload, set: set)
            try writeSerialized(output.report)
        }
    }

    private func sendSerialized(cmd: MageProtocol.Cmd, payload: [UInt8],
                                set: Bool, timeout: TimeInterval) throws -> [UInt8] {
        lock.lock()
        guard let dev = device else { lock.unlock(); throw Error.deviceNotFound }
        lock.unlock()

        let output = VendorChannel.makeOutputReport(cmd: cmd, payload: payload, set: set)
        let report = output.report
        let sequence = output.sequence

        let semaphore = DispatchSemaphore(value: 0)
        var result: [UInt8] = []
        var completed = false
        lock.lock()
        pending = Pending(sequence: sequence, cmd: cmd.rawValue) {
            self.lock.lock()
            result = $0
            completed = true
            self.lock.unlock()
            semaphore.signal()
        }
        lock.unlock()

        do {
            try writeSerialized(report, device: dev)
        } catch {
            clearPending(sequence: sequence)
            throw error
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            if completed {
                let response = result
                lock.unlock()
                return response
            } else if pending?.sequence == sequence {
                pending = nil
            }
            lock.unlock()
            // The device does not echo request sequence numbers. Retire the
            // entire connection after a timeout so a late response cannot be
            // delivered to a later request for the same command.
            closeSerialized()
            throw Error.timeout
        }
        return result
    }

    static func makeOutputReport(cmd: MageProtocol.Cmd, payload: [UInt8],
                                 set: Bool) -> (report: [UInt8], sequence: UInt16) {
        let frame = MageProtocol.makeFrame(
            head: set ? MageProtocol.setHead : MageProtocol.getHead,
            start: set ? MageProtocol.setStart : MageProtocol.getStart,
            cmd: cmd.rawValue, payload: payload)
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 7
        for (index, byte) in frame.enumerated() where index < 63 {
            report[index + 1] = byte
        }
        let sequence = UInt16(frame[2]) << 8 | UInt16(frame[3])
        return (report, sequence)
    }

    private func writeSerialized(_ report: [UInt8], device knownDevice: IOHIDDevice? = nil) throws {
        let dev: IOHIDDevice
        if let knownDevice {
            dev = knownDevice
        } else {
            lock.lock()
            guard let connectedDevice = device else {
                lock.unlock()
                throw Error.deviceNotFound
            }
            dev = connectedDevice
            lock.unlock()
        }

        var reportCopy = report
        let result = IOHIDDeviceSetReport(
            dev, kIOHIDReportTypeOutput, 7, &reportCopy, reportCopy.count
        )
        guard result == kIOReturnSuccess else { throw Error.writeFailed(result) }
    }

    public func close() {
        transactionQueue.sync {
            closeSerialized()
        }
    }

    private func closeSerialized() {
        lock.lock()
        let dev = device
        device = nil
        pid = 0
        pending = nil
        lock.unlock()

        let m = manager
        ioWorker?.stopAndWait { runLoop in
            if let m {
                IOHIDManagerUnscheduleFromRunLoop(
                    m, runLoop, CFRunLoopMode.defaultMode.rawValue
                )
            }
            if let dev { IOHIDDeviceClose(dev, 0) }
            if let m {
                IOHIDManagerClose(m, 0)
            }
        }
        ioWorker = nil
        manager = nil
    }

    private func clearPending(sequence: UInt16) {
        lock.lock()
        if pending?.sequence == sequence { pending = nil }
        lock.unlock()
    }

    deinit { close() }
}
