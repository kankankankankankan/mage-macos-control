# MAGE Controller 项目交接文档

> FF-182 于 2026-11-13 修订交接与事实索引。以下记录区分历史说明、已交付版本与当前动态状态；继续任务先读对应 Issue 最新评论，不能只读本文就判断设备/任务完成。

## 当前权威入口与接续（FF-182）

- 项目 UUID：`b0dd0eaa-e76a-46fa-a266-d523b9925cbf`。平台本地资源仍是本目录，`execution_mode=worktree`；GitHub 资源 `main` 用于定位，不能假定其与当前验收源树相同。先查实际 branch/HEAD、dirty/untracked 和未推送提交，保护用户修改。
- 本次只读核对本目录 `main` 为 `ea33847432f6ca6c12cca0c02f5cf2163398392a`，领先其 origin/main 1 个提交；这不包含全部后续集成。FF-171 记录的集成 SHA `9f47d389aab9de08e64958e6c2963e459996be06`、完整 Git tree `97c0db1d249c0ae7bf2f18d0991aba68fcb05bde`；这些对象在本地可读取。`MageController` 子树为 `9a461a60804d934d905d24af20ffc5826f775204`，与完整 tree 不是同一标识。起步和交接须重新核对，不能从 main 直接交旧版本。
- 稳定技术栈：SwiftPM tools 5.10，最低 macOS 15，SwiftUI + AppKit，MageKit 与 App/helper；集成版含 MageKitTests。以指定 SHA 的 Package.swift 和脚本为准。构建在该版本独立工作树/输出执行 `swift test --package-path MageController --scratch-path <隔离目录>` 和在 MageController 内 `bash scripts/build-app.sh`。脚本会重建自己的 dist；不得在用户正在使用的包目录运行。现有脚本吞签名失败，必须另行执行 `codesign --verify --deep --strict --verbose=2 <候选.app>` 并核对退出码，成功后才能报告签名通过。本次未修改该产品脚本。
- 产物为 `MageController/dist/MAGE Controller.app`，helper 为其 `Contents/MacOS/mage-helper`；记录候选源码/tree、App/helper hash、签名和隔离启动证据。只使用已授权且不影响正式进程/配置的启动方式，测试进程以精确 PID 记录清理；禁止按名称 pkill。构建、GUI、硬件独占测试按资源串行。
- FF-179 已交付非 root helper 与配置失败反馈；FF-181 `f9d0cbb1a44f0ec85e2b20d64174182d562c39b9` 修复 IOHID 生命周期和响应匹配，均已终态，不因规则升级重启。有关请求序号，既有 `MageKeys/协议笔记.md` 第 61 行本已明确设备计数器不回显主机 seq；FF-181 真实 report 再次证实。具体实现和迟到响应隔离以该修订为准。
- FF-175 后续报告曾把另一台 FIIO 设备误认作 MAGE 的新模式，已被 FF-183 的统一日志/IORegistry 证据纠正。MAGE 的 VID `0x2972`，正常 PID `0x4022` / `0x4026`，观测 USB 位置 `0x01100000`；另一设备 PID `0x0144` 位于 `0x01320000`。不能只按相同 VID 放宽匹配，不能向另一设备写 MAGE 命令。位置仅是该机器该次观测，不硬编码为产品常量。
- FF-183 最近诊断：关闭 7.1 后 MAGE 从总线消失，应用/探针时序/固件/供电根因仍未知；设备固件版本未核实。FF-175 保持 backlog，待用户物理恢复、FF-183 读回验证与可证实结论后由总控放行同版独立复验。物理按键、实体灯与最终恢复状态没有完整验收。动态状态以 FF-171/175/183 当前记录为准，本段不证明现在仍未连接。
- 主要交接：保留 FF-183 上指向总控的一次性 `in_review` 条件唤醒 `01a1d45e-945b-7a96-bcac-4e9bcede078b`；FF-175 的后续验收回报在实际放行时读取现有规则再确定单一来源。阶段关闭仅做已交付汇总，复用已消费版本与证据，不再次完整审查。FF-181 已终态的 blocked 超时监听由 FF-182 清理，其他有效阻塞/超时规则保留。
- 共享工作方式见已绑定 shared-delivery；项目总控维护本文件稳定事实与 Issue 的动态交接记录。Mika 负责用户和跨项目异常，不另建重复项目总控循环。以下旧排障记录保留作为历史依据，不能覆盖本节或最新指定源码。


## 一、项目背景

为 FiiO **MAGE 雪漫天** USB 声卡（耳放，官方页 https://cn.fiio.com/product_details/mage.html ）开发 macOS 控制软件。目标：

1. 拦截设备 HID 按键（上下左右 / Menu / 麦克风键），改成用户自定义快捷键（替换 macOS 默认的音量 ±、播放暂停、麦克风静音）。
2. 控制设备功能：指示灯开关、麦克风开关、7.1 声道切换、采样率切换（采样率变化会触发设备灯变色）。
3. 界面按 macOS Liquid Glass（液态玻璃）风格：透明窗口透出桌面、无背景色、可拖动。

## 二、仓库结构与构建

Git 根目录为 `/Users/walkmen/Documents/开发/FIIO/Fiio升级`，远端 `origin` 是
`https://github.com/kankankankankankan/mage-macos-control.git`。2026-11-13 以本地目录建立
`main` 基线并按用户要求覆盖远端旧 `main`；基线提交 `56da8fbb5d438a9ad6c6791dc0a5ab581d1b8d1e`。
远端此前的 `Sources/MageUIApp` 是不同工程结构，后续以本目录源码为准。
项目资源的本地目录使用 Git worktree 并行；执行前检查 `pwd`、当前分支和变更，
合并时核对具体提交，不将其他任务的 worktree 变更当成主目录已生效。
`.build`、`dist` 和 `MageKeys/mage-*` 可执行产物未纳入 Git，构建产物须单独验证。

```
/Users/walkmen/Documents/开发/FIIO/Fiio升级/MageController   ← SwiftPM 项目（唯一工程）
├── Package.swift                    # swift-tools 5.10, macOS 15+, 两个 executableTarget
├── Sources/
│   ├── MageKit/                     # 协议 + HID + 拦截 + 虚拟键盘（有 FF-178/181 后续修复）
│   │   ├── (VendorChannel / MageProtocol / HIDInterceptor / KeystrokeSimulator …)
│   ├── mage-helper/                 # 集成版为当前用户 helper；旧 main 可能仍有历史启动路径
│   └── MageControllerApp/
│       ├── App.swift                # ControllerVM(单例) + StatusBarController + MenuContent + TopDragHost
│       └── MainWindowView.swift     # 主窗口 + 设备线稿 + NSView.beginManualDrag 扩展
├── scripts/build-app.sh             # 构建 + 打包 dist/MAGE Controller.app（含 Info.plist, LSUIElement=true）
└── dist/MAGE Controller.app         # 产物（菜单栏 App + mage-helper）
```

关键命令（以下启动需在隔离候选中、具备 GUI/设备权限且不干扰正式 App 时执行）：

```bash
cd "/Users/walkmen/Documents/开发/FIIO/Fiio升级/MageController"
bash scripts/build-app.sh                      # 构建+打包
open -a "dist/MAGE Controller.app" --args --open-window   # 启动并开主窗口
open -a "dist/MAGE Controller.app" --args --open-panel   # 启动并展开菜单栏面板（调试用）
open -a "dist/MAGE Controller.app" --args --record-mic     # 开窗口+开始录制麦克风键绑定
```

