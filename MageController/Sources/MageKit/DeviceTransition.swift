import Foundation

public enum DeviceTransitionKind: Equatable {
    case deviceRestart
    case helperLifecycle
}

public final class DeviceTransitionInterlock: @unchecked Sendable {
    private let lock = NSLock()
    private var active: DeviceTransitionKind?

    public init() {}

    public func begin(_ transition: DeviceTransitionKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { return false }
        active = transition
        return true
    }

    public func finish(_ transition: DeviceTransitionKind) {
        lock.lock()
        defer { lock.unlock() }
        if active == transition { active = nil }
    }

    public var activeTransition: DeviceTransitionKind? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

public struct RecoveryDeadline: Equatable, Sendable {
    public let end: TimeInterval

    public init(start: TimeInterval, timeout: TimeInterval) {
        end = start + max(0, timeout)
    }

    public func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, end - now)
    }

    public func boundedDuration(
        at now: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval? {
        let duration = min(maximum, remaining(at: now))
        return duration > 0 ? duration : nil
    }

    public func contains(_ now: TimeInterval) -> Bool {
        now < end
    }
}

public struct DeviceRestartSnapshot: Equatable, Sendable {
    public let pid: Int
    public let ledOn: Bool
    public let micOn: Bool
    public let surround71: Bool
    public let sampleRate: Double
    public let availableRates: [Double]

    public init(
        pid: Int,
        ledOn: Bool,
        micOn: Bool,
        surround71: Bool,
        sampleRate: Double,
        availableRates: [Double]
    ) {
        self.pid = pid
        self.ledOn = ledOn
        self.micOn = micOn
        self.surround71 = surround71
        self.sampleRate = sampleRate
        self.availableRates = availableRates
    }
}

public enum DeviceRestartResult: Equatable, Sendable {
    case success(DeviceRestartSnapshot, elapsed: TimeInterval)
    case commandFailure(String)
    case recoveryFailure(String)
}

private enum DeviceRestartError: LocalizedError {
    case invalidStateResponse(MageProtocol.Cmd)

    var errorDescription: String? {
        switch self {
        case .invalidStateResponse(let command):
            return "设备读回 \(command.rawValue) 缺少首字节或包含非法状态值"
        }
    }
}

public struct DeviceRestartIO {
    public let sendRestart: (_ target: Bool) throws -> Void
    public let open: () throws -> Bool
    public let read: (_ command: MageProtocol.Cmd, _ timeout: TimeInterval) throws -> UInt8?
    public let connectedPID: () -> Int
    public let audioSnapshot: () -> MageAudioRecoverySnapshot?
    public let close: () -> Void

    public init(
        sendRestart: @escaping (_ target: Bool) throws -> Void,
        open: @escaping () throws -> Bool,
        read: @escaping (_ command: MageProtocol.Cmd, _ timeout: TimeInterval) throws -> UInt8?,
        connectedPID: @escaping () -> Int,
        audioSnapshot: @escaping () -> MageAudioRecoverySnapshot?,
        close: @escaping () -> Void
    ) {
        self.sendRestart = sendRestart
        self.open = open
        self.read = read
        self.connectedPID = connectedPID
        self.audioSnapshot = audioSnapshot
        self.close = close
    }
}

public struct DeviceRestartCoordinator {
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    public init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public func run(
        targetState: Bool,
        startedAt: TimeInterval,
        timeout: TimeInterval,
        retryDelay: TimeInterval,
        io: DeviceRestartIO,
        observe: (_ message: String) -> Void = { _ in }
    ) -> DeviceRestartResult {
        let deadline = RecoveryDeadline(start: startedAt, timeout: timeout)
        do {
            try io.sendRestart(targetState)
        } catch {
            return .commandFailure(error.localizedDescription)
        }

        guard deadline.contains(now()) else {
            io.close()
            return .recoveryFailure("命令发送或旧通道收尾超过成功判定窗口")
        }

        var lastObservation = "等待 USB/HID 重新枚举"
        while let delay = deadline.boundedDuration(at: now(), maximum: retryDelay) {
            sleep(delay)
            guard deadline.contains(now()) else { break }
            do {
                guard try io.open() else {
                    lastObservation = "尚未发现 SNOWSKY MAGE"
                    observe(lastObservation)
                    continue
                }
                guard deadline.contains(now()) else {
                    io.close()
                    break
                }

                guard let surroundTimeout = deadline.boundedDuration(
                    at: now(), maximum: 1.5
                ) else {
                    io.close()
                    break
                }
                let surround = try readBinaryState(
                    .channel71Switch, timeout: surroundTimeout, io: io
                )
                let observedPID = io.connectedPID()
                guard deadline.contains(now()) else {
                    io.close()
                    break
                }
                guard surround == targetState else {
                    lastObservation = "设备已出现，但 7.1 仍为 \(surround ? 1 : 0)"
                    observe(lastObservation)
                    io.close()
                    continue
                }

                guard let ledTimeout = deadline.boundedDuration(
                    at: now(), maximum: 1.5
                ) else {
                    io.close()
                    break
                }
                let led = try readBinaryState(
                    .ledLight, timeout: ledTimeout, io: io
                )
                guard let micTimeout = deadline.boundedDuration(
                    at: now(), maximum: 1.5
                ) else {
                    io.close()
                    break
                }
                let mic = try readBinaryState(
                    .micSwitch, timeout: micTimeout, io: io
                )
                guard let audio = io.audioSnapshot() else {
                    lastObservation = "HID 已恢复，USB 音频输出或输入接口仍未就绪"
                    observe(lastObservation)
                    io.close()
                    continue
                }
                guard deadline.contains(now()) else {
                    io.close()
                    break
                }

                return .success(DeviceRestartSnapshot(
                    pid: observedPID,
                    ledOn: led,
                    micOn: mic,
                    surround71: surround,
                    sampleRate: audio.sampleRate,
                    availableRates: audio.availableRates
                ), elapsed: now() - startedAt)
            } catch {
                lastObservation = error.localizedDescription
                observe(lastObservation)
                io.close()
            }
        }

        io.close()
        return .recoveryFailure(lastObservation)
    }

    private func readBinaryState(
        _ command: MageProtocol.Cmd,
        timeout: TimeInterval,
        io: DeviceRestartIO
    ) throws -> Bool {
        guard let raw = try io.read(command, timeout) else {
            throw DeviceRestartError.invalidStateResponse(command)
        }
        guard raw == 0 || raw == 1 else {
            throw DeviceRestartError.invalidStateResponse(command)
        }
        return raw == 1
    }
}
