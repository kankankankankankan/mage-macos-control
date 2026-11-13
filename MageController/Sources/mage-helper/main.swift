import Darwin
import Foundation
import MageKit

private func runHelper() -> Int32 {
    let options: HelperLaunchOptions
    do {
        options = try HelperLaunchOptions(
            arguments: Array(CommandLine.arguments.dropFirst()),
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
    } catch {
        fputs("mage-helper 参数错误：\(error.localizedDescription)\n", stderr)
        return 2
    }

    let fm = FileManager.default
    do {
        try fm.createDirectory(
            at: options.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: options.pidFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: options.statusFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: options.configURL.path) {
            let data = try JSONEncoder().encode(KeyConfig())
            try data.write(to: options.configURL, options: .atomic)
        }
    } catch {
        fputs("mage-helper 无法准备配置目录：\(error.localizedDescription)\n", stderr)
        return 3
    }

    func loadConfig() throws -> KeyConfig {
        let data = try Data(contentsOf: options.configURL)
        return try JSONDecoder().decode(KeyConfig.self, from: data)
    }

    func writeStatus(_ kind: HelperStatusRecord.Kind, _ message: String) {
        do {
            let record = HelperStatusRecord(kind: kind, message: message)
            let data = try JSONEncoder().encode(record)
            try data.write(to: options.statusFileURL, options: .atomic)
        } catch {
            fputs("mage-helper 无法写入状态：\(error.localizedDescription)\n", stderr)
        }
    }

    let initialConfig: KeyConfig
    do {
        initialConfig = try loadConfig()
    } catch {
        let message = "配置读取失败，helper 未启动：\(error.localizedDescription)"
        writeStatus(.actionError, message)
        fputs(message + "\n", stderr)
        return 4
    }

    let interceptor = KeyInterceptor()
    interceptor.onLog = { message in
        print(message)
        fflush(stdout)
    }
    interceptor.onActionError = { message in writeStatus(.actionError, message) }
    interceptor.updateConfig(initialConfig)

    guard interceptor.start() else {
        let message: String
        if case .failed(let detail) = interceptor.state {
            message = detail
        } else {
            message = "按键拦截启动失败"
        }
        writeStatus(.actionError, message)
        fputs(message + "\n", stderr)
        return 5
    }

    let ownPID = getpid()
    do {
        try Data("\(ownPID)\n".utf8).write(to: options.pidFileURL, options: .atomic)
    } catch {
        interceptor.stop()
        let message = "无法写入 helper PID：\(error.localizedDescription)"
        writeStatus(.actionError, message)
        fputs(message + "\n", stderr)
        return 6
    }

    let configDirectoryFD = open(options.configURL.deletingLastPathComponent().path, O_EVTONLY)
    var configSource: DispatchSourceFileSystemObject?
    if configDirectoryFD >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: configDirectoryFD,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            do {
                interceptor.updateConfig(try loadConfig())
                interceptor.onLog?("配置已重载")
                writeStatus(.info, "配置已重载")
            } catch {
                let message = "配置重载失败，继续使用上次有效配置：\(error.localizedDescription)"
                interceptor.onLog?(message)
                writeStatus(.actionError, message)
            }
        }
        source.setCancelHandler { close(configDirectoryFD) }
        source.resume()
        configSource = source
    } else {
        interceptor.onLog?("无法监听配置目录，运行期间的映射更新不会自动生效")
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let stopRunLoop = { CFRunLoopStop(CFRunLoopGetMain()) }
    interruptSource.setEventHandler(handler: stopRunLoop)
    terminateSource.setEventHandler(handler: stopRunLoop)
    interruptSource.resume()
    terminateSource.resume()

    writeStatus(.running, "按键拦截运行中")
    print("mage-helper 运行中，配置文件: \(options.configURL.path)，PID: \(ownPID)。")
    fflush(stdout)
    CFRunLoopRun()

    configSource?.cancel()
    interruptSource.cancel()
    terminateSource.cancel()
    interceptor.stop()
    if let pidText = try? String(contentsOf: options.pidFileURL, encoding: .utf8),
       pidText.trimmingCharacters(in: .whitespacesAndNewlines) == String(ownPID) {
        try? fm.removeItem(at: options.pidFileURL)
    }
    writeStatus(.info, "按键拦截已停止")
    return 0
}

exit(runHelper())