调试入口（CLI 参数，仅启动时生效）：`--open-window` `--open-panel` `--menu-preview`（SwiftUI 调试窗口预览面板布局）`--record-mic`。
日志：`~/.mage-controller.log`（fileLog 写入）；守护进程日志 `/tmp/mage-helper.log`。
配置文件：`~/.config/mage-controller/config.json`（KeyConfig：keys 映射 + micKey + micAutoUnmute）。

## 三、架构要点（接手前必读）

### 1. 双进程结构
- **MAGE Controller**（普通权限菜单栏 App）：UI + 厂商通道控制 + 虚拟键盘发送。
- **mage-helper**：FF-179 集成版通过当前用户 Process 管理 bundled helper，持久化开关偏好并反馈失败；旧 root/osascript 路径是历史。已有 root helper 冲突需要识别并阻止并行启动，不擅自停止用户进程。

### 2. 设备事实（已实测确认）
- 厂商控制走 HID vendor channel（非音频 UAC 控制面）。
- **上 / 下 / Menu 三个物理键发同一个键码（playPause）** → 改一个同步三；左=volumeDown、右=volumeUp 独立；麦克风键独立。
- 麦克风键物理按下会切换设备端麦克风静音状态，App 收到 push 后执行配置的动作（快捷键/命令/屏蔽），可选 `micAutoUnmute` 自动恢复设备麦克风。
- 7.1 切换涉及 USB 重枚举，需等待实际设备身份与状态恢复；历史约 6s 不是恢复保证。FF-183 的关闭路径仍有未解决设备恢复问题。
- 灯：音乐灯=HiFi 模式、游戏灯+7.1 灯=游戏模式、麦克风灯（蓝）。`ledLight` 命令控总开关。采样率切换由 macOS 音频侧 `AudioControl` 设置，触发灯色联动（设备行为）。
- 设备可能离线：日志常见 `VendorChannel.Error error 2`（未插设备，属正常）。

### 3. 菜单栏 = 纯 AppKit（重要教训）
SwiftUI `MenuBarExtra(.window)` 的面板由系统托管，内容固定尺寸会**塌缩成 66×20**（修不掉）。已弃用，改为 `StatusBarController`（NSApplicationDelegate）：
- `NSStatusItem` + `NSPanel(.nonactivatingPanel)`，透明圆角 hosting `MenuContent`，尺寸由 `NSHostingView.fittingSize` 自动得出（当前 264×316）。
- 面板定位在状态栏图标正下方；点击面板外自动关闭（global event monitor）。
- 主窗口也是 AppKit `NSWindow` + `NSHostingController`（不用 SwiftUI Window 场景，`NSHostingView` 里没有 `openWindow` 环境值会崩）。
- 打开主窗口走通知 `Notification.Name.openKeysWindow` → `StatusBarController.openMainWindow()`。
- `ControllerVM` 是单例（`ControllerVM.shared`），delegate 由 `@NSApplicationDelegateAdaptor` 创建，**不要**指望给 `StatusBarController.shared` 赋值（那不是同一个实例，曾因此闪退）。

### 4. 窗口拖动（重要教训）
- `isMovableByWindowBackground` 对 SwiftUI 内容**无效**（SwiftUI 视图拦截 mouseDown）。
- 弃用 `performDrag(with:)`（对合成鼠标事件不生效）。
- 现方案：① `TopDragHost`（透明 NSTitlebarAccessoryViewController 配件视图，盖住顶部 28pt，红绿灯区域 hitTest 放行）② `WindowConfigurator.DragLayer`（ZStack 底层 NSView，内容缝隙/留白处接住点击）；两者都调 `NSView.beginManualDrag(with:)`——进入 `nextEvent(matching:)` 循环手动跟随 `NSEvent.mouseLocation` 位移。真实鼠标下方向正确（用户实测）。
- 顶部 `Text("MAGE Controller")` 已加 `.allowsHitTesting(false)`，否则满宽文本挡住顶部拖动。
- 历史窗口 frame 800×696 曾导致顶部空白；FF-180 在后续集成中修为实际 800×640（safeAreaRegions/ignoresSafeArea）。验收记录需说明实际版本与窗口尺寸。

### 5. 界面定稿要点（用户逐像素验收过）
- 液态玻璃 = **无背景色**，透明窗口透出桌面（`isOpaque=false`、clear background、`.ultraThinMaterial` 内容），参考 Apple Liquid Glass 文档。
- 主窗口 800×640 固定、圆角 20、红绿灯在玻璃上。
- 设备线稿 `DeviceLineArt`：Canvas 550×300 viewBox（=55×30mm 实机比例），十字键严格任天堂比例（臂宽 1/3，160 单位路径等比缩 150，**无中心圆**）、M 键、麦克风键、4 颗 LED 等距对称（心 x=213.1/251.2/289.3/327.4，y=238.1，直径 21.4/16.7/16.7/21.4）。设备上除 ▲▼ 和 M 外不放文字。
- 图标只用 SF Symbol（用户讨厌 FontAwesome 及自制几何图标）。麦克风图标 = 系统 `mic.fill`（键帽 14pt；机身线稿用 overlay `Image(systemName:"mic.fill")` font 11，位置 (186,74) 点，按 231×126 固定框换算，**改框尺寸要同步改**）。
- 录制态用黄色呼吸点（`RecordingDot`），不要红色圆钮（用户觉得像录音）。
- 菜单栏面板保留状态、指示灯/麦克风/7.1、采样率、打开主界面/退出；FF-174 已将按键拦截迁入主窗口右栏底部，最终以集成版为准。

### 6. 按键映射 UI
- 6 行：左/右/上/下/Menu/麦克风；点胶囊即录制（`KeyRecorder.shared`，需窗口为 key window）。
- 右键胶囊菜单：录制新快捷键 / 运行命令…（shell）/ 屏蔽 / 恢复默认。
- 支持把键盘组合键录入为绑定（用户的核心诉求：录入组合键 → 按 MAGE 键直接发出该组合键）。

## 四、15:09 历史状态快照（保留溯源，不代表当前验收）

已完成：
- [x] 菜单栏面板（NSPanel 方案，264×316，开合/外部点击关闭正常）
- [x] 主窗口液态玻璃界面 + 设备线稿 + 6 行按键映射 + 指示灯开关
- [x] 顶部/留白拖动（真实鼠标验证：用户亲自拖动了窗口）
- [x] 系统麦克风图标两处替换，比例正确
- [x] 采样率芯片点击真实切换设备（44.1/48/88.2 实测）
- [x] 设备连接状态/灯/麦克风/7.1 状态轮询显示

历史记录曾观测设备连接，左键 ⌘⇧F、右键 ⌘G。当前设备/用户配置必须重新只读核实；FF-182 不读取或修改用户正式配置。

当时的待办 / 可改进（非当前执行清单；非 root 与窗口等后续结果见上方）：
- [ ] **重启 App 用新构建验证**（按键拦截修复已编译进 dist，但当前运行的还是旧进程；重启后让用户在菜单栏面板点「按键拦截」→ 授权 → 按设备键验证左/右键不再调音量）
- [ ] **去掉提权对话框**（重大发现：见下「按键拦截排障」第 2 条，macOS 15 非 root 也能 seize，可直接普通权限启动 mage-helper，UX 大改善）
- [ ] 面板开合只有用户手点验证过图标点击（系统状态栏不接受外部模拟点击，无法自动化验证）
- [ ] `--menu-preview` 调试窗口保留中，可选删除
- [ ] 后续可能做 Web/更完整软件外壳；软件形态（SwiftUI AppKit 混合）对集成友好
- [ ] 灯色实测确认（设备灯色随采样率变化的具体规则，说明书未明确，需真机观察）

