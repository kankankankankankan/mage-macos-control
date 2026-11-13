// MAGE Controller 菜单栏 App
// 功能：设备状态显示、灯/麦克风/7.1 控制、采样率切换（触发灯色）、按键映射编辑、拦截守护进程管理
import SwiftUI
import Combine
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
    @Published var statusMessage = "未连接"

    private let channel = VendorChannel()
    private var pollWork: DispatchWorkItem?

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
                    self?.saveConfig(cfg)
                    fileLog("CLI: 已保存 micKey = \(name) + \(mods.joined(separator: "+"))")
                }
            }
        }
        poll()
    }

    func saveConfig(_ cfg: KeyConfig) {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.config/mage-controller")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: dir.appendingPathComponent("config.json"))
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
        case .keystroke(let k, let mods): KeystrokeSimulator.post(key: k, modifiers: mods)
        }
        if cfg.micAutoUnmute {
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                if let r = try? self.channel.send(cmd: .micSwitch, payload: [1], set: true) {
                    Task { @MainActor in self.micOn = r.first == 1 }
                }
            }
        }
    }

    func loadConfig() -> KeyConfig {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/mage-controller/config.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(KeyConfig.self, from: data) else {
            return KeyConfig()
        }
        return cfg
    }

    private func runShell(_ cmd: String) {
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/zsh")
        t.arguments = ["-c", cmd]
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        try? t.run()
    }

    func poll() {
        pollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollOnce() }
        pollWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func pollOnce() {
        let helperOn = isHelperRunning()
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
                self.helperRunning = helperOn
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
                self.helperRunning = helperOn
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.channel.close()
            self?.poll()
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
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let r = try self.channel.send(cmd: cmd, payload: [value], set: true).first ?? value
                Task { @MainActor in update(r) }
            } catch {
                Task { @MainActor in self.statusMessage = "命令失败: \(error)" }
            }
        }
    }

    // MARK: 拦截守护进程（需要 root）
    var helperPath: String {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("mage-helper").path
    }

    /// 守护进程是否真在跑（pgrep 探测 —— osascript 返回 0 不代表进程存活）
    func isHelperRunning() -> Bool {
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        t.arguments = ["-f", "mage-helper"]
        try? t.run(); t.waitUntilExit()
        return t.terminationStatus == 0
    }

    private func setHelperEnabled(_ on: Bool) {
        var cfg = loadConfig()
        cfg.helperEnabled = on
        saveConfig(cfg)
        helperEnabled = on
    }

    func toggleHelper() {
        if isHelperRunning() {
            _ = run("/usr/bin/pkill", ["-f", "mage-helper"])
            helperRunning = false
            setHelperEnabled(false)
            return
        }
        // 通过系统授权对话框获取 root 启动守护进程。
        // 注意：不要用 nohup —— macOS nohup 在提权 shell（无控制终端）下会
        // 报 "can't detach from console" 并直接退出，守护进程根本没起来，
        // 但 osascript 因后台执行照样返回 0（假阳性）。
        let script = "'\(helperPath)' >/tmp/mage-helper.log 2>&1 &"
        let r = run("/usr/bin/osascript",
                    ["-e", "do shell script \"\(script)\" with administrator privileges"])
        if r != 0 { statusMessage = "未授权，按键拦截未开启"; return }
        // 1 秒后核实进程真的存活
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let ok = self.isHelperRunning()
            let log = ((try? String(contentsOfFile: "/tmp/mage-helper.log", encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                self.helperRunning = ok
                if ok {
                    self.setHelperEnabled(true)
                } else {
                    self.statusMessage = log.isEmpty
                        ? "守护进程启动失败（进程未存活）"
                        : "守护进程启动失败：\(String(log.prefix(100)))"
                }
            }
        }
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let t = Process(); t.executableURL = URL(fileURLWithPath: path); t.arguments = args
        try? t.run(); t.waitUntilExit()
        return t.terminationStatus
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
                menuToggle("按键拦截", icon: "keyboard.badge.ellipsis",
                           isOn: vm.helperRunning, enabled: true) { vm.toggleHelper() }
                if vm.helperEnabled && !vm.helperRunning {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("守护进程未运行，点击上方开关重新启动")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.orange)
                    .padding(.leading, 24)
                    .padding(.top, 2)
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


// MARK: - 顶部拖动宿主（标题栏配件）

/// 透明视图，按住即 performDrag 拖动窗口；红绿灯区域放行给系统按钮。
final class TopDragHost: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        let traffic = NSRect(x: 8, y: -6, width: 96, height: bounds.height + 6)
        if traffic.contains(point) { return nil }  // 红绿灯交给系统按钮
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        beginManualDrag(with: event)
    }
    override var acceptsFirstResponder: Bool { false }
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
            let host = NSHostingController(rootView: MainWindowView().environmentObject(ControllerVM.shared))
            let win = NSWindow(contentViewController: host)
            win.title = "MAGE Controller"
            win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isOpaque = false
            win.backgroundColor = .clear
            win.isMovableByWindowBackground = true
            win.standardWindowButton(.zoomButton)?.isEnabled = false
            win.contentMinSize = NSSize(width: 800, height: 640)
            win.contentMaxSize = NSSize(width: 800, height: 640)
            win.center()

            // 顶部可拖区：透明配件视图覆盖标题栏一带，按住即可拖动窗口。
            // SwiftUI 内容会拦截 mouseDown（isMovableByWindowBackground 失效），
            // 所以由 AppKit 视图显式 performDrag。
            let accessory = NSTitlebarAccessoryViewController()
            let dragHost = TopDragHost(frame: NSRect(x: 0, y: 0, width: 800, height: 28))
            accessory.view = dragHost
            accessory.layoutAttribute = .bottom
            win.addTitlebarAccessoryViewController(accessory)

            mainWC = NSWindowController(window: win)
        }
        mainWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
