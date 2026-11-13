import Darwin
import Foundation

public struct KeyConfigStore {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public func load() throws -> KeyConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KeyConfig.self, from: data)
    }

    public func save(_ config: KeyConfig) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
    }
}

public struct HelperStopPreferenceOutcome: Equatable {
    public static let persistenceFailureMessage =
        "按键拦截已停止，但关闭偏好未写入；下次启动将按磁盘中的旧偏好处理"

    public let helperEnabled: Bool
    public let message: String?

    public init(persistenceSucceeded: Bool) {
        if persistenceSucceeded {
            helperEnabled = false
            message = nil
        } else {
            helperEnabled = true
            message = Self.persistenceFailureMessage
        }
    }
}

public enum HelperStatusPresentation {
    public static func text(
        bindingMessage: String?,
        helperMessage: String?,
        transitioning: Bool,
        running: Bool,
        enabled: Bool
    ) -> String {
        if helperMessage == HelperStopPreferenceOutcome.persistenceFailureMessage {
            return HelperStopPreferenceOutcome.persistenceFailureMessage
        }
        if let bindingMessage { return bindingMessage }
        if let helperMessage { return helperMessage }
        if transitioning { return "正在更新按键拦截状态…" }
        if running { return "运行中，设备按键已接管" }
        if enabled { return "按键拦截未运行，请重试" }
        return "未开启"
    }
}

public struct HelperLaunchOptions: Equatable {
    public enum ParseError: Error, Equatable, LocalizedError {
        case missingValue(String)
        case unknownArgument(String)
        case relativePath(String)

        public var errorDescription: String? {
            switch self {
            case .missingValue(let argument): return "参数缺少路径：\(argument)"
            case .unknownArgument(let argument): return "未知参数：\(argument)"
            case .relativePath(let path): return "路径必须是绝对路径：\(path)"
            }
        }
    }

    public let configURL: URL
    public let pidFileURL: URL
    public let statusFileURL: URL

    public init(configURL: URL, pidFileURL: URL, statusFileURL: URL) throws {
        for url in [configURL, pidFileURL, statusFileURL] where !url.path.hasPrefix("/") {
            throw ParseError.relativePath(url.path)
        }
        self.configURL = configURL.standardizedFileURL
        self.pidFileURL = pidFileURL.standardizedFileURL
        self.statusFileURL = statusFileURL.standardizedFileURL
    }

    public init(arguments: [String], homeDirectoryURL: URL) throws {
        let configDefault = homeDirectoryURL
            .appendingPathComponent(".config/mage-controller/config.json")
        let runtimeDefault = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/MAGE Controller", isDirectory: true)
        var configURL = configDefault
        var pidFileURL = runtimeDefault.appendingPathComponent("mage-helper.pid")
        var statusFileURL = runtimeDefault.appendingPathComponent("mage-helper-status.json")

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard ["--config", "--pid-file", "--status-file"].contains(argument) else {
                throw ParseError.unknownArgument(argument)
            }
            guard index + 1 < arguments.count else { throw ParseError.missingValue(argument) }
            let value = arguments[index + 1]
            guard value.hasPrefix("/") else { throw ParseError.relativePath(value) }
            let url = URL(fileURLWithPath: value)
            switch argument {
            case "--config": configURL = url
            case "--pid-file": pidFileURL = url
            default: statusFileURL = url
            }
            index += 2
        }
        try self.init(configURL: configURL, pidFileURL: pidFileURL, statusFileURL: statusFileURL)
    }

    public var processArguments: [String] {
        [
            "--config", configURL.path,
            "--pid-file", pidFileURL.path,
            "--status-file", statusFileURL.path,
        ]
    }
}

public struct HelperStatusRecord: Codable, Equatable {
    public enum Kind: String, Codable {
        case running
        case info
        case actionError
    }

    public let kind: Kind
    public let message: String
    public let timestamp: Date

    public init(kind: Kind, message: String, timestamp: Date = Date()) {
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
    }
}

public struct HelperProcessIdentity: Equatable {
    public let pid: pid_t
    public let uid: uid_t
    public let executableURL: URL

    public init(pid: pid_t, uid: uid_t, executableURL: URL) {
        self.pid = pid
        self.uid = uid
        self.executableURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public enum HelperProcessInspector {
    public enum EnumerationError: Error, Equatable, LocalizedError {
        case queryFailed
        case processListKeptGrowing
        case bufferTooLarge

        public var errorDescription: String? {
            switch self {
            case .queryFailed:
                return "无法读取系统进程列表"
            case .processListKeptGrowing:
                return "系统进程列表持续变化，无法确认枚举完整"
            case .bufferTooLarge:
                return "系统进程列表超过可检查范围"
            }
        }
    }

    typealias ProcessListProvider = (UnsafeMutableRawPointer?, Int32) -> Int32

    public static func identity(for pid: pid_t) -> HelperProcessIdentity? {
        guard pid > 0 else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard pathLength > 0 else { return nil }

        var bsdInfo = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let infoSize = withUnsafeMutablePointer(to: &bsdInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard infoSize == expectedSize else { return nil }

        return HelperProcessIdentity(
            pid: pid,
            uid: bsdInfo.pbi_uid,
            executableURL: URL(fileURLWithPath: String(cString: pathBuffer))
        )
    }

    public static func identities(named executableName: String) throws -> [HelperProcessIdentity] {
        return try allProcessIDs()
            .compactMap(identity(for:))
            .filter { $0.executableURL.lastPathComponent == executableName }
    }

    public static func allProcessIDs() throws -> [pid_t] {
        try allProcessIDs { buffer, byteCount in
            proc_listallpids(buffer, byteCount)
        }
    }

    static func allProcessIDs(
        maxAttempts: Int = 3,
        listAllPIDs: ProcessListProvider
    ) throws -> [pid_t] {
        let initialCount = listAllPIDs(nil, 0)
        guard initialCount > 0 else { throw EnumerationError.queryFailed }

        var capacity = Int(initialCount) + 32
        for _ in 0..<maxAttempts {
            let (byteCapacity, overflow) = capacity.multipliedReportingOverflow(
                by: MemoryLayout<pid_t>.stride
            )
            guard !overflow, byteCapacity <= Int(Int32.max) else {
                throw EnumerationError.bufferTooLarge
            }

            var pids = [pid_t](repeating: 0, count: capacity)
            let returnedCount = pids.withUnsafeMutableBytes { buffer in
                listAllPIDs(buffer.baseAddress, Int32(buffer.count))
            }
            guard returnedCount > 0 else { throw EnumerationError.queryFailed }
            if returnedCount < capacity {
                return Array(pids.prefix(Int(returnedCount)))
            }
            capacity = max(capacity, Int(returnedCount)) + max(capacity / 2, 32)
        }
        throw EnumerationError.processListKeptGrowing
    }

    public static func matches(
        pid: pid_t,
        executableURL: URL,
        uid: uid_t = getuid()
    ) -> Bool {
        guard let identity = identity(for: pid) else { return false }
        return identity.uid == uid
            && identity.executableURL == executableURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}