## 三点五、历史按键拦截排障记录（早于 FF-179，保留原因证据）

用户反馈：面板里打开「按键拦截」后，按设备左/右键**依然能调音量**（拦截未生效）。

### 1. 根因：nohup 假阳性
`toggleHelper` 用 `osascript 'do shell script "nohup ... &" with administrator privileges'` 启动守护进程。macOS 的 `nohup` 在提权 shell（无控制终端）下打印 `nohup: can't detach from console: No such process` 后**直接退出，不执行命令**；而 `osascript` 因后台执行照样返回 0 → UI 显示已开启（假阳性）。`/tmp/mage-helper.log` 里只有那一行 nohup 报错、没有任何 helper 输出，`pgrep mage-helper` 无进程。
**已修复**（已编译，未实测）：去掉 nohup 直接后台执行；启动 1 秒后用 `pgrep -f mage-helper` 核实存活，失败则显示 `/tmp/mage-helper.log` 内容；`KeyConfig` 新增 `helperEnabled` 持久化开关状态；面板在「已开启但未运行」时显示橙色提示行。`helperRunning` 改为 poll 里用 pgrep 实时刷新，不再信 osascript 返回值。

### 2. 重大发现：seize 不需要 root
修复验证过程中发现：**macOS 15 上非 root 进程也能成功 seize 该 HID 设备**（`IOHIDManagerOpen + kIOHIDOptionsTypeSeizeDevice` 普通用户直接成功，日志打出「拦截已启动，设备按键将被接管」）。这意味着 admin 授权对话框可以完全去掉，`toggleHelper` 可直接 `Process` 启动（仍需后台 + pgrep 核实）。**改造时注意**：root 启动的旧 log 文件 `/tmp/mage-helper.log` 属主是 root，普通用户写不了，换路径或先删。

### 3. seize 生效的伴生现象（预期行为，非 bug）
mage-helper seize 设备期间，**App 自己的 VendorChannel 会离线**（日志 `VendorChannel.Error error 0`），UI 显示「未连接」。这是独占的必然结果：厂商通道和 HID 媒体键在同一个 USB 设备上。helper 死后 App 自动恢复（日志「设备上线」）。后续可考虑：拦截生效期间 UI 状态栏显示「拦截中（设备被独占）」而不是「未连接」。
另注意：helper 的 config 监听热重载，App 改绑定后 helper 立即生效，无需重启。

## 五、协作约定（用户偏好）

- 中文沟通；用户会**逐像素挑 UI 问题**，交付前必须自己放大截图核对，不要让用户指出低级错误（原话："不要让我帮你检查低级错误"）。
- 历史使用 Kimi CUA；现在按环境可用且已授权的 GUI 工具操作。历史接口为 Kimi CUA（`cua.getApp('com.fiio.mage-controller')`）自行点击/拖动/截图验证；`screencapture` 可全屏截图（Retina 2x，AppKit 原点在左下）。
- CUA 细节：`listWindows` 只列主窗口；NSPanel 面板不列出，用 `--open-panel` + 全屏截图验证。坐标点击需 `window_id + screenshot_id`（图像 2x 像素，不做 Retina 换算）。CUA 合成 drag 会报告 `user_intervened`（用户真鼠标在动）。
- 不满意时用户会说"你自己看/重新检查"——先自查截图再回复。
- 方向键相关：用户重视十字键视觉比例（任天堂 1/3 臂宽），上下总长 = 左右总长。

## 六、按改动范围选择的验证清单（需同版、隔离和当前可用工具）

1. `bash scripts/build-app.sh` 无 error（记录真实 warning；后续集成报告含 AudioControl.swift 既有 warning）。
2. 启动 `--open-window`，CUA 截主窗口：布局/图标/灯位/绑定显示与改动前一致（除非改动点本身）。
3. 启动 `--open-panel` + `screencapture`，确认面板尺寸（日志 `菜单面板尺寸`）与渲染。
4. 涉及拖动：在顶部条和面板间隙各拖一次，确认窗口位移且按钮点击仍正常（点采样率芯片看状态栏数值变化最快）。
5. 涉及按键录入：`--record-mic` 或 UI 点胶囊录制，查 config.json。


## 七、2026-11-14 新增：模式切换需求 + 网页版逆向成果 + 免拦截 v2 POC

### 用户需求更新（最高优先）
- **切换模式（含 7.1）后设备从总线失联是稳定复现**（用户 11-14 确认，与 FF-183 同源）。
  因此软件**必须具备模式切换能力，且带重启兜底**（救设备 + 日常切换）。这是对 FF-183
  定性的改变：从「调查 bug」变为「功能刚需」。
- 降噪默认值用户不关心准确状态（网页版麦克风区只有音量滑条，降噪是另一个开关），
  软件读设备真实状态显示即可。
- **按键方案确定为「免拦截 v2 架构」**：先在独立 POC 验证，通过后再改正式软件。

### FiiO Control 网页版逆向结论（fiiocontrol.fiio.com，WebHID 单页应用）
- MAGE 在网页版**没有任何按键自定义命令**——按键改键只能靠我们客户端侧方案，做固件不现实
  （固件签名无法绕过，别走这条路）。
- 网页版切换 7.1：只弹确认框 → 发 CHANNEL71_SWITCH(56) → 等设备自枚举，**不发重启命令**。
- 完整命令枚举（与我们的 MageProtocol 同编号体系，可直接在 VendorChannel 发帧）：
  - 6 LED_LIGHT（=我们的 ledLight）、8 VOL_OUTPUT_SWITCH、18 MIC_SWITCH（一致）
  - 11 FIRMWARE_VERSION（固件版本读回，FF-183 悬案"固件版本未核实"可补）
  - 33 RESET_TO_FACTORY、52 MIC_NR_LEVEL（降噪等级读写）、34 MIC_VOL、29/30 麦克风监听
  - 53 GAIN_3D、54 REVERB_LEVEL、55 CHANNEL71_CONFIG（声道相位）、58 CHANNEL71_GAIN
  - 56 CHANNEL71_SWITCH、57 CHANNEL71_RESET、61 SPACE_SIZE、62 ENVIRONMENT_AMBIENCE
  - 122 REBOOT_DEVICE（升级流程在用，模式切换的硬复位兜底）
  - HiFi/游戏双模式**无独立命令**：假设=选择 EQ 预设分类（22 PEQ_PRE / 96 PEQ_PRE_V2，
    game 分类值 257/258），**需实测验证**（发预设选命令 → 看游戏灯）。
- 7.1 是独立开关，HiFi/游戏两种音效模式都能开；唯一互斥对：**7.1 ↔ 麦克风 AI 降噪**
  （官网明示降噪仅非 7.1 模式可用）。
- 主窗口 UI 修正点：「HiFi 音乐 / 游戏模式」胶囊目前用 `vm.surround71` 判断（把 7.1
  当游戏模式），混淆了两个独立维度，后续要拆开。

### 免拦截 v2 架构（已定方向，POC 先行）
目标：去掉 seize / root / 守护进程，按键全链路在 App 内完成。
1. **只读监听**：IOHIDManager 共享模式打开 MAGE（不 seize），HID 回调精确报告
   哪个键按下（不会和 MacBook 自带音量键混淆）。
