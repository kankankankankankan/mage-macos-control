// 主窗口：macOS Liquid Glass（液态玻璃）风格
// 无背景色——透明窗口 + 玻璃材质，直接透出桌面；文字用系统色自动适配深浅
import SwiftUI
import MageKit

// MARK: - 窗口透明配置（配合 hiddenTitleBar 实现悬浮玻璃卡片）

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 窗口背景拖动层：SwiftUI 视图会拦截 mouseDown，导致 isMovableByWindowBackground 失效。
    /// 放在 ZStack 最底层（内容之下），面板间隙 / 四周留白的点击落到这里 → performDrag 拖动窗口。
    struct DragLayer: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { DragView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class DragView: NSView {
            override func mouseDown(with event: NSEvent) {
                beginManualDrag(with: event)
            }
        }
    }

    final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        override func layout() {
            super.layout()
            configure()
        }
        private func configure() {
            guard let w = window else { return }
            w.styleMask.insert(.fullSizeContentView)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.titlebarAppearsTransparent = true
            // 无标题栏窗口：按住玻璃空白处即可拖动
            w.isMovableByWindowBackground = true
        }
    }
}

// MARK: - 手动窗口拖动（performDrag 对合成事件不生效，改自己跟鼠标移动）

extension NSView {
    /// 按住拖动窗口：进入跟踪循环持续跟随鼠标，真实与合成鼠标事件均有效。
    func beginManualDrag(with event: NSEvent) {
        guard let window else { return }
        let startOrigin = window.frame.origin
        let startMouse = NSEvent.mouseLocation
        while true {
            guard let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            if e.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: startOrigin.x + now.x - startMouse.x,
                                          y: startOrigin.y + now.y - startMouse.y))
        }
    }
}

// MARK: - 主视图

struct MainWindowView: View {
    @EnvironmentObject var vm: ControllerVM
    @StateObject private var recorder = KeyRecorder.shared
    @State private var config = KeyConfig()
    @State private var recordingRow: RowID? = nil
    @State private var shellRow: RowID? = nil
    @State private var shellDraft = ""

    enum RowID: String, CaseIterable {
        case left, right, up, down, menu, mic
    }

