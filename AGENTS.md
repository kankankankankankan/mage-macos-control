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