2. **系统事件抑制**：CGEventTap（.cgSessionEventTap + .headInsertEventTap）拦截
   NSSystemDefined 媒体键事件（subtype=8；音量=NX_KEYTYPE_SOUND_UP/DOWN 0/1，
   播放=0x10），字段 46=subtype、47=(keyCode<<16)|flags，flags&0xFF00==0x0A00 为按下；
   命中「HID 监听 300ms 时间窗内对应键」→ 返回 nil 抑制，否则放行。
   权限=辅助功能/输入监控（用户授权一次，远轻于 root）。
3. 验证点：HID 回调收到事件；对应系统事件被抑制（macOS 音量不弹）；MacBook 键盘
   音量键不受影响；无 seize 时厂商通道保持连接。
- **POC 验证结果（2026-11-14 05:30 通过）**：三项全对——
  ① HID 监听 100% 命中（右键 usage=0xe9、左键 0xea、Menu 0xcd）；
  ② 三个设备键对应系统事件全部「已抑制」（音量条/播放不触发）；
  ③ MacBook 音量键「放行」正常，系统功能不受影响。
  实测日志见 `/tmp/v2-poc.log`（调试期 mask=全部事件，正式集成时收紧为 `CGEventMask(1 << 14)`）。
- **踩过的坑（正式集成时照抄结论）**：
  1. run loop source 必须加 `.defaultMode`，加 `.commonModes` tap 收不到任何事件；
  2. Swift 无 `.systemDefined`，用 `type.rawValue == 14` 判断；
  3. **不要读 CGEvent 字段 46/47**（本系统取不到值，且 `NSEvent(cgEvent:)` 对
     CGEventPost 合成的事件也解不出 subtype/data）——必须用 `NSEvent(cgEvent:)`
     读 `.subtype.rawValue == 8` 和 `.data1`（keyCode=(data1&0xFFFF0000)>>16，
     flags=data1&0xFFFF，(flags&0xFF00)==0x0A00 按下沿）；真实硬件事件可正常解析；
  4. stdout 重定向块缓冲，日志要定期 fflush；tap 回调里需处理 `.tapDisabledByTimeout`
     并 `CGEvent.tapEnable` 自动恢复。
- POC 代码：`v2-poc/`（独立 SwiftPM 包，未跟踪，不碰正式 App）。

### v2 正式集成状态（2026-11-14 完成编译+打包，待用户真机验收）
- 新增 `Sources/MageKit/KeyTapV2.swift`：App 内单进程完成 HID 共享监听 + CGEventTap
  系统事件抑制 + 动作执行（复用 KeyAction/KeystrokeSimulator），API：start/stop/updateConfig，
  回调 onLog/onActionError。
- `App.swift` 改动（旧 helper 进程路径保留为 startHelperLegacy 死代码，含「code after
  return」warning，待验收通过后清理）：
  1. `startHelper` → 先 `stopLegacyHelpers()`（杀旧 seize helper），`AXIsProcessTrustedWithOptions`
     请求辅助功能权限，然后 `keyTap.start()`；`helperRunning` 由 keyTap.state 决定；
  2. `stopHelper` → `keyTap.stop()` + `stopLegacyHelpers()`；
  3. `refreshHelperState` 不再看 helper 进程 PID；
  4. `saveConfig` 成功后 `keyTap.updateConfig(cfg)` 热生效（替代旧 helper 文件监听）；
  5. `stopHelperForAppTermination` 补 `keyTap.stop()`。
- **注意**：v2 下主 App 需要「辅助功能」权限（之前是 helper 独占 HID 不需要）；厂商通道全程在线，
  麦克风键维持现有 push 方案不变。
- 已知遗留：KeyInterceptor 里 MageKey.usage 左/右映射与 POC 实测相反（0xE9=SOUND_UP），
  v2 抑制映射按 POC 实测为准；按键绑定若发现左/右相反需统一修正 KeyInterceptor 后清理。
- 构建：`bash scripts/build-app.sh` 通过，codesign --verify --deep --strict 通过。
- **验收（2026-11-14 05:42 用户确认通过）**：自定义动作触发 ✓、音量条不弹 ✓、
  MacBook 音量键正常 ✓。

### 免重插修复 + 默认开启（2026-11-14）
- **Bug：启动时已连接的设备收不到按键（必须重插）**。根因：IOHIDManager 管理器级
  value 回调只对「注册回调后新匹配」的设备投递，对打开时已连接的设备不投递。
  **修法（勿回退）**：改用 `IOHIDManagerRegisterDeviceMatchingCallback` +
  每台设备 `IOHIDDeviceOpen(0)` + `IOHIDDeviceScheduleWithRunLoop` +
  `IOHIDDeviceRegisterInputValueCallback`；removal 回调里对称关闭。
  匹配回调注册时会补调一次已连接设备，热插拔也走同一路径。KeyTapV2 已改为此模式。
- **按键拦截改为默认开启**（KeyConfig.helperEnabled 默认 true，含解码缺省），
  App 启动即自启监听，开关降级为「彻底停用」选项；v2 下厂商通道在线，
  `deviceControlsEnabled` 不再排除拦截中状态，UI 删掉「拦截期间设备控制暂不可用」提示。
- 旧 helper 死代码（startHelperLegacy 等）仍在，验收稳定后清理。
- **免重插修复已验收（2026-11-14 05:48 用户确认）**：设备保持连接直接启动 App，
  按键立即可用，无需重插。用户将继续观察稳定性。

### 音效模式切换 + 固定签名（2026-11-14，已实测，待用户验收）
- **模式切换命令实测打通**（真机双向验证）：
  - 设备无独立 HiFi/游戏命令；网页版经 **EQ 预设 cmd 22** 路由。从线上 bundle 确认预设表：
    240=BYPASS(HiFi)、257=FPS 258=ACT 259=MOBA 260=MUG（游戏）。
  - 编码：大端最短字节（240→`F0`，257→`01 01`），与网页版 `ms()` 一致；读回 257 为
    两字节 `01 01`，解析用 `MageProtocol.peqPresetValue/Bytes`。
  - 写 257 → 读回 01 01、**游戏灯亮音乐灯灭**（用户亲证）；写 240 → 读回 F0、灯切回。
  - **切换不重启设备、不掉线**（写完立即读回成功），因此比 7.1 的 20 秒重连流程简单：
    `toggleGameMode()` 写后读回验证即可；poll 也会周期读 peqPre 同步 gameMode。
  - 命令号注意：cmd 22 十进制 = 0x16。mage-led 工具 `raw` 按十六进制解析命令号、
    `scan` 按十进制——此前用 `raw 22` 误发到 cmd 0x22=34（麦克风音量），已把音量写回 100。
- **实现**：`MageProtocol` 加 `peqPresetHifi/Game/peqPresetBytes/peqPresetValue/isGamePreset`、
  `firmwareVersion=11`、`rebootDevice=122`；App 加 `gameMode` 状态 + `toggleGameMode()` +
  `rebootDevice()`（手动重启，菜单栏面板有入口）；7.1 失败路径加 `attemptRebootRecovery`
  兜底（等通道可写发 122）。
- **UI 修正**：模式胶囊与 7.1 拆开——胶囊用 `gameMode`（且可点击切换），7.1 灯/图例/
  开关独立用 `surround71`；状态栏文案同步；菜单栏面板加「游戏模式」开关和「重启设备」。
- **固定签名修复权限反复弹窗**：原 adhoc 每次构建哈希都变 → macOS 当新应用重弹权限。
  已建自签名证书 **MAGE Dev Signing**（存于 `~/Library/Keychains/mage-dev.keychain-db`，
  密码 magedev，已配 partition-list 允许 codesign 免弹窗）；`build-app.sh` 改用该证书
  （缺证书时回退 adhoc 并警告）。⚠️ 用户需在 系统设置→隐私与安全性 里对 MAGE Controller
  **重新允许一次**辅助功能（身份从 adhoc 变为证书后是一次性迁移），之后跨构建保留。
