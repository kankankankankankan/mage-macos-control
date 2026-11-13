// MAGE Controller 菜单栏 App
// 功能：设备状态显示、灯/麦克风/7.1 控制、采样率切换（触发灯色）、按键映射编辑、拦截守护进程管理
import SwiftUI
import Combine
import Darwin
import MageKit

// MARK: - 视图模型

func fileLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/.mage-controller.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

@MainActor
final class ControllerVM: ObservableObject {
    static let shared = ControllerVM()

    @Published var connected = false
    @Published var pid: Int = 0
    @Published var ledOn = false
    @Published var micOn = false
    @Published var surround71 = false
    @Published var sampleRate: Double = 0
    @Published var availableRates: [Double] = []
    @Published var helperRunning = false
    @Published var helperEnabled = false
    @Published var helperTransitioning = false
    @Published var helperStatusMessage: String?
    @Published var bindingStatusMessage: String?
    @Published var statusMessage = "未连接"

    private let channel = VendorChannel()
    private var pollWork: DispatchWorkItem?
    private var helperProcess: Process?
    private var helperLogHandle: FileHandle?
    private var helperStopRequested = false
    private var configReadFailed = false
    private var lastHelperStatusDate: Date?

    private static let homeURL = FileManager.default.homeDirectoryForCurrentUser
    private static let configURL = homeURL
        .appendingPathComponent(".config/mage-controller/config.json")
    private static let runtimeDirectoryURL = homeURL
        .appendingPathComponent("Library/Application Support/MAGE Controller", isDirectory: true)
    private static let helperPIDURL = runtimeDirectoryURL.appendingPathComponent("mage-helper.pid")
    private static let helperStatusURL = runtimeDirectoryURL
        .appendingPathComponent("mage-helper-status.json")
    private static let helperLogURL = homeURL
        .appendingPathComponent("Library/Logs/MAGE Controller/mage-helper.log")
    private var configStore: KeyConfigStore {
        KeyConfigStore(url: Self.configURL)
    }

