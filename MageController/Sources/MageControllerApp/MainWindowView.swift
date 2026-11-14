// 主窗口：macOS Liquid Glass（液态玻璃）风格
// 无背景色——透明窗口 + 玻璃材质，直接透出桌面；文字用系统色自动适配深浅
import SwiftUI
import MageKit

// MARK: - 液态玻璃卡片
// 参照 Kubai087《液态玻璃材质》(x.com/Kubai087/status/2117782193108082923) 的配方：
//   ① 投影：体积感柔影（.shadow 大尺寸低透明）
//   ② 模糊与提亮：由 .regularMaterial 承担（系统视觉特效，自动采样背后内容）
//   ③ 边缘折射：原文用 SVG 位移贴图 + 色散，SwiftUI 无位移滤镜，
//      以边缘渐变描边近似「边缘一圈更亮、像被压弯」的感觉
//   ⑤ 边缘光：左上亮 + 右下暗一道，再向内缩进补一道微光
// （④着色/⑥文字混合模式/⑦自动深浅：系统材质与系统色已自带，不重复实现）

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                shape
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
            }
            .overlay {
                ZStack {
                    // 主边缘光：左上亮 → 右下暗，模拟玻璃受光
                    shape.stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.55), location: 0.0),
                                .init(color: .white.opacity(0.08), location: 0.35),
                                .init(color: .clear, location: 0.55),
                                .init(color: .black.opacity(0.14), location: 0.8),
                                .init(color: .black.opacity(0.24), location: 1.0),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                    // 内缩一道微亮边，增强「厚玻璃」体积感
                    shape
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                        .padding(1.5)
                }
            }
    }
}

extension View {
    /// 液态玻璃卡片：regularMaterial + 体积投影 + 边缘光（双描边）
    func liquidGlassCard(cornerRadius: CGFloat) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - 窗口透明配置（配合 hiddenTitleBar 实现悬浮玻璃卡片）

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 窗口拖动层：不实现 mouseDown，点击直接交给 NSWindow 的
    /// isMovableByWindowBackground 原生背景拖动——由 WindowServer 合成器加速
    /// 移动窗口（官方写法，高刷屏不掉帧）。应用层 performDrag/手动跟环都会顿挫。
    /// 只铺在顶部标题栏区域（勿全窗口铺——点按留白会误拖窗口）。
    struct DragLayer: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { DragView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class DragView: NSView {
            // 窗口非激活时也能直接拖动
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

// MARK: - 窗口拖动（双轨：真实鼠标走 AppKit performDrag，合成事件走手动循环）

extension NSView {
    /// 按住拖动窗口。
    /// - 真实用户输入：交给 `window.performDrag(with:)` —— AppKit 原生跟踪循环，
    ///   无坐标系换算、无漂移，社区标准做法（Quill / Apple 文档 10.11+ 推荐）。
    /// - 合成事件（Kimi Computer Use 等注入、事件源 PID≠0）：performDrag 不生效，
    ///   退回手动循环；手动循环内置看门狗：左键未按下即退出、单事件位移 >100px
    ///   视为注入风暴直接丢弃——根治「松手后窗口还在自己乱飘」。
    func beginManualDrag(with event: NSEvent) {
        guard let window else { return }

        // 高刷屏拖动掉帧优化：透明玻璃窗口拖动时每帧重算投影是大头，
        // 拖动期间临时关阴影、松手恢复（社区通用做法）
        window.hasShadow = false

        defer { window.hasShadow = true }

        var isSynthesized = false
        if let cgEvent = event.cgEvent {
            // 合成事件（CGEventPost 注入）的 source Unix PID ≠ 0；真实硬件输入为 0
            isSynthesized = cgEvent.getIntegerValueField(.eventSourceUnixProcessID) != 0
        }

        if !isSynthesized {
            window.performDrag(with: event)
            return
        }

        var last = event.locationInWindow
        while true {
            guard let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            if e.type == .leftMouseUp { break }
            // 看门狗：按钮已松开（事件流与真实状态失步）立即退出，不再跟
            guard NSEvent.pressedMouseButtons & 1 != 0 else { break }
            let p = e.locationInWindow
            let dx = p.x - last.x, dy = p.y - last.y
            last = p
            // 注入风暴 / 异常大位移：丢弃不跟，避免窗口被合成流拖飞
            guard abs(dx) < 100, abs(dy) < 100 else { continue }
            var origin = window.frame.origin
            origin.x += dx
            origin.y += dy
            window.setFrameOrigin(origin)
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
        // 仅顶部标题栏区域可拖动窗口：全窗口拖动层会让点按留白/缝隙时误拖（用户报「乱飘」）；
        // 左侧留出红绿灯区域，避免遮挡关闭按钮
        .overlay(alignment: .top) {
            WindowConfigurator.DragLayer()
                .frame(height: 36)
                .padding(.leading, 84)
        }
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
        if vm.deviceTransitioning { return "MAGE 雪漫天 · 设备重启重连中" }
        return vm.connected ? "MAGE 雪漫天 · 已连接" : "未连接 · 等待设备"
    }

    private var statusDetail: String {
        if vm.deviceTransitioning { return "请稍候" }
        return vm.connected
            ? "\(formatRate(vm.sampleRate)) · \(vm.gameMode ? "游戏模式" : "HiFi 模式")\(vm.surround71 ? " · 7.1" : "")"
            : "—"
    }

    private var statusColor: Color {
        if vm.deviceTransitioning { return .orange }
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
                musicOn: vm.ledOn && !vm.gameMode,
                gameOn: vm.ledOn && vm.gameMode,
                s71On: vm.ledOn && vm.surround71,
                micOn: vm.ledOn && vm.micOn,
                rate: vm.sampleRate
            )
            .frame(width: 231, height: 126)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            // 灯位图例（颜色与线稿灯一致：跟随采样率）
            let lampTint = lampColor(rate: vm.sampleRate)
            HStack(spacing: 14) {
                legendDot(on: vm.ledOn && !vm.gameMode, "音乐", color: lampTint)
                legendDot(on: vm.ledOn && vm.gameMode, "游戏", color: lampTint)
                legendDot(on: vm.ledOn && vm.surround71, "7.1", color: lampTint)
                legendDot(on: vm.ledOn && vm.micOn, "麦克风", color: Color(hex: 0x4FC3F7))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            // 音效模式胶囊（可点击切换 HiFi ↔ 游戏）
            HStack(spacing: 12) {
                modePillButton("HiFi 音乐", active: !vm.gameMode) { vm.toggleGameMode() }
                modePillButton("游戏模式", active: vm.gameMode) { vm.toggleGameMode() }
            }
            .padding(.top, 14)

            Text("采样率")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
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
            .disabled(!vm.deviceControlsEnabled)

            Text(deviceControlMessage)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
        }
        .padding(20)
        .liquidGlassCard(cornerRadius: 16)
    }