- **风险项**：REBOOT_DEVICE(122) 在协议笔记无响应扫描范围（59–160）内，设备可能不支持
  该命令；兜底路径失败会如实提示重新插拔，需真机验证。
- 构建：`build-app.sh` 通过，`codesign --verify --deep --strict` 通过。

### 7.1 关闭卡住修复（2026-11-14 06:30，根因已定位）
- **现象**：开 7.1 正常，关闭时卡 35 秒+（用户 06:25 反馈）。
- **日志时间线**（`~/.mage-controller.log` 22:22:45–22:23:23）：HID 3 秒就重连成功，
  但协调器死等 CoreAudio 音频接口重枚举（实测 17s+）直到 20 秒窗口耗尽 →
  误报失败 → REBOOT 兜底又空等 15 秒 → 设备其实 22:23:23 自己恢复上线。
- **根因**：`DeviceRestartCoordinator.run` 把「音频接口未就绪」当作重试条件，
  而 CoreAudio 重枚举比 HID 慢一个数量级。
- **修法**：HID 恢复且 7.1 状态匹配后，给音频接口 **3 秒专用宽限**（`audioGrace`），
  超宽限按成功收尾（sampleRate=0/空 rates，App 保留旧采样率等轮询刷新）；
  恢复失败现在只表示设备真没回来，REBOOT 兜底保留。41 项单测全过。
- **待用户验收**：关 7.1 应在 ~6 秒内完成（HID 3s + 宽限 3s），不再卡 20 秒。

### Tap 健康检查 + 诊断日志（2026-11-14 06:45，编译打包完成，待用户复测）
- **用户反馈两条 bug**：① 右键绑 ⌥ 连按后变成调音量（自定义动作偶发丢失）；
  ② 上键（0xCD）连按多次后设备失联几秒自动恢复。
- **根因假设①**：连按触发 CGEventTap `tapDisabledByTimeout`，tap 被系统禁用后
  系统媒体键直通（日志里同时段无「已抑制」记录可证）。**修法**：KeyTapV2 新增
  `healthTimer`（每 3s 查 `CGEvent.tapIsEnabled`，被禁即 `CGEvent.tapEnable` 恢复）；
  tap 回调的 disabled 分支加日志；**放行路径**加诊断日志
  （`系统媒体键 N ← 放行（未匹配设备键，lastUsage=…，窗口=…s）`），
  用于区分「tap 失效」与「HID 匹配窗口过期」。
- **设备失联（②）观察结论**：v2 的 removal/matching 回调自动重订阅工作正常
  （日志可见秒级恢复），疑似设备固件在高频按键洪水下自我保护重枚举；
  待用户复测确认 healthTimer 生效后失联是否仍发生。
- 注意：`State` 枚举带关联值无自动 Equatable，比较用 `state.isRunning`（文件级扩展）。

### 长按重复泄漏 + 离线期媒体键全抑制（2026-11-14 06:52 实测定位，已打包待复测）
- **日志实证（右键连按）**：HID 每按只报一次按下沿，但按住时系统以 ~83ms 间隔
  自动重复发 NX 媒体键事件；300ms 匹配窗口过期后重复事件全部「放行」→
  音量条弹出/音量变化（用户报「右键有时变成音量」）。上键同理会泄漏播放键
  → Apple Music 弹出。
- **修法（KeyTapV2.tapCallback 三层判定）**：
  1. HID 命中（原 300ms 窗口）→ 记录 lastMatchKeyCode/lastMatchTime；
  2. 同键码 + 距上次抑制 < 1.2s 滑窗续期抑制（长按重复全部吞掉；代价：设备键后
     1.2s 内按 MacBook 同功能键丢一拍）；
  3. `suppressAllMediaKeys`（App 在 `!connected || deviceTransitioning` 时置真，
     两个 @Published 的 didSet 同步）→ 音量/播放类全抑制，防离线窗口漏播放键。
  放行/全抑制诊断日志限频 2s 一条（原 12Hz 写盘）。
- **「设备离线: MAGE HID 响应超时」是单次 poll 超时误报**：HID 实际未断
  （无「设备已移除」日志），2s 后下轮 poll 自动恢复「设备上线」；疑似按键洪水期
  设备固件延迟响应厂商命令。暂不处理，观察中。

### 单修饰键回放失效修复（2026-11-14 07:00 用户复测定位，已打包待复测）
- **现象**：右键绑「单 ⌥」日志显示动作已执行（`→ 快捷键: option+`）+ 系统媒体键
  已抑制，但 Typeless 无反应。从未生效过（06:33 用户首次提出时即无效）。
- **根因**：`KeystrokeSimulator.legacyPost` 纯修饰键分支用 `CGEvent(source: nil)`
  造 flagsChanged 事件，**keyCode=0 且无事件源**。按 keyCode 匹配修饰键的热键应用
  （Typeless 的单 ⌥ 触发即此类）会忽略该事件。
- **修法**：`modifierKeyCode` 表（option→58 左/61 右、command→55/54、shift→56/60、
  control→59/62、fn→63），`CGEventSource(hidSystemState)` + 逐键按下（flags 累积）
  → 30ms → 逆序抬起（flags 递减），仿真真实键盘。
- **顺手**：KeyTapV2 动作执行挪到串行后台队列 `mage.keyaction`（原在主 runloop
  上 usleep 60ms+，阻塞期间 HID 设备事件可能丢失——疑为偶发「按了没反应」诱因）。
- 已知噪音：日志偶发「事件监听被系统禁用」→ healthTimer 3s 内自动恢复，残余
  窗口小，观察中。

### 录制器区分修饰键左右侧（2026-11-14 13:39 用户复测定位，已打包待复测）
- **现象**：设备键绑「右侧 Command」，日志显示动作已执行（`→ 快捷键: command+`），
  但目标应用无反应。
- **根因**：`KeyRecorder.handle` 的 flagsChanged 分支只读 `modifierFlags`——
  该 mask 不分左右（右⌘=左⌘），录到的是通用 "command"；回放按左侧（keyCode 55）
  发送，需要右侧（54）的热键应用不识别。
- **修法**：新增 `modsByKeyCode`（54/55⌘、58/61⌥、56/60⇧、59/62⌃、63 fn），
  flagsChanged 按 keyCode 记侧别名；chord 数组跟踪当前按住集合，全部松开时
  以「按下过的完整组合」收尾。keyDown 组合分支侧别信息在 flags 里已丢失，
  维持通用名（组合键多数应用不分侧）。
- 用户需**重新录制**右侧 Command（旧配置存的是通用 command=左侧）。
- 另：13:31:54 一条 `左键 → keyCode1 放行` 为按右键长按的余波事件（重启前旧状态），
  非匹配表错误——左键↔0 / 右键↔1 与 `nxKeyCode` 表一致，勿动。

### 侧别修饰键 UI 显示修复（2026-11-14 13:46，已打包待复测）
- **现象**：录制右侧 Command 后 pill 空白；左侧 Command 正常显示。
- **根因**：`MainWindowView.pillText` 的 `modSymbols` 只含通用名，
  `right_command` 经 `compactMap` 被丢弃 → 纯修饰键时返回空串。
- **修法**：`modSymbols` 增加 `right_*` 映射（显示「右⌘/右⌥/右⌃/右⇧」）。
  录制→存储→回放链路本身已正确（13:39 修复），仅显示层缺映射。