    init() {
        helperEnabled = loadConfig().helperEnabled
        channel.onPush = { [weak self] cmd, payload in
            guard let self else { return }
            Task { @MainActor in self.handlePush(cmd: cmd, payload: payload) }
        }
        fileLog("App 启动，开始轮询设备")
        if CommandLine.arguments.contains("--open-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .openKeysWindow, object: nil)
            }
        }
        if CommandLine.arguments.contains("--record-mic") {
            // 先打开按键映射窗口，等窗口创建并激活后再开始录制（本地监听需要 key window）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .openKeysWindow, object: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                fileLog("CLI: 开始录制麦克风键绑定")
                KeyRecorder.shared.start(timeout: 600) { name, mods in
                    var cfg = self?.loadConfig() ?? KeyConfig()
                    cfg.micKey = .keystroke(key: name, modifiers: mods)
                    if self?.saveConfig(cfg) == true {
                        fileLog("CLI: 已保存 micKey = \(name) + \(mods.joined(separator: "+"))")
                    }
                }
            }
        }
        DispatchQueue.main.async { [weak self] in self?.restoreHelperIfNeeded() }
        poll()
    }

    @discardableResult
    func saveConfig(_ cfg: KeyConfig) -> Bool {
        guard !configReadFailed else {
            bindingStatusMessage = "配置读取失败，已停止写入；请修复 config.json 后重启应用"
            return false
        }
        do {
            try validateConfig(cfg)
            try configStore.save(cfg)
            bindingStatusMessage = nil
            return true
        } catch {
            bindingStatusMessage = "配置未保存：\(error.localizedDescription)"
            fileLog(bindingStatusMessage ?? "配置未保存")
            return false
        }
    }

    private func validateConfig(_ cfg: KeyConfig) throws {
        for action in Array(cfg.keys.values) + [cfg.micKey] {
            if case .keystroke(let key, let modifiers) = action {
                try KeystrokeSimulator.validate(key: key, modifiers: modifiers)
            }
        }
    }

    private func handlePush(cmd: UInt8, payload: [UInt8]) {
        switch MageProtocol.Cmd(rawValue: cmd) {
        case .micSwitch:
            let state = payload.first == 1
            // 自己 set 的响应走 pending 匹配，不会到这里；能到的都是物理按键推送
            guard state != micOn else { return }
            micOn = state
            micKeyPressed()
        case .ledLight: ledOn = payload.first == 1
        default: break
        }
    }

    /// 麦克风键被按下：执行配置的动作，并按需自动恢复设备麦克风
    private func micKeyPressed() {
        let cfg = loadConfig()
        fileLog("麦克风键 → \(cfg.micKey.summary)")
        switch cfg.micKey {
        case .block: break
        case .shell(let cmd): runShell(cmd)
        case .keystroke(let k, let mods):
            if case .failure(let error) = KeystrokeSimulator.post(key: k, modifiers: mods) {
                bindingStatusMessage = "快捷键执行失败：\(error.localizedDescription)"
                fileLog(bindingStatusMessage ?? "快捷键执行失败")
            }
        }
        if cfg.micAutoUnmute {
            let channel = channel
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                if let r = try? channel.send(cmd: .micSwitch, payload: [1], set: true) {
                    Task { @MainActor in self.micOn = r.first == 1 }
                }
            }
        }
    }

    func loadConfig() -> KeyConfig {
        guard FileManager.default.fileExists(atPath: Self.configURL.path) else {
            configReadFailed = false
            return KeyConfig()
        }
        do {
            let cfg = try configStore.load()
            configReadFailed = false
            return cfg
        } catch {
            configReadFailed = true
            bindingStatusMessage = "配置读取失败，已停止写入：\(error.localizedDescription)"
            fileLog(bindingStatusMessage ?? "配置读取失败")
            return KeyConfig()
        }
    }

    private func runShell(_ cmd: String) {
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/zsh")
        t.arguments = ["-c", cmd]
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        try? t.run()
    }

    func poll() {
        pollWork?.cancel()
        refreshHelperState()
        let work = DispatchWorkItem { [weak self] in self?.pollOnce() }
        pollWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func pollOnce() {
        do {
            if !channel.isConnected {
                _ = try channel.open()
            }
            let led = try channel.send(cmd: .ledLight).first ?? 0
            let mic = try channel.send(cmd: .micSwitch).first ?? 0
            let s71 = try channel.send(cmd: .channel71Switch).first ?? 0
            let wasConnected = self.connected
            Task { @MainActor in
                self.connected = true
                self.pid = self.channel.connectedPID
                self.ledOn = led == 1
                self.micOn = mic == 1
                self.surround71 = s71 == 1
                self.statusMessage = String(format: "已连接 PID=0x%04X", self.pid)
                fileLog("\(self.statusMessage) LED=\(led) MIC=\(mic) 7.1=\(s71)")
                if !wasConnected { fileLog("设备上线") }
                if let out = AudioControl.outputDevice() {
                    self.sampleRate = AudioControl.currentSampleRate(device: out)
                    self.availableRates = out.sampleRates
                }
                self.poll()
            }
        } catch {
            Task { @MainActor in
                self.connected = false
                self.statusMessage = "未连接（等待设备）"
                fileLog("设备离线: \(error.localizedDescription)")
                self.channel.close()
                self.poll()
            }
        }
    }

    func toggleLED() { runSet(.ledLight, value: ledOn ? 0 : 1, update: { self.ledOn = $0 == 1 }) }
    func toggleMic() { runSet(.micSwitch, value: micOn ? 0 : 1, update: { self.micOn = $0 == 1 }) }

    func toggle71() {
        // 切换 7.1 设备会重新枚举：发送命令后等待重连再刷新
        runSet(.channel71Switch, value: surround71 ? 0 : 1, update: { _ in })
        statusMessage = "正在切换 7.1（设备重新枚举）…"
        let channel = channel
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in
            channel.close()
            Task { @MainActor in self?.poll() }
        }
    }

    func setRate(_ rate: Double) {
        guard let out = AudioControl.outputDevice() else { return }
        if AudioControl.setSampleRate(rate, device: out) {
            sampleRate = rate
        }
    }

    private func runSet(_ cmd: MageProtocol.Cmd, value: UInt8,
                        update: @escaping (UInt8) -> Void) {
        let channel = channel
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let r = try channel.send(cmd: cmd, payload: [value], set: true).first ?? value
                Task { @MainActor in update(r) }
            } catch {
                Task { @MainActor in self.statusMessage = "命令失败: \(error)" }
            }
        }
    }

    // MARK: 按键拦截 helper（当前用户进程）

    var helperPath: String {
        helperURL?.path ?? ""
    }

    private var helperURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("mage-helper")
            .standardizedFileURL
    }

    private var helperOptions: HelperLaunchOptions? {
        guard let options = try? HelperLaunchOptions(
            configURL: Self.configURL,
            pidFileURL: Self.helperPIDURL,
            statusFileURL: Self.helperStatusURL
        ) else { return nil }
        return options
    }

    private func controlledHelperPID() -> pid_t? {
        guard let executableURL = helperURL else { return nil }
        if let process = helperProcess,
           process.isRunning,
           HelperProcessInspector.matches(
               pid: process.processIdentifier,
               executableURL: executableURL
           ) {
            return process.processIdentifier
        }
        guard let text = try? String(contentsOf: Self.helperPIDURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              HelperProcessInspector.matches(pid: pid, executableURL: executableURL) else {
            return nil
        }
        return pid
    }

    private func refreshHelperState() {
        helperRunning = controlledHelperPID() != nil
        refreshHelperStatus()
        if helperEnabled && !helperRunning && !helperTransitioning && helperStatusMessage == nil {
            helperStatusMessage = "按键拦截未运行，请重试"
        }
    }

    private func refreshHelperStatus() {
        guard let data = try? Data(contentsOf: Self.helperStatusURL),
              let record = try? JSONDecoder().decode(HelperStatusRecord.self, from: data),
              lastHelperStatusDate == nil || record.timestamp > lastHelperStatusDate! else { return }
        lastHelperStatusDate = record.timestamp
        if record.kind == .actionError {
            bindingStatusMessage = record.message
        }
    }

    private func setHelperEnabled(_ on: Bool) -> Bool {
        var cfg = loadConfig()
        cfg.helperEnabled = on
        guard saveConfig(cfg) else { return false }
        helperEnabled = on
        return true
    }

    private func restoreHelperIfNeeded() {
        refreshHelperState()
        if !helperRunning, let message = unmanagedHelperMessage() {
            helperStatusMessage = message
            return
        }
        guard helperEnabled && !helperRunning else { return }
        startHelper(persistPreference: false)
    }

    func toggleHelper() {
        guard !helperTransitioning else { return }
        refreshHelperState()
        if helperRunning {
            stopHelper(persistPreference: true)
        } else {
            startHelper(persistPreference: true)
        }
    }

    private func startHelper(persistPreference: Bool) {
        guard let executableURL = helperURL, let options = helperOptions else {
            helperStatusMessage = "按键拦截启动失败：无法解析 helper 路径"
            return
        }
        guard FileManager.default.fileExists(atPath: executableURL.path),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            helperStatusMessage = "按键拦截启动失败：缺少可执行文件 Contents/MacOS/mage-helper"
            return
        }

        if let message = unmanagedHelperMessage() {
            helperStatusMessage = message
            return
        }

        helperTransitioning = true
        helperStatusMessage = "正在启动按键拦截…"
        bindingStatusMessage = nil
        do {
            try FileManager.default.createDirectory(
                at: Self.runtimeDirectoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: Self.helperLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: Self.helperLogURL.path) {
                FileManager.default.createFile(atPath: Self.helperLogURL.path, contents: nil)
            }
            let logHandle = try FileHandle(forWritingTo: Self.helperLogURL)
            try logHandle.seekToEnd()

            let process = Process()
            process.executableURL = executableURL
            process.arguments = options.processArguments
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self, weak process] terminated in
                guard let process else { return }
                Task { @MainActor in
                    guard let self, self.helperProcess === process else { return }
                    let requested = self.helperStopRequested
                    self.helperProcess = nil
                    try? self.helperLogHandle?.close()
                    self.helperLogHandle = nil
                    self.helperRunning = false
                    self.refreshHelperStatus()
                    // stopHelper owns requested transitions until PID/path verification confirms exit.
                    if !requested {
                        self.helperTransitioning = false
                        self.helperStopRequested = false
                        self.helperStatusMessage = "按键拦截异常退出（状态 \(terminated.terminationStatus)）"
                    }
                }
            }
            helperProcess = process
            helperLogHandle = logHandle
            helperStopRequested = false
            try process.run()

            Task { @MainActor [weak self, weak process] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, let process, self.helperProcess === process else { return }
                guard process.isRunning,
                      HelperProcessInspector.matches(
                          pid: process.processIdentifier,
                          executableURL: executableURL
                      ) else {
                    self.refreshHelperStatus()
                    if self.helperStatusMessage?.hasPrefix("按键拦截异常退出") != true {
                        self.helperStatusMessage = "按键拦截启动失败：进程未保持运行"
                    }
                    self.helperTransitioning = false
                    return
                }
                if persistPreference && !self.setHelperEnabled(true) {
                    self.helperStatusMessage = self.bindingStatusMessage ?? "配置未保存，按键拦截已停止"
                    self.stopHelper(persistPreference: false)
                    return
                }
                self.helperRunning = true
                self.helperTransitioning = false
                self.helperStatusMessage = nil
                fileLog("按键拦截已启动 PID=\(process.processIdentifier)，用户 UID=\(getuid())")
            }
        } catch {
            helperProcess = nil
            try? helperLogHandle?.close()
            helperLogHandle = nil
            helperTransitioning = false
            helperStatusMessage = "按键拦截启动失败：\(error.localizedDescription)"
        }
    }

    private func unmanagedHelperMessage() -> String? {
        let controlledPID = controlledHelperPID()
        let conflicts = HelperProcessInspector.identities(named: "mage-helper")
            .filter { $0.pid != controlledPID }
        if let conflict = conflicts.first(where: { $0.uid == 0 }) {
            return "检测到旧版管理员 helper（PID \(conflict.pid)）；请运行 sudo kill \(conflict.pid) 后重试"
        }
        if let conflict = conflicts.first {
            return "检测到未受控 helper（PID \(conflict.pid)）；请先退出旧版应用后重试"
        }
        return nil
    }

    private func stopHelper(persistPreference: Bool) {
        guard let executableURL = helperURL, let pid = controlledHelperPID() else {
            helperRunning = false
            helperTransitioning = false
            if persistPreference {
                applyStopPreference()
            } else {
                helperStatusMessage = nil
            }
            return
        }
        guard HelperProcessInspector.matches(pid: pid, executableURL: executableURL) else {
            helperStatusMessage = "拒绝停止：helper 进程身份已变化"
            return
        }

        helperTransitioning = true
        helperStopRequested = true
        helperStatusMessage = "正在停止按键拦截…"
        guard kill(pid, SIGTERM) == 0 else {
            helperTransitioning = false
            helperStopRequested = false
            helperStatusMessage = "按键拦截停止失败：\(String(cString: strerror(errno)))"
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if !HelperProcessInspector.matches(pid: pid, executableURL: executableURL) { break }
            }
            guard !HelperProcessInspector.matches(pid: pid, executableURL: executableURL) else {
                self.helperTransitioning = false
                self.helperStopRequested = false
                self.helperStatusMessage = "按键拦截停止失败：进程未退出"
                return
            }
            self.helperRunning = false
            self.helperTransitioning = false
            self.helperStopRequested = false
            if persistPreference {
                self.applyStopPreference()
            } else {
                self.helperStatusMessage = nil
            }
            fileLog("按键拦截已停止 PID=\(pid)")
        }
    }

    func stopHelperForAppTermination() {
        guard let executableURL = helperURL, let pid = controlledHelperPID(),
              HelperProcessInspector.matches(pid: pid, executableURL: executableURL) else { return }
        helperStopRequested = true
        _ = kill(pid, SIGTERM)
        for _ in 0..<20 {
            if !HelperProcessInspector.matches(pid: pid, executableURL: executableURL) { break }
            usleep(50_000)
        }
    }

    private func applyStopPreference() {
        let outcome = HelperStopPreferenceOutcome(
            persistenceSucceeded: setHelperEnabled(false)
        )
        helperEnabled = outcome.helperEnabled
        helperStatusMessage = outcome.message ?? bindingStatusMessage
    }
}

