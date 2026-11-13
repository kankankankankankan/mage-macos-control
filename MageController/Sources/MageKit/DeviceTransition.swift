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