### 菜单栏面板三问题修复（2026-11-14 13:50 用户反馈，已打包待复测）
- **问题①「选完面板不消失，一直停留在上面」**：`openMainWindow` 未收面板；
  面板是 `isFloatingPanel` 浮动窗，永远压在主窗口上方。修法：打开主界面前
  `panel?.orderOut(nil)` 确定性收起。
- **问题②「点击后主界面乱飘」**：`MainWindowView` 曾把 `DragLayer` 全窗口铺在
  ZStack 底层，点按任何留白/缝隙即进入 `beginManualDrag` 误拖。修法：改为
  `.overlay(alignment: .top)` 仅覆盖顶部 36pt 标题栏区域，`.padding(.leading, 84)`
  避开红绿灯。与「顶部可拖动」诉求一致。
- **问题③「有时主界面出来后面板又消失」**：面板浮于主窗口之上时，点到覆盖区域
  会触发 `closePanelIfOutside` 的异步位置判断（Task 跳主队列有竞争），时有关时无关。
  ①的确定性收起使该竞争路径不再出现。
- 用户另报「界面上还有一些问题」，待用户给截图/具体描述。

### 指示灯(cmd6)真机实测结论 + mic 灯红闪可行性判定（2026-11-14 14:10 实测）
- **cmd 6 SET 真机无效**：`mage-led led off` 写入+读回均成功且读回稳定保持 0，
  但物理灯无变化（用户确认 1 号音乐灯、4 号麦克风灯仍亮；2/3 号本就灭）。
  `led on` 时用户观察到灯「灭一下瞬间又亮」= 写 1 会重启灯控（可见闪断），
  写 0 物理无任何效果。**结论：cmd 6 的读回状态与物理灯脱钩**，
  四灯 = 模式/状态指示（音乐灯=HiFi 模式活跃、游戏灯、7.1 灯、麦克风灯=mic 状态），
  软件「指示灯」开关控制不了它们。历史文档 MAGE_LED_STATUS.md 早有预警：
  「LED_LIGHT 的 GET 名称不等于已确认 SET 帧」。⚠️ 官方网页面有「指示灯开关」
  入口——若官方开关物理有效则我方帧有差异，待用户网页版实测对比（未做）。
- **cmd 51（自猜 ledCtrl）无响应**：`color idx=0` 无 ACK；且 51 不在网页 bundle
  确认命令表中（52 是 MIC_NR_LEVEL）。命令空间 0–160 已全扫（59–160 无响应），
  **协议中不存在逐灯 RGB/颜色/闪烁控制命令**。
- **mic 灯「红色闪烁」需求判定不可行**：mic 灯颜色由固件按 mute 状态驱动
  （蓝=开麦、红=静音，颜色表见历史文档未完全确认），无命令可改色/闪烁；
  用快速 toggle 静音模拟闪烁会切断语音流，不可接受。
  替代方案：软件侧指示（菜单栏图标红色脉冲/面板「正在听写」态）。
- 工具共存确认：`mage-led` CLI 与运行中的 App 可同时访问设备（共享打开）。

### 指示灯之谜最终结论（2026-11-14 15:00 系列实验定案，已修已打包）
上文「cmd6 真机无效」结论**部分推翻**。真相是三层模型：
1. **cmd6 寄存器完全有效**：`=1` 灯常亮、`=0` 灯可灭（网页面板实测双向验证，
   帧 `aa 0a seq 06 01 v crc ee` 与我们逐字节一致）。
2. **固件「活动闪灯」行为（本案根因）**：**任何 HID 流量**（读或写、任意命令）
   都会让物理灯点亮约 3–5 秒，与寄存器无关。纯连接不发命令→灯不亮；
   发一条 GET→灯亮数秒→自动灭。之前观测到的「写 off 无效」「灭一下又亮」
   全是 App 每 2 秒轮询 4 条命令（ledLight/micSwitch/channel71/peqPre 的 GET）
   不断刷新闪灯所致，cmd6 被冤枉。
3. **设备不会在无请求时主动推送**（探针纯挂 8 秒零回包）。之前看到的
   "2.2s 推送"其实是轮询回包。
- **修法（App.swift `poll(force:)`）**：寄存器=0 且已连接时进入静默轮询——
  90 秒一次心跳仅作掉线/重插检测；`poll(force: true)` 仅供用户主动打开
  菜单栏面板/主界面时用一次（与官方面板切页行为一致，代价一次闪灯）；
  `toggleLED` 后调 `poll()` 让开灯恢复常规轮询、关灯转入静默。
  灯亮期间常规 2s 轮询无害（灯本常亮，闪断不可见）。
- **已知残余**：静默期掉线最多 90s 才被心跳发现；灯灭时打开主界面/面板
  会闪一次灯（面板同款，无解）。
- **面板行为佐证**：连接时一帧 GET 爆发；LED 开关 off→发送
  `aa 0a .. 06 01 00 ..`（与我们相同）；off 后彻底无流量→灯真灭。

### 静默期零流量断线检测（2026-11-14 15:20 实现，15:2x 用户复测通过）
- 上一版静默期靠 90s 心跳轮询检测拔插——灯会每 90s 闪一下，非零打扰。
- 现改为 **IOHIDDevice 移除通知**（`IOHIDDeviceRegisterRemovalCallback`）：
  VendorChannel 新增 `onDeviceRemoved` 回调，`handleDeviceRemoval` 用 generation
  守卫（7.1 切换的重连流程会推进 generation，旧设备移除通知作废）。
  注意：回调在 IO worker runloop 触发，`stopAndWait` 已有 calledFromWorker
  防自等待，关闭走原 `closeSerialized`，无线程问题。
- App 侧：静默期（ledOn=false && connected && !force）完全不排轮询；
  移除通知→主线程置 disconnected→poll() 转入 2s 重连循环（设备不在时
  open() 失败无流量；重插即恢复）。`poll(force:true)` 仅供菜单栏面板/
  主界面 onAppear 用一次。
- `swift test` 全绿；已打包 dist/MAGE Controller.app。

### mic 灯听写指示（方案C=A+B）+ 录制器左右修饰键修复（2026-11-14 15:37 已打包待复测）
**背景**：mic 灯颜色由固件按 mute 状态驱动，协议无改色/闪烁命令（0–160 已全扫）。
方案A=反向利用 mute 状态做听写指示；方案B=菜单栏图标红色脉冲；用户选组合 C。

- **KeyConfig 新增 `micLampDictation`**（默认 false）：开启后每次按 mic 键翻转
  App/helper 内部听写态，并把设备麦克风强制对齐——听写=开麦（蓝灯）、待机=静音（红灯），
  取代 micAutoUnmute 的固定开麦（两者 UI 互斥，开启 dictation 时 autoUnmute 禁用）。
- **双链路实现**：v2 现行链路=App `micKeyPressed()`（设备 cmd18 推送→handlePush）+
  连接时 pollOnce 内对齐；旧版 seize helper（KeyInterceptor）同步实现
  （start 时对齐 + handleMicKeyPress 翻转），`onDictationChange` 经
  HelperStatusRecord 新增可选 `dictating` 字段传给 App（App 仅在
  adoptableHelperPID 存在时采用，且 keyTap/helper 都不跑时强制 dictating=false
  防脉冲卡死）。
- **菜单栏脉冲**：StatusBarController sink `$dictating`，0.7s 红色 contentTintColor
  闪烁；主界面麦克风区新增开关+状态点（蓝=听写/红=待机）。