// MARK: - App

@main
struct MageControllerApp: App {
    @StateObject private var vm = ControllerVM.shared
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBar

    var body: some Scene {
        // 调试：--menu-preview 在新窗口中预览菜单栏面板布局
        Window("Menu Preview", id: "menu-preview") {
            MenuContent(vm: ControllerVM.shared)
                .padding(14)
                .frame(width: 264)
                .fixedSize()
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .padding(8)
        }
        .defaultLaunchBehavior(CommandLine.arguments.contains("--menu-preview") ? .presented : .suppressed)
    }
}

// MARK: - 菜单栏弹出面板（与主窗口一致的液态玻璃风格）

struct MenuContent: View {
    @ObservedObject var vm: ControllerVM

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 状态头
            HStack(spacing: 8) {
                Image(systemName: vm.connected ? "gamecontroller.fill" : "gamecontroller")
                    .font(.system(size: 14))
                Text("MAGE 雪漫天")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(vm.connected ? Color(hex: 0x34C759) : Color.primary.opacity(0.25))
                    .frame(width: 8, height: 8)
                Text(vm.connected ? formatRate(vm.sampleRate) : "未连接")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)

            Divider().padding(.vertical, 10)

            // 设备开关
            VStack(spacing: 2) {
                menuToggle("指示灯", icon: "lightbulb.max.fill",
                           isOn: vm.ledOn, enabled: vm.connected) { vm.toggleLED() }
                menuToggle("麦克风", icon: "mic.fill",
                           isOn: vm.micOn, enabled: vm.connected) { vm.toggleMic() }
                menuToggle("7.1 环绕", icon: "speaker.wave.3.fill",
                           isOn: vm.surround71, enabled: vm.connected) { vm.toggle71() }
            }

