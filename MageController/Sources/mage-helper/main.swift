// mage-helper：按键拦截守护进程（需要 root：sudo mage-helper）
// 读取 ~/.config/mage-controller/config.json，配置文件变更自动重载
import Foundation
import MageKit

let configPath = NSHomeDirectory() + "/.config/mage-controller/config.json"
let configURL = URL(fileURLWithPath: configPath)

func loadConfig() -> KeyConfig {
    guard let data = try? Data(contentsOf: configURL),
          let cfg = try? JSONDecoder().decode(KeyConfig.self, from: data) else {
        return KeyConfig()
    }
    return cfg
}

// 确保配置目录和默认配置存在
let fm = FileManager.default
let dir = configURL.deletingLastPathComponent()
if !fm.fileExists(atPath: dir.path) {
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
}
if !fm.fileExists(atPath: configPath),
   let data = try? JSONEncoder().encode(KeyConfig()) {
    try? data.write(to: configURL)
}

let interceptor = KeyInterceptor()
interceptor.onLog = { print($0); fflush(stdout) }
interceptor.updateConfig(loadConfig())

// 配置文件监听（写入后自动重载）
let fd = open(configPath, O_EVTONLY)
if fd >= 0 {
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                           eventMask: .write, queue: .main)
    source.setEventHandler {
        interceptor.updateConfig(loadConfig())
        interceptor.onLog?("配置已重载")
    }
    source.setCancelHandler { close(fd) }
    source.resume()
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

if !interceptor.start() {
    if case .failed(let msg) = interceptor.state { fputs(msg + "\n", stderr) }
    exit(1)
}

print("mage-helper 运行中，配置文件: \(configPath)，Ctrl+C 退出。")
fflush(stdout)
CFRunLoopRun()