- **录制器左右修饰键修复**：KeyRecorder.handle 的 keyDown 分支原来从
  deviceIndependentFlagsMask 读修饰键（不分左右），「右⌘+,」被录成通用 command。
  改用 chord 数组里的侧别名（flagsChanged 按 keyCode 记录）——「录制前才按住修饰键」
  的窗口期仍未覆盖（与 13:39 修复同一局限，先按修饰键再录）。
- 局限：闪烁仍不可能（硬件无命令）；待机=静音意味着平时麦克风采集关闭（用户已认可）。

### 集成构建 2026-11-14 17:17（含他方改动，已打包待用户测试）
本构建合并了多位智能体的改动，`swift build`/`swift test` 全绿：
- **固定身份签名**（他方，`scripts/build-app.sh`）：MAGE Dev Signing 自签名证书
  （位于 ~/Library/Keychains/mage-dev.keychain-db，脚本自动解锁）。
  解决 adhoc 每次构建哈希变化 → macOS 当新应用反复弹「辅助功能/输入监控」
  权限框的问题；授权跨构建保留。若证书缺失脚本回退 adhoc 并打印警告。
- **7.1 切换音频宽限**（他方，`DeviceTransition.swift`）：HID 恢复且 7.1 状态
  匹配后，USB 音频接口给 1s 专用宽限（CoreAudio 重枚举实测 17s+，不阻塞判定）；
  超宽限按成功收尾，采样率由正常轮询稍后刷新。修「切出 7.1 卡好久」。
- **协议补充**（他方，`MageProtocol.swift`）：cmd 11=固件版本、cmd 122=设备硬重启
  （模式切换失联兜底）；peqPre(22) 预设表注释：240=BYPASS(HiFi)、257-260=游戏；
  `isGamePreset`/`peqPresetBytes`/`peqPresetValue` 编解码工具。
- **本轮（15:37 条目）**：micLampDictation 听写指示（蓝灯=听写/红灯=待机+
  菜单栏红色脉冲）+ 录制器左右修饰键修复，均已包含在本构建。

**用户测试清单**：
1. 退出旧 App → 打开 dist/MAGE Controller.app（固定签名后不应再弹权限框）。
2. 指示灯开关：关→灯灭且不再周期闪；开→灯常亮。
3. 按键映射：给方向键录「右⌘ + ,」，确认显示并生效（先点录制再按修饰键）。
4. 主界面打开「待机静音·蓝灯=听写中」，按 mic 键：灯蓝+菜单栏红色脉冲，
   再按：灯红+脉冲停。
5. 7.1 开关切换速度确认。

### 拖动漂移 + 面板/窗口关闭即退出（2026-11-14 17:23 已修已打包待复测）
**退出问题**：SwiftUI `App` 生命周期默认最后一个窗口关闭即退出整个 App。
面板（NSPanel）收起后主窗口计数归零 → 再点图标 App 已死；主窗口红灯关闭同理。
日志佐证：~/.mage-controller.log 里 17:19–17:20 反复出现「App 启动」=用户反复重开。
修法：`StatusBarController` 实现 `applicationShouldTerminateAfterLastWindowClosed`
返回 false，退出只走菜单栏「退出 MAGE Controller」。

**拖动漂移**：录屏（17.17.26.mov）复现：拖标题栏时窗口相对光标滑动、光标远离
窗口窗口仍移动。原实现用 `NSEvent.mouseLocation`（全局屏幕坐标）与
`window.frame.origin` 做绝对跟随——事件合并/坐标系基准不一致时会漂。
修法（`MainWindowView.beginManualDrag`）：改用事件流内 `locationInWindow` 增量
驱动（数学上等价绝对跟随且自校正），真实与合成鼠标事件均有效，保留原 API 选择。

### 拖动漂移最终修复（2026-11-14 17:31 已修已打包待复测）
**更正 17:23 条目的归因**：增量版仍复现漂移（录屏 17.27.15.mov：光标远离窗口
窗口仍高速弧线滑动）→ 根因不是坐标系，是**事件源**。用户开着 Kimi Computer
Use 语音/远程控制鼠标，合成事件流与真实事件交错进 nextEvent 手动循环，把窗口
拖飞；warp#1658 同款系统 bug 场景（macOS 27.x 远程输入会话后拖拽失灵）。

**修法**（`MainWindowView.beginManualDrag` 双轨）：
- 真实输入（`cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == 0`）→
  `window.performDrag(with: event)`，AppKit 原生跟踪循环，社区标准做法。
- 合成事件才走手动循环，内置双保险：`pressedMouseButtons & 1` 看门狗（按钮
  未按下即退出，根治松手后还动）+ 单事件位移 >100px 丢弃（防注入风暴）。
- `DragView` 补 `acceptsFirstMouse(for:)`（注意是方法不是属性）。

**待用户复测**：正常手拖标题栏应完全不漂；用 Kimi CU 拖也不应再飞窗口。
若 performDrag 在 macOS 27.x 上间歇失灵（warp#1658），再考虑 Accessibility API 方案。

### 录屏反馈修复 + 液态玻璃 + 采样率全量（2026-11-14 17:40 已修已打包）
依据录屏 17.33.12.mov 与用户三点诉求（枯白液态玻璃文章 / 录屏问题 / 采样率不全）：
1. **断连闪断置灰**：pollOnce 单次失败即 connected=false（HID 偶发忙抖动→面板瞬间
   「未连接」全灰）。加 pollFailures 防抖：连续 3 次失败（约 6s）才判离线，
   偶发失败只记「轮询抖动(n/3)」日志。
2. **采样率截断为 3 个**：menuRates/rateChoices 的 `.prefix(3)` 去掉，全量展示
   CoreAudio 上报档位（LazyVGrid adaptive 自动换行）；fallback 补全到 8 档
   （44.1…384k）。选中判定放宽为 ±1%。
3. **「48.1 kHz」怪值**：CoreAudio 实际速率如 48094 → formatRate 两处统一改为
   吸附标准档显示（48 kHz / 44.1 kHz），非标准值仍显示原始一位小数。
4. **菜单头部截断**：采样率 Text 加 `.layoutPriority(1).fixedSize(horizontal:true)`。
5. **液态玻璃**（x.com/Kubai087 6 层配方，SwiftUI 可复现部分）：新增
   `LiquidGlassCard` modifier（regularMaterial + 体积投影 + 左上亮/右下暗边缘光
   双描边），应用于主窗口左右面板与菜单栏面板；折射/文字混合模式需 Metal，
   以边缘渐变近似。菜单预览窗口可用 `--menu-preview` 参数打开。

### FiiO 网页面板功能审计（2026-11-14 17:46 WebBridge 实机扫描）
面板四页：游戏 / HIFI / 均衡器 / 配置。设备连接走 WebHID，与本 App 的
IOHIDManager 通道可共存（实测同时在线互不挤占）。
**面板有而本 App 没有的功能（协议待逆向）**：
- 全局增益 slider（-24..+12 dB，当前 0.0 dB）
- 10 段 PEQ 手动调节（每段 -24..+12 dB；USER1-3 三个自定义预设可改名）
- 3D 增益 slider（0..10，当前约 7）
- 混响 slider（0..100，当前 0）
- 麦克风音量 slider（0..100，当前约 80）——用户之前问的「降噪滑块」其实是这个
- 7.1 声道：FL/FR/FC/LFE/SL/SR/RL/RR 各自角度 slider（默认 315/45/0/0/270/90/225/135°）
  + 听音位置 + 重置角度