            Divider().padding(.vertical, 10)

            // 采样率（芯片横排）
            Text("采样率 · 灯色联动")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            HStack(spacing: 6) {
                ForEach(menuRates, id: \.self) { rate in
                    let selected = abs(vm.sampleRate - rate) < 1
                    Button { vm.setRate(rate) } label: {
                        Text(formatRate(rate))
                            .font(.system(size: 10))
                            .foregroundStyle(.primary.opacity(selected ? 1 : 0.55))
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background {
                                Capsule().fill(Color.primary.opacity(selected ? 0.14 : 0.06))
                            }
                            .overlay {
                                Capsule().stroke(Color.primary.opacity(selected ? 0.35 : 0.15), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.connected)
                }
            }

            Divider().padding(.vertical, 10)

            // 操作
            VStack(spacing: 2) {
                menuRow("打开主界面", icon: "macwindow") {
                    NotificationCenter.default.post(name: .openKeysWindow, object: nil)
                }
                menuRow("退出 MAGE Controller", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .onAppear { vm.poll() }
    }

    private var menuRates: [Double] {
        vm.availableRates.isEmpty ? [48000, 96000, 192000] : Array(vm.availableRates.prefix(3))
    }

    /// 开关行：图标 + 名称 + 迷你开关
    private func menuToggle(_ title: String, icon: String, isOn: Bool,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Capsule()
                    .fill(isOn ? Color(hex: 0x34C759) : Color.primary.opacity(0.15))
                    .frame(width: 30, height: 17)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 13, height: 13)
                            .padding(2)
                    }
            }
            .foregroundStyle(.primary)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 普通按钮行
    private func menuRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .buttonStyle(.plain)
    }