    private var deviceControlMessage: String {
        if vm.deviceTransitioning { return vm.statusMessage }
        if vm.statusMessage.hasPrefix("命令失败") || vm.statusMessage.hasPrefix("7.1") {
            return vm.statusMessage
        }
        return ""
    }

    private var rateChoices: [Double] {
        // 全量展示（MAGE 规格 PCM 32bit/384kHz + DSD256，经 DoP 表现为高 PCM 档）
        vm.availableRates.isEmpty
            ? [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
            : vm.availableRates
    }

    private func legendDot(on: Bool, _ label: String, color: Color = Color(hex: 0x4FC3F7)) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? color : Color.primary.opacity(0.25))
                .frame(width: 6, height: 6)
                .shadow(color: on ? color.opacity(0.4) : .clear, radius: 4)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(on ? Color.primary : .secondary)
        }
    }

    /// 官方说明书灯色：音乐/游戏灯 PCM≤48kHz 浅蓝、PCM>48kHz 黄、DSD 绿
    /// （DSD 状态 CoreAudio 无法判别，暂按 PCM 档位着色）
    private func lampColor(rate: Double) -> Color {
        rate <= 48050 ? Color(hex: 0x4FC3F7) : .yellow
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

    /// 可点击的模式胶囊（音效模式切换）
    private func modePillButton(_ title: String, active: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            modePill(title, active: active)
        }
        .buttonStyle(.plain)
        .disabled(vm.deviceTransitioning)
        .help("点击切换音效模式")
    }

    private func rateChip(_ rate: Double) -> some View {
        let selected = abs(vm.sampleRate - rate) < rate * 0.01
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
        .disabled(!vm.deviceControlsEnabled)
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
            .disabled(!vm.helperControlEnabled)

            Text("开启后，设备按键不再触发系统默认行为（调音量、切歌），改为你上方自定义的快捷键；关闭则恢复出厂行为。想自定义按键就需要开启。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Text(helperStatusText)
                .font(.system(size: 10))
                .foregroundStyle(helperStatusColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
                .help(helperStatusText)
        }
        .padding(20)
        .liquidGlassCard(cornerRadius: 16)
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
        HelperStatusPresentation.text(
            bindingMessage: vm.bindingStatusMessage,
            helperMessage: vm.helperStatusMessage,
            transitioning: vm.helperTransitioning,
            running: vm.helperRunning,
            enabled: vm.helperEnabled
        )
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
        "right_command": "右⌘", "right_option": "右⌥",
        "right_control": "右⌃", "right_shift": "右⇧",
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


private func formatRate(_ r: Double) -> String {
    // 与 MenuContent.formatRate 同逻辑：吸附标准档，避免 48094 →「48.1 kHz」怪值
    let standards: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
    for s in standards where abs(r - s) / s < 0.01 {
        let k = s / 1000
        let num = String(format: "%.1f", k).replacingOccurrences(of: ".0", with: "")
        return "\(num) kHz"
    }
    return r >= 1000 ? String(format: "%.1f kHz", r / 1000) : String(format: "%.0f Hz", r)
}
