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
    public let helperEnabled: Bool
    public let message: String?

    public init(persistenceSucceeded: Bool) {
        if persistenceSucceeded {
            helperEnabled = false
            message = nil
        } else {
            helperEnabled = true
            message = "按键拦截已停止，但关闭偏好未写入；下次启动将按磁盘中的旧偏好处理"
        }
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

    public static func identities(named executableName: String) -> [HelperProcessIdentity] {
        return allProcessIDs()
            .compactMap(identity(for:))
            .filter { $0.executableURL.lastPathComponent == executableName }
    }

    public static func allProcessIDs() -> [pid_t] {
        var capacity = max(Int(proc_listallpids(nil, 0)), 1)
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let returnedCount = pids.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard returnedCount > 0 else { return [] }
            if returnedCount <= capacity {
                return Array(pids.prefix(Int(returnedCount)))
            }
            capacity = Int(returnedCount) + 32
        }
        return []
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