    func formatRate(_ r: Double) -> String {
        r >= 1000 ? String(format: "%.1f kHz", r / 1000) : String(format: "%.0f Hz", r)
    }
}

extension Notification.Name {
    static let openKeysWindow = Notification.Name("OpenKeysWindow")
}

// MARK: - 按键录制器

/// 录制器外壳：本地事件监听（App 窗口聚焦时按键，无需任何系统权限）
/// 录制期间吞掉按键事件，捕获键名与修饰键（经 @Published 抛给视图）
final class KeyRecorder: ObservableObject {
    static let shared = KeyRecorder()

    @Published var recording = false
    @Published var capturedName: String?
    @Published var capturedMods: [String] = []

    private var monitor: Any?
    private var timeout: Timer?
    private var onCapture: ((String, [String]) -> Void)?

    private static let names: [UInt16: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p",
        12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
        16: "y", 6: "z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
        36: "return", 49: "space", 48: "tab", 53: "escape", 51: "backspace",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        50: "`", 43: ",", 47: ".", 44: "/", 117: "forwarddelete",
        123: "left", 124: "right", 126: "up", 125: "down",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15",
    ]

    /// 开始录制。录制期间 App 窗口必须保持焦点（点击「录制」后不要切换窗口）
    func start(timeout seconds: TimeInterval = 30, onCapture: ((String, [String]) -> Void)? = nil) {
        stop()
        self.onCapture = onCapture
        // 激活 App 并取消文本框焦点，确保按键到达窗口层被监听器捕获
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.handle(ev)
            return nil   // 录制期间吞掉按键
        }
        recording = true
        fileLog("录制器: 开始监听 (本地, 窗口需聚焦)")
        timeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.stop()
            fileLog("录制器: 超时未按键，已停止")
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        timeout?.invalidate(); timeout = nil
        recording = false
    }

    private func handle(_ ev: NSEvent) {
        // 修饰键：flagsChanged 事件
        if ev.type == .flagsChanged {
            let f = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: [String] = []
            if f.contains(.command) { mods.append("command") }
            if f.contains(.option) { mods.append("option") }
            if f.contains(.control) { mods.append("control") }
            if f.contains(.shift) { mods.append("shift") }
            // 松开全部修饰键 → 作为纯修饰键组合捕获
            if mods.isEmpty && sawMod {
                finish("", lastMods)
            } else if !mods.isEmpty {
                sawMod = true
                lastMods = mods
            }
            return
        }
        guard ev.type == .keyDown else { return }
        var name = KeyRecorder.names[ev.keyCode] ?? ""
        if name.isEmpty { name = (ev.charactersIgnoringModifiers ?? "").lowercased() }
        guard !name.isEmpty else { return }
        let f = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: [String] = []
        if f.contains(.command) { mods.append("command") }
        if f.contains(.option) { mods.append("option") }
        if f.contains(.control) { mods.append("control") }
        if f.contains(.shift) { mods.append("shift") }
        finish(name, mods)
    }

    private var sawMod = false
    private var lastMods: [String] = []

    private func finish(_ name: String, _ mods: [String]) {
        stop()
        sawMod = false
        lastMods = []
        capturedMods = mods
        capturedName = name
        fileLog("录制: 捕获 \(name.isEmpty ? "(纯修饰键)" : name) + \(mods.joined(separator: "+"))")
        onCapture?(name, mods)
    }
}


