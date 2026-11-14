// MAGE Controller 菜单栏 App
// 功能：设备状态显示、灯/麦克风/7.1 控制、采样率切换（触发灯色）、按键映射编辑、拦截守护进程管理
import SwiftUI
import Combine
import Darwin
import MageKit

// MARK: - 视图模型

private let restartRecoveryTimeout: TimeInterval = 20
private let restartRetryDelay: TimeInterval = 0.35

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

    @Published var connected = false {
        // 只在模式/7.1 切换过渡期全抑制（设备重枚举时设备键洪水是唯一来源）。
        // 设备离线时绝不抑制——设备已拔出，没有设备键可拦，全抑制只会误吞
        // MacBook 自带音量键（用户 2026-11-15 反馈的 bug）。
        didSet { keyTap.suppressAllMediaKeys = deviceTransitioning }
    }
    @Published var pid: Int = 0
    @Published var ledOn = false
    @Published var micOn = false
    @Published var surround71 = false
    /// 音效模式：true=游戏（PEQ 预设 ≥256），false=HiFi/BYPASS。与 7.1 相互独立
    @Published var gameMode = false
    @Published var sampleRate: Double = 0
    @Published var availableRates: [Double] = []
    @Published var helperRunning = false
    @Published var helperEnabled = false
    @Published var helperTransitioning = false
    @Published var helperStatusMessage: String?
    @Published var bindingStatusMessage: String?
    @Published var statusMessage = "未连接"
    @Published private(set) var deviceTransitioning = false {
        didSet { keyTap.suppressAllMediaKeys = deviceTransitioning }
    }

    private let channel = VendorChannel()
    /// 免拦截 v2：App 内按键识别 + 系统事件抑制（替代旧 seize + helper 方案）
    private let keyTap = KeyTapV2()
    private var pollWork: DispatchWorkItem?
    private var helperProcess: Process?
    private var helperLogHandle: FileHandle?
    private var helperStopRequested = false
    private var configReadFailed = false
    private var lastHelperStatusDate: Date?
    private var transitionErrorMessage: String?
    private var deviceTransitionID: UUID?
    private let transitionInterlock = DeviceTransitionInterlock()
    private var helperRecoveryGeneration = 0
    private var shortcutRelayObserver: NSObjectProtocol?
    /// 轮询连续失败次数：设备 HID 偶发抖动（按键爆发时忙）单次失败不打掉已连接态，
    /// 连续 3 次（约 6 秒）才判定离线——修菜单栏面板「闪断置灰」
    private var pollFailures = 0

    // v2 免拦截：厂商通道全程在线，按键监听期间设备控制照常可用
    var deviceControlsEnabled: Bool {
        connected && !deviceTransitioning && !helperTransitioning
    }

    var helperControlEnabled: Bool {
        !deviceTransitioning && !helperTransitioning
    }

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
        shortcutRelayObserver = DistributedNotificationCenter.default().addObserver(
            forName: ShortcutRelay.notificationName,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] notification in
            guard let request = ShortcutRelay.Request(notification: notification) else {
                fileLog("快捷键请求格式无效，已忽略")
                return
            }
            Task { @MainActor [weak self] in
                self?.handleShortcutRequest(request)
            }
        }
        channel.onPush = { [weak self] cmd, payload in
            guard let self else { return }
            Task { @MainActor in self.handlePush(cmd: cmd, payload: payload) }
        }
        // 零流量断线检测：IOHIDDevice 移除通知直接到达，无需轮询心跳，
        // 指示灯关闭期间可以完全静默（任何 HID 流量都会点亮物理灯数秒）。
        channel.onDeviceRemoved = { [weak self] in
            Task { @MainActor in
                guard let self, !self.deviceTransitioning else { return }
                if self.connected {
                    self.connected = false
                    self.pid = 0
                    self.statusMessage = "未连接（等待设备）"
                    fileLog("设备移除（系统通知）")
                }
                self.poll()
            }
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

    deinit {
        if let shortcutRelayObserver {
            DistributedNotificationCenter.default().removeObserver(shortcutRelayObserver)
        }
    }

    private func handleShortcutRequest(_ request: ShortcutRelay.Request) {
        let action = KeyAction.keystroke(key: request.key, modifiers: request.modifiers)
        fileLog("helper 转交快捷键 → \(action.summary)")
        switch KeystrokeSimulator.post(key: request.key, modifiers: request.modifiers) {
        case .success:
            helperStatusMessage = nil
            fileLog("快捷键回放成功 → \(action.summary)")
            writeHelperStatus(.info, "快捷键回放成功：\(action.summary)")
        case .failure(let error):
            let message: String
            if case .eventAccessDenied = error {
                let executable = Bundle.main.executableURL?.path ?? "MAGE Controller.app"
                message = "macOS 未授予主 App 发送键盘事件的辅助功能权限：\(executable)"
            } else {
                message = "快捷键回放失败：\(error.localizedDescription)"
            }
            helperStatusMessage = message
            fileLog(message)
            writeHelperStatus(.actionError, message)
        }
    }

    private func writeHelperStatus(_ kind: HelperStatusRecord.Kind, _ message: String) {
        do {
            try FileManager.default.createDirectory(
                at: Self.runtimeDirectoryURL,
                withIntermediateDirectories: true
            )
            let record = HelperStatusRecord(kind: kind, message: message)
            let data = try JSONEncoder().encode(record)
            try data.write(to: Self.helperStatusURL, options: .atomic)
        } catch {
            fileLog("无法写入快捷键状态：\(error.localizedDescription)")
        }
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
            keyTap.updateConfig(cfg)   // v2：绑定改动即时生效（替代旧 helper 的文件监听热重载）
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

    func poll(force: Bool = false) {
        pollWork?.cancel()
        refreshHelperState()
        guard !deviceTransitioning else { return }
        // 固件实测行为：任何 HID 流量（读/写任意命令）都会让物理指示灯点亮约 5 秒，
        // 与 cmd6 寄存器无关。官方面板的做法是只有连接/切页时发一帧，之后静默。
        // 因此指示灯关（寄存器=0）期间完全静默、不排任何轮询；拔线/重插检测
        // 靠 VendorChannel 的 IOHIDDevice 移除通知（零流量）。用户主动打开界面
        // （force）时才允许一次查询爆发（与官方面板切页行为一致，代价一次闪灯）。
        if !ledOn && connected && !force { return }
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
            // 音效模式：读 EQ 预设（240=HiFi/BYPASS；≥256=游戏），回包解析失败不阻断轮询
            let peq = (try? channel.send(cmd: .peqPre)) ?? []
            let game = MageProtocol.peqPresetValue(peq)
                .map { MageProtocol.isGamePreset($0) } ?? self.gameMode
            Task { @MainActor in
                guard !self.deviceTransitioning else { return }
                let wasConnected = self.connected
                self.connected = true
                self.pollFailures = 0
                self.pid = self.channel.connectedPID
                self.ledOn = led == 1
                self.micOn = mic == 1
                self.surround71 = s71 == 1
                self.gameMode = game
                self.transitionErrorMessage = nil
                self.statusMessage = String(format: "已连接 PID=0x%04X", self.pid)
                fileLog("\(self.statusMessage) LED=\(led) MIC=\(mic) 7.1=\(s71)")
                if !wasConnected { fileLog("设备上线") }
                if let out = AudioControl.outputDevice() {
                    if let rate = AudioControl.currentSampleRate(device: out) {
                        self.sampleRate = rate
                    }
                    self.availableRates = out.sampleRates
                }
                self.poll()
            }
        } catch {
            Task { @MainActor in
                guard !self.deviceTransitioning else { return }
                self.pollFailures += 1
                // 首次/偶发失败：保留已连接态，只记日志，2s 后自动重试
                guard self.pollFailures >= 3 else {
                    fileLog("轮询抖动(\(self.pollFailures)/3): \(error.localizedDescription)")
                    self.poll()
                    return
                }
                self.connected = false
                self.pid = 0
                self.statusMessage = self.transitionErrorMessage ?? "未连接（等待设备）"
                fileLog("设备离线: \(error.localizedDescription)")
                self.channel.close()
                self.poll()
            }
        }
    }

    func toggleLED() {
        guard deviceControlsEnabled else { return }
        runSet(.ledLight, value: ledOn ? 0 : 1) { [weak self] v in
            guard let self else { return }
            self.ledOn = v == 1
            // 灯开→恢复正常轮询；灯关→poll 自身转入 90s 静默心跳
            self.poll()
        }
    }

    func toggleMic() {
        guard deviceControlsEnabled else { return }
        runSet(.micSwitch, value: micOn ? 0 : 1, update: { self.micOn = $0 == 1 })
    }

    func toggle71() {
        guard deviceControlsEnabled,
              transitionInterlock.begin(.deviceRestart) else { return }
        let targetState = !surround71
        let targetValue: UInt8 = targetState ? 1 : 0
        let startedAt = ProcessInfo.processInfo.systemUptime
        let transitionID = UUID()

        deviceTransitioning = true
        deviceTransitionID = transitionID
        transitionErrorMessage = nil
        connected = false
        pid = 0
        pollWork?.cancel()
        statusMessage = targetState
            ? "正在开启 7.1，等待设备重启重连…"
            : "正在关闭 7.1，等待设备重启重连…"
        fileLog("7.1 切换开始 target=\(targetValue)")

        DispatchQueue.main.asyncAfter(deadline: .now() + restartRecoveryTimeout) { [weak self] in
            guard let self,
                  self.deviceTransitioning,
                  self.deviceTransitionID == transitionID else { return }
            self.statusMessage = "7.1 切换已超过 20 秒，正在安全收尾，请勿重复操作…"
            fileLog("7.1 成功判定窗口已结束，等待不可取消的 HID/CoreAudio 调用安全收尾")
        }

        let channel = channel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let coordinator = DeviceRestartCoordinator()
            let result = coordinator.run(
                targetState: targetState,
                startedAt: startedAt,
                timeout: restartRecoveryTimeout,
                retryDelay: restartRetryDelay,
                io: DeviceRestartIO(
                    sendRestart: { target in
                        try channel.sendRestartCommand(
                            cmd: .channel71Switch,
                            payload: [target ? 1 : 0],
                            set: true
                        )
                        fileLog("7.1 命令已写入 target=\(target ? 1 : 0)，旧通道已原子关闭")
                    },
                    open: { try channel.open() },
                    read: { command, timeout in
                        try channel.send(cmd: command, timeout: timeout).first
                    },
                    connectedPID: { channel.connectedPID },
                    audioSnapshot: {
                        AudioControl.recoverySnapshot(from: AudioControl.mageDevices())
                    },
                    close: { channel.close() }
                ),
                observe: { message in fileLog("7.1 重连观察：\(message)") }
            )
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let snapshot, let elapsed):
                    self.finish71TransitionSuccess(
                        snapshot, elapsed: elapsed, transitionID: transitionID
                    )
                case .commandFailure(let detail):
                    self.finish71TransitionFailure(
                        "7.1 命令发送失败，未自动重试：\(detail)",
                        transitionID: transitionID
                    )
                case .recoveryFailure(let detail):
                    // 重启兜底：命令可能已执行但设备未恢复，尝试 REBOOT_DEVICE(122) 救活
                    self.attemptRebootRecovery(
                        afterFailure: "7.1 未在 20 秒成功判定窗口内恢复：\(detail)。",
                        transitionID: transitionID
                    )
                }
            }
        }
    }

    private func finish71TransitionSuccess(
        _ snapshot: DeviceRestartSnapshot,
        elapsed: TimeInterval,
        transitionID: UUID
    ) {
        guard deviceTransitioning, deviceTransitionID == transitionID else { return }
        deviceTransitioning = false
        deviceTransitionID = nil
        transitionInterlock.finish(.deviceRestart)
        transitionErrorMessage = nil
        connected = true
        pid = snapshot.pid
        ledOn = snapshot.ledOn
        micOn = snapshot.micOn
        surround71 = snapshot.surround71
        // 音频接口可能尚未重枚举（宽限收尾），保留旧采样率，轮询稍后刷新
        if snapshot.sampleRate > 0 {
            sampleRate = snapshot.sampleRate
            availableRates = snapshot.availableRates
        }
        statusMessage = String(format: "已连接 PID=0x%04X", snapshot.pid)
        fileLog(String(
            format: "7.1 切换完成 target=%d PID=0x%04X elapsed=%.2fs LED=%d MIC=%d",
            snapshot.surround71 ? 1 : 0,
            snapshot.pid,
            elapsed,
            snapshot.ledOn ? 1 : 0,
            snapshot.micOn ? 1 : 0
        ))
        poll()
    }

    private func finish71TransitionFailure(_ message: String, transitionID: UUID) {
        guard deviceTransitioning, deviceTransitionID == transitionID else { return }
        deviceTransitioning = false
        deviceTransitionID = nil
        transitionInterlock.finish(.deviceRestart)
        connected = false
        pid = 0
        transitionErrorMessage = message
        statusMessage = message
        fileLog(message)
        poll()
    }

    // MARK: - 音效模式切换（HiFi ↔ 游戏，经 EQ 预设 cmd 22）

    /// 切换音效模式。实测（2026-11-14）写 EQ 预设后设备**不重启、不掉线**，
    /// 写完直接读回验证即可；比 7.1 的 20 秒重连流程轻得多。
    /// 若固件后续版本出现切换后失联，poll() 的自动重连 + peqPre 读回会自愈状态。
    func toggleGameMode() {
        guard deviceControlsEnabled else { return }
        let targetGame = !gameMode
        let preset: UInt16 = targetGame
            ? MageProtocol.peqPresetGame
            : MageProtocol.peqPresetHifi
        statusMessage = targetGame ? "正在切换到游戏模式…" : "正在切换到 HiFi 模式…"
        fileLog("音效模式切换开始 target=\(preset)")
        let channel = channel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try channel.send(cmd: .peqPre,
                                     payload: MageProtocol.peqPresetBytes(preset),
                                     set: true)
                // 读回验证
                let payload = try channel.send(cmd: .peqPre, timeout: 1.5)
                let readback = MageProtocol.peqPresetValue(payload)
                Task { @MainActor in
                    guard let self else { return }
                    guard readback == preset else {
                        self.statusMessage = "模式切换读回不一致（写入 \(preset)，读回 \(readback.map(String.init) ?? "无")），请重试"
                        fileLog(self.statusMessage)
                        return
                    }
                    self.gameMode = targetGame
                    self.statusMessage = String(format: "已连接 PID=0x%04X", self.pid)
                    fileLog("音效模式切换完成 game=\(targetGame)")
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.statusMessage = "模式切换失败: \(error)"
                    fileLog("音效模式切换失败: \(error)")
                }
            }
        }
    }

    /// 手动重启设备（REBOOT_DEVICE 122）：设备状态异常时的硬复位手段。
    /// 重启后设备会从总线消失再重枚举，正常轮询会自动重连并读回状态。
    func rebootDevice() {
        guard deviceControlsEnabled else { return }
        statusMessage = "正在重启设备…"
        fileLog("发送 REBOOT_DEVICE(122)")
        let channel = channel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try channel.send(cmd: .rebootDevice, payload: [], set: true)
                Task { @MainActor in
                    guard let self else { return }
                    self.statusMessage = "设备重启中，等待重连…"
                    fileLog("REBOOT_DEVICE 已发送，等待设备重枚举")
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.statusMessage = "重启命令失败: \(error)"
                    fileLog("REBOOT_DEVICE 失败: \(error)")
                }
            }
        }
    }

    /// 切换失败后兜底：等通道恢复可写后发 REBOOT_DEVICE(122)，之后正常轮询自动重连。
    private func attemptRebootRecovery(afterFailure failedMessage: String, transitionID: UUID) {
        fileLog("尝试 REBOOT_DEVICE 兜底")
        let channel = channel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var lastError = ""
            while ProcessInfo.processInfo.systemUptime < deadline {
                do {
                    if try channel.open() {
                        try channel.send(cmd: .rebootDevice, payload: [], set: true)
                        fileLog("REBOOT_DEVICE(122) 兜底已发送，等待重枚举")
                        Task { @MainActor in
                            self?.finish71TransitionFailure(
                                failedMessage + "已发送设备重启命令，若 10 秒内仍未恢复请重新插拔 USB",
                                transitionID: transitionID
                            )
                        }
                        return
                    }
                } catch {
                    lastError = error.localizedDescription
                }
                Thread.sleep(forTimeInterval: 1)
            }
            Task { @MainActor in
                self?.finish71TransitionFailure(
                    failedMessage + "重启兜底未成功（\(lastError)），请重新插拔 MAGE USB",
                    transitionID: transitionID
                )
            }
        }
    }

    func setRate(_ rate: Double) {
        guard deviceControlsEnabled else { return }
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

    /// 找到与本 App 同路径、正在运行、但不由当前实例管理的 mage-helper。
    /// 用于在开启拦截时安全接管已在运行的 helper，而不是另起一个去抢占设备。
    private func adoptableHelperPID() -> pid_t? {
        guard let executableURL = helperURL else { return nil }
        if let pid = controlledHelperPID() { return pid }
        guard let text = try? String(contentsOf: Self.helperPIDURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              HelperProcessInspector.matches(pid: pid, executableURL: executableURL)
        else { return nil }
        return pid
    }

    private func refreshHelperState() {
        // 免拦截 v2：运行状态由 App 内 keyTap 决定；旧 helper 进程不再代表拦截状态
        if case .running = keyTap.state { helperRunning = true } else { helperRunning = false }
        refreshHelperStatus()
        if helperEnabled && !helperRunning && !helperTransitioning && helperStatusMessage == nil {
            helperStatusMessage = "按键拦截未运行，请重试"
        }
    }

    private var lastHelperStatusRecord: HelperStatusRecord? {
        guard let data = try? Data(contentsOf: Self.helperStatusURL),
              let record = try? JSONDecoder().decode(HelperStatusRecord.self, from: data)
        else { return nil }
        return record
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
        // 开关偏好仍开着但 helper 已不在：轮询兜底会自动拉起。
        if helperStatusMessage == nil {
            helperStatusMessage = "按键拦截未运行，正在自动恢复…"
        }
        guard beginHelperTransition() else { return }
        startHelper(persistPreference: false)
    }

    private func scheduleHelperRecoveryRetry() {
        let generation = helperRecoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            // 仅当这是一次仍未成功的恢复尝试时继续重试，避免与手动开关竞争。
            guard self.helperRecoveryGeneration == generation,
                  self.helperEnabled,
                  HelperKeepAlivePolicy.shouldRetryRecovery(
                      enabled: self.helperEnabled,
                      running: self.helperRunning,
                      transitioning: self.helperTransitioning,
                      status: self.lastHelperStatusRecord
                  ) else { return }
            self.restoreHelperIfNeeded()
        }
    }

    func toggleHelper() {
        guard helperControlEnabled else { return }
        refreshHelperState()
        guard beginHelperTransition() else { return }
        if helperRunning {
            stopHelper(persistPreference: true)
        } else {
            startHelper(persistPreference: true)
        }
    }

    private func beginHelperTransition() -> Bool {
        guard !deviceTransitioning, !helperTransitioning,
              transitionInterlock.begin(.helperLifecycle) else { return false }
        helperTransitioning = true
        return true
    }

    private func finishHelperTransition() {
        helperTransitioning = false
        transitionInterlock.finish(.helperLifecycle)
    }

    private func startHelper(persistPreference: Bool) {
        // 免拦截 v2：按键识别 + 系统事件抑制全部在 App 内完成，不再启动 mage-helper。
        // 先清理可能在跑的旧 helper（seize 会独占设备，与共享监听冲突）。
        stopLegacyHelpers()
        // CGEventTap 需要辅助功能权限；未授权时弹系统授权框
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            helperStatusMessage = "需要辅助功能权限：请在 系统设置 → 隐私与安全性 → 辅助功能 中允许 MAGE Controller 后重新开启"
            finishHelperTransition()
            return
        }
        keyTap.updateConfig(loadConfig())
        keyTap.onLog = { fileLog("[按键] " + $0) }
        keyTap.onActionError = { [weak self] message in
            Task { @MainActor in
                self?.helperStatusMessage = message
                fileLog("[按键] " + message)
            }
        }
        guard keyTap.start() else {
            helperStatusMessage = keyTap.failureReason ?? "按键拦截启动失败"
            finishHelperTransition()
            return
        }
        if persistPreference && !setHelperEnabled(true) {
            helperStatusMessage = bindingStatusMessage ?? "配置未保存，按键拦截状态未更新"
        } else {
            helperStatusMessage = nil
        }
        helperRunning = true
        finishHelperTransition()
        fileLog("按键拦截已启动（免拦截 v2，App 内）")
        return
    }

    /// 停掉旧版 seize helper（若还在跑），避免独占设备
    private func stopLegacyHelpers() {
        guard let executableURL = helperURL else { return }
        guard let pids = try? HelperProcessInspector.identities(named: "mage-helper") else { return }
        for identity in pids where HelperProcessInspector.matches(pid: identity.pid, executableURL: executableURL) {
            kill(identity.pid, SIGTERM)
            fileLog("已停止旧版 helper PID=\(identity.pid)")
        }
    }

    private func startHelperLegacy(persistPreference: Bool) {
        guard let executableURL = helperURL, let options = helperOptions else {
            helperStatusMessage = "按键拦截启动失败：无法解析 helper 路径"
            finishHelperTransition()
            return
        }
        // 已有同路径 helper 在跑（可能是本 App 之前拉起、或上次会话遗留）：
        // 直接接管，不再另起一个去抢占设备，避免 seize 失败导致的反复离线。
        if adoptableHelperPID() != nil {
            if persistPreference && !setHelperEnabled(true) {
                helperStatusMessage = bindingStatusMessage ?? "配置未保存，按键拦截状态未更新"
            } else {
                helperStatusMessage = nil
            }
            helperRunning = true
            finishHelperTransition()
            return
        }
        guard FileManager.default.fileExists(atPath: executableURL.path),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            helperStatusMessage = "按键拦截启动失败：缺少可执行文件 Contents/MacOS/mage-helper"
            finishHelperTransition()
            return
        }

        if let message = unmanagedHelperMessage() {
            helperStatusMessage = message
            finishHelperTransition()
            return
        }

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
                        self.finishHelperTransition()
                        self.helperStopRequested = false
                        self.helperStatusMessage = "按键拦截异常退出（状态 \(terminated.terminationStatus)）"
                    }
                }
            }
            helperProcess = process
            helperLogHandle = logHandle
            helperStopRequested = false
            try process.run()
        helperRecoveryGeneration += 1

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
                    self.finishHelperTransition()
                    // 开关偏好仍是开时，短暂延迟后自动重试，避免一次失败就永久失联。
                    if self.helperEnabled {
                        self.scheduleHelperRecoveryRetry()
                    }
                    return
                }
                if persistPreference && !self.setHelperEnabled(true) {
                    self.helperStatusMessage = self.bindingStatusMessage ?? "配置未保存，按键拦截已停止"
                    self.stopHelper(persistPreference: false)
                    return
                }
                self.helperRunning = true
                self.finishHelperTransition()
                self.helperStatusMessage = nil
                fileLog("按键拦截已启动 PID=\(process.processIdentifier)，用户 UID=\(getuid())")
            }
        } catch {
            helperProcess = nil
            try? helperLogHandle?.close()
            helperLogHandle = nil
            finishHelperTransition()
            helperStatusMessage = "按键拦截启动失败：\(error.localizedDescription)"
        }
    }

    private func unmanagedHelperMessage() -> String? {
        let controlledPID = controlledHelperPID()
        let conflicts: [HelperProcessIdentity]
        do {
            conflicts = try HelperProcessInspector.identities(named: "mage-helper")
                .filter { $0.pid != controlledPID }
        } catch {
            return "无法完整检查现有 helper 进程，已取消启动：\(error.localizedDescription)"
        }
        if let conflict = conflicts.first(where: { $0.uid == 0 }) {
            return "检测到旧版管理员 helper（PID \(conflict.pid)）；请运行 sudo kill \(conflict.pid) 后重试"
        }
        if let conflict = conflicts.first {
            return "检测到未受控 helper（PID \(conflict.pid)）；请先退出旧版应用后重试"
        }
        return nil
    }

    private func stopHelper(persistPreference: Bool) {
        // 免拦截 v2：停 App 内事件监听，同时清理旧 helper
        keyTap.stop()
        stopLegacyHelpers()
        helperRunning = false
        if persistPreference {
            applyStopPreference()
        } else {
            helperStatusMessage = nil
        }
        finishHelperTransition()
        fileLog("按键拦截已停止（免拦截 v2）")
        return
        guard let executableURL = helperURL, let pid = controlledHelperPID() else {
            helperRunning = false
            if persistPreference {
                applyStopPreference()
            } else {
                helperStatusMessage = nil
            }
            finishHelperTransition()
            return
        }
        guard HelperProcessInspector.matches(pid: pid, executableURL: executableURL) else {
            helperStatusMessage = "拒绝停止：helper 进程身份已变化"
            finishHelperTransition()
            return
        }

        helperStopRequested = true
        helperStatusMessage = "正在停止按键拦截…"
        guard kill(pid, SIGTERM) == 0 else {
            finishHelperTransition()
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
                self.finishHelperTransition()
                self.helperStopRequested = false
                self.helperStatusMessage = "按键拦截停止失败：进程未退出"
                return
            }
            self.helperRunning = false
            self.helperStopRequested = false
            if persistPreference {
                self.applyStopPreference()
            } else {
                self.helperStatusMessage = nil
            }
            self.finishHelperTransition()
            fileLog("按键拦截已停止 PID=\(pid)")
        }
    }

    func stopHelperForAppTermination() {
        keyTap.stop()
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
                .liquidGlassCard(cornerRadius: 14)
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
                Image(systemName: vm.deviceTransitioning
                    ? "arrow.triangle.2.circlepath"
                    : (vm.connected ? "gamecontroller.fill" : "gamecontroller"))
                    .font(.system(size: 14))
                Text("MAGE 雪漫天")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(vm.deviceTransitioning
                        ? Color.orange
                        : (vm.connected ? Color(hex: 0x34C759) : Color.primary.opacity(0.25)))
                    .frame(width: 8, height: 8)
                Text(vm.deviceTransitioning
                    ? "重启中"
                    : (vm.connected ? formatRate(vm.sampleRate) : "未连接"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    // 防截断：优先级高于 Spacer，宽度不足时压缩标题而非裁掉数值
                    .layoutPriority(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.primary)

            Divider().padding(.vertical, 10)

            // 设备开关
            VStack(spacing: 2) {
                menuToggle("指示灯", icon: "lightbulb.max.fill",
                           isOn: vm.ledOn, enabled: vm.deviceControlsEnabled) { vm.toggleLED() }
                menuToggle("麦克风", icon: "mic.fill",
                           isOn: vm.micOn, enabled: vm.deviceControlsEnabled) { vm.toggleMic() }
                menuToggle("游戏模式", icon: "gamecontroller.fill",
                           isOn: vm.gameMode, enabled: vm.deviceControlsEnabled) { vm.toggleGameMode() }
                menuToggle("7.1 环绕", icon: "speaker.wave.3.fill",
                           isOn: vm.surround71, enabled: vm.deviceControlsEnabled) { vm.toggle71() }
                menuRow("重启设备", icon: "arrow.triangle.2.circlepath") { vm.rebootDevice() }
            }

            Divider().padding(.vertical, 10)

            // 采样率（芯片横排，超宽自动换行；全量来自 CoreAudio 设备上报）
            Text("采样率 · 灯色联动")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6)], spacing: 6) {
                ForEach(menuRates, id: \.self) { rate in
                    let selected = abs(vm.sampleRate - rate) < rate * 0.01
                    Button { vm.setRate(rate) } label: {
                        Text(formatRate(rate))
                            .font(.system(size: 10))
                            .foregroundStyle(.primary.opacity(selected ? 1 : 0.55))
                            .frame(width: 62, height: 22)
                            .background {
                                Capsule().fill(Color.primary.opacity(selected ? 0.14 : 0.06))
                            }
                            .overlay {
                                Capsule().stroke(Color.primary.opacity(selected ? 0.35 : 0.15), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.deviceControlsEnabled)
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
        .onAppear { vm.poll(force: true) }
    }

    private var menuRates: [Double] {
        // 全量展示设备上报的采样率（MAGE 支持 PCM 至 32bit/384kHz），不再截断前 3 个
        vm.availableRates.isEmpty ? [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000] : vm.availableRates
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

    /// 采样率显示：吸附到标准档（44.1/48/88.2/96/176.4/192/352.8/384），
    /// 避免 CoreAudio 实际速率 48094 之类显示成「48.1 kHz」这种怪值；去尾零（48 而非 48.0）
    func formatRate(_ r: Double) -> String {
        let standards: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        for s in standards where abs(r - s) / s < 0.01 {
            let k = s / 1000
            let num = String(format: "%.1f", k).replacingOccurrences(of: ".0", with: "")
            return "\(num) kHz"
        }
        return r >= 1000 ? String(format: "%.1f kHz", r / 1000) : String(format: "%.0f Hz", r)
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

    /// 修饰键 keyCode → (侧别名称, 对应 flag)。NSEvent.ModifierFlags 不分左右，
    /// 录制右侧 Command 等必须读 keyCode，否则回放时按左侧发导致目标应用不识别。
    private static let modsByKeyCode: [UInt16: (name: String, flag: NSEvent.ModifierFlags)] = [
        55: ("command", .command), 54: ("right_command", .command),
        58: ("option", .option), 61: ("right_option", .option),
        56: ("shift", .shift), 60: ("right_shift", .shift),
        59: ("control", .control), 62: ("right_control", .control),
        63: ("fn", .function),
    ]

    private func handle(_ ev: NSEvent) {
        // 修饰键：flagsChanged 事件（带 keyCode 可区分左右侧）
        if ev.type == .flagsChanged {
            guard let info = KeyRecorder.modsByKeyCode[ev.keyCode] else { return }
            let f = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if f.contains(info.flag) {
                if !chord.contains(info.name) { chord.append(info.name); lastMods.append(info.name) }
                sawMod = true
            } else {
                chord.removeAll { $0 == info.name }
                // 松开全部修饰键 → 作为纯修饰键组合捕获（lastMods = 按下过的完整组合）
                if chord.isEmpty && sawMod {
                    finish("", lastMods)
                }
            }
            return
        }
        guard ev.type == .keyDown else { return }
        var name = KeyRecorder.names[ev.keyCode] ?? ""
        if name.isEmpty { name = (ev.charactersIgnoringModifiers ?? "").lowercased() }
        guard !name.isEmpty else { return }
        // 修饰键必须用 chord 里记录的侧别名（right_command 等）——
        // modifierFlags 不分左右，直接读会把「右⌘+,」录成通用 command，
        // 回放按左侧发出导致依赖右⌘的应用不识别。
        var mods: [String] = []
        for side in ["command", "right_command",
                     "option", "right_option",
                     "control", "right_control",
                     "shift", "right_shift",
                     "fn"] where chord.contains(side) {
            mods.append(side)
        }
        finish(name, mods)
    }

    private var sawMod = false
    private var lastMods: [String] = []
    /// 当前仍按住的修饰键（松开即移除）
    private var chord: [String] = []

    private func finish(_ name: String, _ mods: [String]) {
        stop()
        sawMod = false
        lastMods = []
        chord = []
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

    /// 菜单栏常驻 App：SwiftUI App 生命周期默认「最后一个窗口关闭即退出」，
    /// 面板收起/主窗口关闭都会把整个 App 杀掉（用户报「再点一次图标就退出」）。
    /// 显式返回 false，退出只走菜单栏「退出 MAGE Controller」。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
            .liquidGlassCard(cornerRadius: 14)
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
        // 面板是浮动面板，不随主窗口层级；打开主界面前必须确定性收起，
        // 否则面板会一直压在主界面上方（用户报「选完不消失/时有关时无关」）
        panel?.orderOut(nil)
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