    var body: some View {
        ZStack {
            // 整块窗口就是一层薄玻璃（透出桌面 = Liquid Glass）
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)

            // 背景拖动层：内容缝隙/留白处的点击落到这里拖动窗口
            WindowConfigurator.DragLayer()

            VStack(spacing: 0) {
                // 标题（红绿灯左侧由系统绘制在玻璃上）；不参与点击，让拖动穿透到底层
                Text("MAGE Controller")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .padding(.top, 16)

                // 状态胶囊
                statusCapsule
                    .padding(.horizontal, 40)
                    .padding(.top, 8)

                HStack(alignment: .top, spacing: 20) {
                    leftPanel
                        .frame(width: 336)
                    rightPanel
                        .frame(width: 380)
                }
                .frame(height: 516)
                .padding(.horizontal, 32)
                .padding(.top, 16)

                Spacer(minLength: 0)
            }
        }
        .frame(width: 800, height: 640)
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(WindowConfigurator())
        .onAppear { config = vm.loadConfig() }
        .onDisappear { recorder.stop(); recordingRow = nil }
        .onChange(of: recorder.capturedName) { _, name in
            guard let name, let row = recordingRow else { return }
            recordingRow = nil
            let mods = recorder.capturedMods
            let saved = apply(.keystroke(key: name, modifiers: mods), to: row)
            recorder.capturedName = nil
            if saved {
                fileLog("录制: 应用到 \(row.rawValue) -> \(name) + \(mods.joined(separator: "+"))")
            }
        }
        .onChange(of: recorder.recording) { _, on in
            if !on { recordingRow = nil }
        }
    }

    // MARK: 状态胶囊

    private var statusCapsule: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusTitle)
                .font(.system(size: 13))
            Spacer()
            Text(statusDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 26)
        .frame(height: 48)
        .background { Capsule().fill(.regularMaterial) }
        .overlay { Capsule().stroke(strokeColor(strong: false), lineWidth: 1) }
    }

    private var statusTitle: String {
        if vm.helperRunning && !vm.connected { return "按键拦截运行中 · 设备控制暂不可用" }
        return vm.connected ? "MAGE 雪漫天 · 已连接" : "未连接 · 等待设备"
    }

    private var statusDetail: String {
        vm.connected
            ? "\(formatRate(vm.sampleRate)) · \(vm.surround71 ? "游戏模式" : "HiFi 模式")"
            : "—"
    }

    private var statusColor: Color {
        if vm.connected { return Color(hex: 0x34C759) }
        if vm.helperRunning { return .orange }
        return Color.primary.opacity(0.25)
    }

    // MARK: 左栏：设备状态

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设备状态")
                .font(.system(size: 12, weight: .semibold))
                .frame(height: 16)

            DeviceLineArt(
                musicOn: vm.ledOn && !vm.surround71,
                gameOn: vm.ledOn && vm.surround71,
                s71On: vm.ledOn && vm.surround71,
                micOn: vm.ledOn && vm.micOn
            )
            .frame(width: 231, height: 126)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            // 灯位图例
            HStack(spacing: 14) {
                legendDot(on: vm.ledOn && !vm.surround71, "音乐")
                legendDot(on: vm.ledOn && vm.surround71, "游戏")
                legendDot(on: vm.ledOn && vm.surround71, "7.1")
                legendDot(on: vm.ledOn && vm.micOn, "麦克风")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            // 模式胶囊（状态展示）
            HStack(spacing: 12) {
                modePill("HiFi 音乐", active: !vm.surround71)
                modePill("游戏模式", active: vm.surround71)
            }
            .padding(.top, 14)

            Text("采样率")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            HStack(spacing: 8) {
                ForEach(rateChoices, id: \.self) { rate in
                    rateChip(rate)
                }
            }
            .padding(.top, 6)

            Text("麦克风键：按一下静音，再按恢复")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            Toggle("按后自动恢复麦克风", isOn: Binding(
                get: { config.micAutoUnmute },
                set: { value in
                    var updated = config
                    updated.micAutoUnmute = value
                    if vm.saveConfig(updated) { config = updated }
                }
            ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Spacer(minLength: 8)

            Divider()
                .padding(.top, 8)

            Toggle(isOn: Binding(get: { vm.ledOn }, set: { _ in vm.toggleLED() })) {
                Label("指示灯", systemImage: vm.ledOn ? "lightbulb.max.fill" : "lightbulb.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(vm.ledOn ? Color.primary : Color.secondary)
            }
            .toggleStyle(.switch)
            .tint(.green)
            .frame(height: 44)
            .disabled(!vm.connected)

            Text(deviceControlMessage)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor(strong: false), lineWidth: 1)
        }
    }

    private var deviceControlMessage: String {
        if vm.helperRunning && !vm.connected { return "按键拦截期间，设备控制暂不可用" }
        if vm.statusMessage.hasPrefix("命令失败") { return vm.statusMessage }
        return ""
    }

    private var rateChoices: [Double] {
        vm.availableRates.isEmpty ? [48000, 96000, 192000] : Array(vm.availableRates.prefix(3))
    }

    private func legendDot(on: Bool, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? Color.primary : Color.primary.opacity(0.25))
                .frame(width: 6, height: 6)
                .shadow(color: on ? Color.primary.opacity(0.4) : .clear, radius: 4)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(on ? Color.primary : .secondary)
        }
    }

    private func modePill(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: active ? .bold : .regular))
            .foregroundStyle(.primary.opacity(active ? 1 : 0.6))
            .frame(width: 142, height: 36)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(active ? 0.12 : 0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor(strong: active), lineWidth: 1)
            }
    }

    private func rateChip(_ rate: Double) -> some View {
        let selected = abs(vm.sampleRate - rate) < 1
        return Button {
            vm.setRate(rate)
        } label: {
            Text(formatRate(rate))
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(selected ? 1 : 0.6))
                .frame(width: 92, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.12 : 0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(strokeColor(strong: selected), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!vm.connected)
    }

    // MARK: 右栏：按键映射

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("按键映射")
                .font(.system(size: 12, weight: .semibold))
                .frame(height: 16)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        // 左/右键独立；上/下/菜单键共用同一物理键码。
                        ForEach(Array(RowID.allCases.enumerated()), id: \.element) { index, row in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.1))
                                    .frame(height: 1)
                            }
                            bindingRow(row)
                                .frame(height: 52)
                        }

                        if let row = shellRow {
                            shellEditor(row)
                                .id("shell-editor")
                                .padding(.top, 8)
                        }

                        Text("点击快捷键可重新录入")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                        Text("上、下、菜单键共用绑定，修改同步生效")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: shellRow) { _, row in
                    guard row != nil else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("shell-editor", anchor: .bottom)
                    }
                }
            }
            .padding(.top, 12)

            Divider()
                .padding(.top, 8)

            Toggle(isOn: Binding(get: { vm.helperRunning }, set: { _ in vm.toggleHelper() })) {
                Label("按键拦截", systemImage: "keyboard.badge.ellipsis")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .tint(.green)
            .frame(height: 44)
            .disabled(vm.helperTransitioning)

            Text(helperStatusText)
                .font(.system(size: 10))
                .foregroundStyle(helperStatusColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
                .help(helperStatusText)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor(strong: false), lineWidth: 1)
        }
    }

    private func shellEditor(_ row: RowID) -> some View {
        HStack(spacing: 6) {
            TextField("输入要运行的命令", text: $shellDraft) {
                if apply(.shell(shellDraft), to: row) { shellRow = nil }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(strokeColor(strong: false), lineWidth: 1)
            }

            Button {
                if apply(.shell(shellDraft), to: row) { shellRow = nil }
            } label: {
                Image(systemName: "checkmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("保存命令")

            Button {
                shellRow = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("取消")
        }
    }

    private var helperStatusText: String {
        if let message = vm.bindingStatusMessage { return message }
        if let message = vm.helperStatusMessage { return message }
        if vm.helperTransitioning { return "正在更新按键拦截状态…" }
        if vm.helperRunning { return "运行中，设备按键已接管" }
        if vm.helperEnabled { return "按键拦截未运行，请重试" }
        return "未开启"
    }

    private var helperStatusColor: Color {
        if vm.bindingStatusMessage != nil || vm.helperStatusMessage != nil
            || (vm.helperEnabled && !vm.helperRunning) { return .orange }
        return vm.helperRunning ? Color(hex: 0x34C759) : .secondary
    }

    private func bindingRow(_ row: RowID) -> some View {
        HStack(spacing: 12) {
            keycap(row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Text(row.caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            pill(row)
        }
        .contentShape(Rectangle())
    }

    private func keycap(_ row: RowID) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.1))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(strokeColor(strong: false), lineWidth: 1)
            if row == .mic {
                // 系统麦克风图标（与 macOS 菜单栏一致）
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
            } else {
                Text(row.symbol)
                    .font(.system(size: row == .menu ? 14 : 16, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 40, height: 40)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
    }

    private func pill(_ row: RowID) -> some View {
        let recording = recordingRow == row && recorder.recording
        let action = action(for: row)
        return Button {
            if recording {
                recorder.stop()
                recordingRow = nil
            } else {
                recordingRow = row
                shellRow = nil
                recorder.start(timeout: 30)
            }
        } label: {
            HStack(spacing: 6) {
                if recording { RecordingDot(color: Color(hex: 0xFFD60A), size: 6, pulsing: true) }
                Text(recording ? "请按下新快捷键…" : pillText(action))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.primary.opacity(recording || action.isKeystroke ? 1 : 0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(width: 160, height: 26)
            .background {
                Capsule().fill(Color.primary.opacity(recording ? 0.05 : 0.08))
            }
            .overlay {
                Capsule().stroke(
                    recording ? Color(hex: 0xFFD60A)
                        : strokeColor(strong: action.isKeystroke),
                    lineWidth: recording ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(recordingRow != nil && !recording)
        .contextMenu {
            Button("录制新快捷键") { recordingRow = row; recorder.start(timeout: 30) }
            Button("运行命令…") {
                shellRow = row
                if case .shell(let cmd) = action { shellDraft = cmd } else { shellDraft = "" }
            }
            Button("屏蔽") { apply(.block, to: row) }
            Divider()
            Button("恢复默认") { apply(row.defaultAction, to: row) }
        }
    }

    // MARK: 配置读写

    /// 行的物理键 → 配置键码。左/右独立；上/下/Menu 共用 playPause；麦克风走 micKey
    private func action(for row: RowID) -> KeyAction {
        switch row {
        case .left:  return config.keys[MageKey.volumeDown.rawValue] ?? .block
        case .right: return config.keys[MageKey.volumeUp.rawValue] ?? .block
        case .up, .down, .menu:
            return config.keys[MageKey.playPause.rawValue] ?? .block
        case .mic:   return config.micKey
        }
    }

    @discardableResult
    private func apply(_ action: KeyAction, to row: RowID) -> Bool {
        var updated = config
        switch row {
        case .left:  updated.keys[MageKey.volumeDown.rawValue] = action
        case .right: updated.keys[MageKey.volumeUp.rawValue] = action
        case .up, .down, .menu:
            updated.keys[MageKey.playPause.rawValue] = action   // 三键同码，同步生效
        case .mic:   updated.micKey = action
        }
        guard vm.saveConfig(updated) else { return false }
        config = updated
        return true
    }

    private func pillText(_ action: KeyAction) -> String {
        switch action {
        case .block:
            return "已屏蔽"
        case .shell(let cmd):
            let short = cmd.count > 14 ? String(cmd.prefix(13)) + "…" : cmd
            return short.isEmpty ? "命令（空）" : "命令: \(short)"
        case .keystroke(let key, let mods):
            let prefix = mods.compactMap { Self.modSymbols[$0] }.joined()
            let name = key.isEmpty ? "" : Self.keySymbols[key] ?? key.uppercased()
            return prefix + name
        }
    }

    private static let modSymbols: [String: String] = [
        "command": "⌘", "option": "⌥", "control": "⌃", "shift": "⇧",
    ]
    private static let keySymbols: [String: String] = [
        "return": "⏎", "space": "空格", "tab": "制表",
        "escape": "退出", "backspace": "删除",
    ]

    /// 玻璃描边：深色模式亮一点，浅色模式暗一点
    private func strokeColor(strong: Bool) -> Color {
        Color.primary.opacity(strong ? 0.35 : 0.18)
    }
}

// MARK: - 行定义

private extension MainWindowView.RowID {
    var title: String {
        switch self {
        case .left: return "左键"
        case .right: return "右键"
        case .up: return "上键"
        case .down: return "下键"
        case .menu: return "菜单键"
        case .mic: return "麦克风键"
        }
    }
    var caption: String {
        switch self {
        case .left: return "默认 音量 −"
        case .right: return "默认 音量 +"
        case .up: return "与菜单键同步"
        case .down: return "与菜单键同步"
        case .menu: return "与上、下键同步"
        case .mic: return "语音输入键"
        }
    }
    var symbol: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .menu: return "M"
        case .mic: return ""
        }
    }
    var defaultAction: KeyAction {
        switch self {
        case .mic: return .keystroke(key: "f13", modifiers: [])
        default: return .block
        }
    }
}

private extension KeyAction {
    var isKeystroke: Bool {
        if case .keystroke = self { return true }
        return false
    }
}

// MARK: - 呼吸黄点（录制态 / 指示灯标识）

struct RecordingDot: View {
    let color: Color
    let size: CGFloat
    let pulsing: Bool
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: size * 0.6)
            .opacity(pulsing ? (lit ? 0.25 : 1) : 1)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil,
                       value: lit)
            .onAppear { if pulsing { lit = true } }
    }
}

// MARK: - 设备线稿（严格按设计稿 550×300 坐标系，55×30mm 实机比例）

struct DeviceLineArt: View {
    var musicOn: Bool
    var gameOn: Bool
    var s71On: Bool
    var micOn: Bool

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 550, size.height / 300)
            ctx.scaleBy(x: s, y: s)
            let line = Color.primary

            // 机身
            let bodyRect = CGRect(x: 0, y: 0, width: 550, height: 300)
            ctx.fill(Path(roundedRect: bodyRect, cornerRadius: 35),
                     with: .color(line.opacity(0.04)))
            ctx.stroke(Path(roundedRect: bodyRect, cornerRadius: 35),
                       with: .color(line.opacity(0.8)), lineWidth: 3.57)
            // 内圈 bezel
            ctx.stroke(Path(roundedRect: CGRect(x: 15, y: 15, width: 520, height: 270),
                            cornerRadius: 22),
                       with: .color(line.opacity(0.3)), lineWidth: 2.38)

            // 十字键（任天堂比例：臂宽 1/3；160 单位路径严格等比缩放到 150）
            var dpad = Path()
            dpad.move(to: CGPoint(x: 122, y: 69))
            dpad.addLine(to: CGPoint(x: 170.8, y: 69))
            dpad.addLine(to: CGPoint(x: 170.8, y: 119.6))
            dpad.addLine(to: CGPoint(x: 221.4, y: 119.6))
            dpad.addLine(to: CGPoint(x: 221.4, y: 168.4))
            dpad.addLine(to: CGPoint(x: 170.8, y: 168.4))
            dpad.addLine(to: CGPoint(x: 170.8, y: 219))
            dpad.addLine(to: CGPoint(x: 122, y: 219))
            dpad.addLine(to: CGPoint(x: 122, y: 168.4))
            dpad.addLine(to: CGPoint(x: 71.4, y: 168.4))
            dpad.addLine(to: CGPoint(x: 71.4, y: 119.6))
            dpad.addLine(to: CGPoint(x: 122, y: 119.6))
            dpad.closeSubpath()
            ctx.fill(dpad, with: .color(line.opacity(0.06)))
            ctx.stroke(dpad, with: .color(line.opacity(0.8)), lineWidth: 3.57)

            // M 圆键
            ctx.fill(Path(ellipseIn: CGRect(x: 300, y: 88, width: 66.7, height: 66.7)),
                     with: .color(line.opacity(0.06)))
            ctx.stroke(Path(ellipseIn: CGRect(x: 300, y: 88, width: 66.7, height: 66.7)),
                       with: .color(line.opacity(0.8)), lineWidth: 3.57)

            // 麦克风圆键
            ctx.fill(Path(ellipseIn: CGRect(x: 409.5, y: 142.9, width: 66.7, height: 66.7)),
                     with: .color(line.opacity(0.06)))
            ctx.stroke(Path(ellipseIn: CGRect(x: 409.5, y: 142.9, width: 66.7, height: 66.7)),
                       with: .color(line.opacity(0.8)), lineWidth: 3.57)
            // 麦克风图标用系统 SF Symbol 叠加绘制（见 overlay），不在 Canvas 内手绘

            // 灯窗
            ctx.fill(Path(roundedRect: CGRect(x: 195.2, y: 214.3, width: 150, height: 47.6),
                            cornerRadius: 14),
                     with: .color(line.opacity(0.04)))
            ctx.stroke(Path(roundedRect: CGRect(x: 195.2, y: 214.3, width: 150, height: 47.6),
                            cornerRadius: 14),
                       with: .color(line.opacity(0.3)), lineWidth: 2.38)

            // 4 颗 LED：音乐 / 游戏 / 7.1 / 麦克风
            // 灯窗 x 195.2..345.2，四灯心等距 38.1、两端边距对称 17.9（=7.5px）
            led(ctx, center: CGPoint(x: 213.1, y: 238.1), d: 21.4, on: musicOn)
            led(ctx, center: CGPoint(x: 251.2, y: 238.1), d: 16.7, on: gameOn)
            led(ctx, center: CGPoint(x: 289.3, y: 238.1), d: 16.7, on: s71On)
            led(ctx, center: CGPoint(x: 327.4, y: 238.1), d: 21.4, on: micOn)
        }
        .overlay {
            // 键位符号（▲▼ 与 M，与机身印刷一致）
            ZStack {
                Text("▲").font(.system(size: 7)).foregroundStyle(.primary.opacity(0.8))
                    .position(x: 61.5, y: 40)
                Text("▼").font(.system(size: 7)).foregroundStyle(.primary.opacity(0.8))
                    .position(x: 61.5, y: 81)
                Text("M").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.8))
                    .position(x: 140, y: 51)
                // 系统麦克风图标（与 macOS 菜单栏一致）；位置 = 按钮心 (442.85,176.25) × s(0.42)
                Image(systemName: "mic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.85))
                    .position(x: 186, y: 74)
            }
        }
    }

    private func led(_ ctx: GraphicsContext, center: CGPoint, d: CGFloat, on: Bool) {
        let tint = Color.primary
        if on {
            let halo = Path(ellipseIn: CGRect(x: center.x - d * 1.5, y: center.y - d * 1.5,
                                              width: d * 3, height: d * 3))
            ctx.fill(halo, with: .radialGradient(
                Gradient(colors: [tint.opacity(0.4), .clear]),
                center: center, startRadius: 0, endRadius: d * 1.5))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - d / 2, y: center.y - d / 2,
                                        width: d, height: d)),
                 with: .color(on ? tint : tint.opacity(0.2)))
    }
}

// MARK: - 颜色 / 格式化工具

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

private func formatRate(_ r: Double) -> String {
    r >= 1000 ? String(format: "%.1f kHz", r / 1000) : String(format: "%.0f Hz", r)
}