// MARK: - 菜单栏状态项 + 弹出面板 + 主窗口（AppKit 实现，完全掌控尺寸与行为）
//
// 弃用 SwiftUI MenuBarExtra(.window)：其面板由系统托管，内容固定尺寸会塌缩成 66×20。
// 改用 NSStatusItem + NSPanel 手动管理后，面板尺寸、定位、点击外部关闭全部可控。

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var mainWC: NSWindowController?
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon(connected: false)
        item.button?.action = #selector(togglePanel)
        item.button?.target = self
        statusItem = item

        ControllerVM.shared.$connected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.statusItem?.button?.image = Self.icon(connected: on) }
            .store(in: &cancellables)

        buildPanel()

        NotificationCenter.default.addObserver(
            self, selector: #selector(openMainWindow),
            name: .openKeysWindow, object: nil)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanelIfOutside() }
        }

        if CommandLine.arguments.contains("--open-window") { openMainWindow() }
        if CommandLine.arguments.contains("--open-panel") {
            // 状态项窗口刚创建，稍等再展开面板
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.togglePanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControllerVM.shared.stopHelperForAppTermination()
    }

    private static func icon(connected: Bool) -> NSImage? {
        NSImage(systemSymbolName: connected ? "gamecontroller.fill" : "gamecontroller",
                accessibilityDescription: "MAGE Controller")
    }

    // MARK: 弹出面板

    private func buildPanel() {
        let content = MenuContent(vm: ControllerVM.shared)
            .padding(14)
            .frame(width: 264)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            }
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 264, height: 600)
        let fit = host.fittingSize
        host.frame = NSRect(origin: .zero, size: fit)
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: fit),
                        styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = host
        panel = p
        fileLog("菜单面板尺寸 \(fit.width)×\(fit.height)")
    }

    @objc private func togglePanel() {
        guard let panel, let button = statusItem?.button, let buttonWindow = button.window else {
            fileLog("togglePanel 提前返回: panel=\(panel != nil) button=\(statusItem?.button != nil) window=\(statusItem?.button?.window != nil)")
            return
        }
        if panel.isVisible { panel.orderOut(nil); return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: buttonRect.midX - size.width / 2,
                                     y: buttonRect.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        fileLog("面板已展开 \(size.width)×\(size.height) @ \(panel.frame.origin)")
    }

    private func closePanelIfOutside() {
        guard let panel, panel.isVisible else { return }
        let loc = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -6, dy: -6).contains(loc) { return }
        if let button = statusItem?.button, let bw = button.window {
            let r = bw.convertToScreen(button.convert(button.bounds, to: nil))
            if r.insetBy(dx: 6, dy: 6).contains(loc) { return }
        }
        panel.orderOut(nil)
    }

    // MARK: 主窗口

    @objc private func openMainWindow() {
        if mainWC == nil {
            let windowSize = NSSize(width: 800, height: 640)
            let host = NSHostingView(rootView: MainWindowView().environmentObject(ControllerVM.shared))
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.frame = NSRect(origin: .zero, size: windowSize)

            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.contentView = host
            win.title = "MAGE Controller"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isOpaque = false
            win.backgroundColor = .clear
            win.isMovableByWindowBackground = true
            win.standardWindowButton(.zoomButton)?.isEnabled = false
            win.minSize = windowSize
            win.maxSize = windowSize
            win.setFrame(NSRect(origin: win.frame.origin, size: windowSize), display: false)
            win.center()

            mainWC = NSWindowController(window: win)
        }
        mainWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