**已有对应**：LED 灯开关、麦克风静音开关（=cmd6 micSwitch）、EQ 预设
（7 音乐预设 + USER1-3 + 关闭EQ，游戏/HIFI 两页共用同一组卡片）、
固件在线更新、恢复出厂设置。
**下一步**：要支持上面缺失项，需在面板操作时抓 HID 流量定位 cmd ID
（参考 SEND aa/bb 帧日志的做法）。

### 采样率写入实测确认（2026-11-14 17:53）
CoreAudio 实测（/tmp/mage_rate_test2.swift）：MAGE 输出接口（AudioDeviceID 示例 146）
上报 8 档 44.1/48/88.2/96/176.4/192/352.8/384k，`kAudioDevicePropertyNominalSampleRate`
写入**确实生效**（96k/44.1k/192k 读回全部命中）。注意：空闲状态下生效有 0.5–1s
传播延迟，App 里 setRate 后乐观赋值 + 轮询刷新是对的。系统里第二个同名接口
（仅 48k、拒写）是麦克风输入口，不是输出——选择输出设备时不要选错。

### mic 灯颜色之谜最终结论（2026-11-14 18:22 实验定案）
**设备 4 盏灯完全由固件控制，主机寄存器写入无法改变灯色**。证据链：
1. 写 micSwitch(cmd18) 回包正常但灯无任何变化（用户 12 秒对照实验目击确认）；
2. 官方网页面板用的就是同款 cmd06/cmd18（WebHID 抓帧实证 `aa 0a .. 06/12 01 00/01`），
   说明 FiiO 官方也没有灯色指令；
3. mic 键是**厂商通道 cmd18 推送**（非标准 consumer usage），固件自己切灯：
   实测默认行为 按一下=灯灭(静音)、再按=蓝(开麦)；
4. 红色确实存在，但只出现在**恢复出厂序列**（四灯齐红闪→全灭→重启），
   固件内部流程，无主机触发指令（cmd33 恢复出厂会触发但它是破坏性操作）。
**最终方案**：听写指示 = 菜单栏红色 mic 图标脉冲（contentTintColor 在新系统上
渲染不可靠，已改为 sourceAtop 烘焙红色位图交替）；mic 寄存器写入保留
（音频路径需要），UI 文案改为「听写模式（菜单栏红灯指示）」。
**寄存器读取侧新收获**（独立通道探针实测）：micVol(34)=89、gain3d(53)=10、
reverbLevel(54)=0、channel71Config(55)=16字节小端角度
（315/45/0/0/270/90/225/135，与面板一致）；ledCtrl(51)/micNrLevel(52)/
firmwareVersion(11) 读取无响应（51/52 是猜的 ID，未证实）。
**探针要点**：CLI 探针必须跑 RunLoop（响应靠回调）；超时命令会 closeSerialized
拖垮后续命令，要每命令独立通道；设备有多个同名 HID 接口（0x4022=厂商通道，
0x0144=另一接口无响应），要按响应筛选。

### 官方说明书灯色表 + 按键逻辑定案（2026-11-14 18:45 官网说明书 PDF 实证）
说明书来源：cn.fiio.com 下载中心「MAGE说明书」（`MAGE_manual.pdf` 已存项目根目录，
8 页图片型 PDF，需渲染看图）。核心两页结论：
**指示灯官方定义（第 3 页表格，已落入软件线稿）**：
- 音乐模式指示灯：开 → PCM≤48kHz **浅蓝**、PCM>48kHz **黄**、DSD **绿**；关 → 灭
- 游戏模式指示灯：同音乐灯（浅蓝/黄/绿按采样率）
- V7.1 指示灯：开 → **浅蓝**，8 声道=**闪烁**、2 声道=常亮；关 → 灭
- 麦克风指示灯：开 → **浅蓝**；关 → 灭（与此前实测「按一下灭/再按蓝」一致；**红色
  不在常态表内**，只在恢复出厂序列出现）
- 已改 `DeviceLineArt`：新增 `rate` 参数，音乐/游戏灯按 `rate<=48050` 选浅蓝(0x4FC3F7)/黄；
  7.1 灯用 TimelineView 0.5s 周期闪烁；图例圆点同色联动。DSD 绿暂无法实现
  （CoreAudio 无法判别 DSD 状态，DSD 时按上报速率着色）。
**按键逻辑官方定义（第 1-2 页，M 键即 MAGE 功能键 = 我们的 Menu 键）**：
- 短按 M：播放/暂停；**双击 M：开/关 7.1 虚拟环绕**；**长按 M 2 秒：游戏↔音乐模式循环切换**
- 短按 mic 键：麦克风开/关；**M + mic 同按 1 秒：恢复出厂**（四灯齐红闪 1 秒→全灭→重启，
  这就是用户看到的唯一红灯场景）
- AI 降噪：3.5mm 麦克风输入在**非 7.1 模式**下支持（与此前结论一致）
**此前「灯颜色未知」问题全部闭环**：常态灯只有浅蓝/黄/绿三种（按采样率），
mic 灯无红色常态。用户问「红灯单独显示」 officially 不存在（仅恢复出厂）。

### 听写指示实验功能整体拆除（2026-11-14 19:30 用户指示）
mic 灯硬件可控性已证伪（见上节），用户决定放弃整套「听写指示」方案：
- 删除菜单栏红色脉冲（applyDictatingPulse/tintedIcon/dictatingTimer）、
  ControllerVM.dictating、KeyInterceptor 的 dictating/onDictationChange/micLampDictation、
  App 内 micLampDictation 对齐块、主窗口「听写模式」Toggle 与状态行、
  HelperStatusRecord.dictating 字段、mage-helper 的听写状态写入。
- 保留：mic 键快捷键映射（用户 Typeless 工作流 = 纯按键映射，不依赖本功能）、
  micAutoUnmute。config.json 的 micLampDictation 键已删（旧配置多出的键
  JSONDecoder 默认忽略，向后兼容）。麦克风键工作逻辑不变：按一下 = 触发映射快捷键
  （默认静音切换）+ 可选自动恢复开麦。

### 灯色联动测试基建 + 采样率实测（2026-11-14 20:10）
- `DeviceLineArt` 已抽取为独立文件 `Sources/MageControllerApp/DeviceLineArt.swift`
  （含 Color(hex:) 扩展；formatRate 留在主视图），可单独编译做离屏渲染测试：
  `swiftc /tmp/main.swift Sources/MageControllerApp/DeviceLineArt.swift -framework SwiftUI -framework AppKit -o /tmp/lineart_test`
  （main.swift 里用 ImageRenderer + MainActor.assumeIsolated 出 PNG）。
- 三组场景（96k/44.1k/192k+游戏+7.1）离屏渲染验证通过：音乐/游戏灯随采样率黄/蓝切换正确，
  7.1 灯 TimelineView 闪烁正常。
- 通用采样率写入脚本 `/tmp/mage_set_rate.swift <rate>`（按设备名+输出声道数自动找输出接口，
  不再写死 ID；设备当前 id=144）。注意 AudioBufferList 遍历时 mBuffers 不能下标，
  要用 assumingMemoryBound(to: AudioBuffer.self)。
- 实测：用户此前已手动切到 384k；脚本切 96k 一次成功。设备实机灯色待用户目验。
- **实机目验闭环（20:12）**：96k 下用户确认音乐灯=黄色，与官方说明书表、软件线稿
  三方一致，灯色联动功能完成。
- 注意：播放中的音频引擎（Netflix 等）会抢回采样率（实测写 384k 后系统立即回到
  44.1k），空闲时写入才稳定——手动切档在播放中可能被系统覆盖。
