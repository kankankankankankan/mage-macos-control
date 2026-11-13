# MAGE Controller 项目交接文档

> 最后更新：2026-11-13 14:30。本文档面向后续接手的智能体，读完即可继续开发，无需翻历史对话。

## 一、项目背景

为 FiiO **MAGE 雪漫天** USB 声卡（耳放，官方页 https://cn.fiio.com/product_details/mage.html ）开发 macOS 控制软件。目标：

1. 拦截设备 HID 按键（上下左右 / Menu / 麦克风键），改成用户自定义快捷键（替换 macOS 默认的音量 ±、播放暂停、麦克风静音）。
2. 控制设备功能：指示灯开关、麦克风开关、7.1 声道切换、采样率切换（采样率变化会触发设备灯变色）。
3. 界面按 macOS Liquid Glass（液态玻璃）风格：透明窗口透出桌面、无背景色、可拖动。

## 二、仓库结构与构建

```
/Users/walkmen/Documents/开发/FIIO/Fiio升级/MageController   ← SwiftPM 项目（唯一工程）
├── Package.swift                    # swift-tools 5.10, macOS 15+, 两个 executableTarget
├── Sources/
│   ├── MageKit/                     # 协议 + HID + 拦截 + 虚拟键盘（稳定，近期未动）
│   │   ├── (VendorChannel / MageProtocol / HIDInterceptor / KeystrokeSimulator …)
│   ├── mage-helper/                 # root 守护进程（加载 HID 拦截驱动）
│   └── MageControllerApp/
│       ├── App.swift                # ControllerVM(单例) + StatusBarController + MenuContent + TopDragHost
│       └── MainWindowView.swift     # 主窗口 + 设备线稿 + NSView.beginManualDrag 扩展
├── scripts/build-app.sh             # 构建 + 打包 dist/MAGE Controller.app（含 Info.plist, LSUIElement=true）
└── dist/MAGE Controller.app         # 产物（菜单栏 App + mage-helper）
```

关键命令：

```bash
cd "/Users/walkmen/Documents/开发/FIIO/Fiio升级/MageController"
bash scripts/build-app.sh                      # 构建+打包
pkill -f "MAGE Controller"; sleep 1
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
- **mage-helper**（root 守护进程，须 `sudo`）：用 IOKit HID 拦截独占设备按键。App 内「按键拦截」开关通过 osascript 提权启动/关闭。重启 App 后守护进程不自动拉起（状态不持久，待改进项）。

### 2. 设备事实（已实测确认）
- 厂商控制走 HID vendor channel（非音频 UAC 控制面）。
- **上 / 下 / Menu 三个物理键发同一个键码（playPause）** → 改一个同步三；左=volumeDown、右=volumeUp 独立；麦克风键独立。
- 麦克风键物理按下会切换设备端麦克风静音状态，App 收到 push 后执行配置的动作（快捷键/命令/屏蔽），可选 `micAutoUnmute` 自动恢复设备麦克风。
- 7.1 切换后设备会重新 USB 枚举，需延迟 ~6s 重连轮询。
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
- 窗口结构：frame 800×696 = 28pt 标题栏 + 28pt 配件拖区 + 640pt 内容（MainWindowView 800×640）。

### 5. 界面定稿要点（用户逐像素验收过）
- 液态玻璃 = **无背景色**，透明窗口透出桌面（`isOpaque=false`、clear background、`.ultraThinMaterial` 内容），参考 Apple Liquid Glass 文档。
- 主窗口 800×640 固定、圆角 20、红绿灯在玻璃上。
- 设备线稿 `DeviceLineArt`：Canvas 550×300 viewBox（=55×30mm 实机比例），十字键严格任天堂比例（臂宽 1/3，160 单位路径等比缩 150，**无中心圆**）、M 键、麦克风键、4 颗 LED 等距对称（心 x=213.1/251.2/289.3/327.4，y=238.1，直径 21.4/16.7/16.7/21.4）。设备上除 ▲▼ 和 M 外不放文字。
- 图标只用 SF Symbol（用户讨厌 FontAwesome 及自制几何图标）。麦克风图标 = 系统 `mic.fill`（键帽 14pt；机身线稿用 overlay `Image(systemName:"mic.fill")` font 11，位置 (186,74) 点，按 231×126 固定框换算，**改框尺寸要同步改**）。
- 录制态用黄色呼吸点（`RecordingDot`），不要红色圆钮（用户觉得像录音）。
- 菜单栏面板布局：状态头 → 指示灯/麦克风/7.1 开关行（SF Symbol 图标）→ 采样率芯片 → 打开主界面/按键拦截/退出。

### 6. 按键映射 UI
- 6 行：左/右/上/下/Menu/麦克风；点胶囊即录制（`KeyRecorder.shared`，需窗口为 key window）。
- 右键胶囊菜单：录制新快捷键 / 运行命令…（shell）/ 屏蔽 / 恢复默认。
- 支持把键盘组合键录入为绑定（用户的核心诉求：录入组合键 → 按 MAGE 键直接发出该组合键）。

## 四、当前状态（全部截图验证过）

已完成：
- [x] 菜单栏面板（NSPanel 方案，264×316，开合/外部点击关闭正常）
- [x] 主窗口液态玻璃界面 + 设备线稿 + 6 行按键映射 + 指示灯开关
- [x] 顶部/留白拖动（真实鼠标验证：用户亲自拖动了窗口）
- [x] 系统麦克风图标两处替换，比例正确
- [x] 采样率芯片点击真实切换设备（44.1/48/88.2 实测）
- [x] 设备连接状态/灯/麦克风/7.1 状态轮询显示

设备当前已连接（用户真机使用中）。左键绑定已被用户改成 ⌘⇧F，右键 ⌘G。

待办 / 可改进：
- [ ] **重启 App 用新构建验证**（按键拦截修复已编译进 dist，但当前运行的还是旧进程；重启后让用户在菜单栏面板点「按键拦截」→ 授权 → 按设备键验证左/右键不再调音量）
- [ ] **去掉提权对话框**（重大发现：见下「按键拦截排障」第 2 条，macOS 15 非 root 也能 seize，可直接普通权限启动 mage-helper，UX 大改善）
- [ ] 面板开合只有用户手点验证过图标点击（系统状态栏不接受外部模拟点击，无法自动化验证）
- [ ] `--menu-preview` 调试窗口保留中，可选删除
- [ ] 后续可能做 Web/更完整软件外壳；软件形态（SwiftUI AppKit 混合）对集成友好
- [ ] 灯色实测确认（设备灯色随采样率变化的具体规则，说明书未明确，需真机观察）

## 三点五、按键拦截排障记录（2026-11-13，重要）

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
- 用户说"你自己操作"时用 Kimi CUA（`cua.getApp('com.fiio.mage-controller')`）自行点击/拖动/截图验证；`screencapture` 可全屏截图（Retina 2x，AppKit 原点在左下）。
- CUA 细节：`listWindows` 只列主窗口；NSPanel 面板不列出，用 `--open-panel` + 全屏截图验证。坐标点击需 `window_id + screenshot_id`（图像 2x 像素，不做 Retina 换算）。CUA 合成 drag 会报告 `user_intervened`（用户真鼠标在动）。
- 不满意时用户会说"你自己看/重新检查"——先自查截图再回复。
- 方向键相关：用户重视十字键视觉比例（任天堂 1/3 臂宽），上下总长 = 左右总长。

## 六、验证清单（改动后照此自检）

1. `bash scripts/build-app.sh` 无 error（warning 可接受，现有的是 onChange deprecated）。
2. 启动 `--open-window`，CUA 截主窗口：布局/图标/灯位/绑定显示与改动前一致（除非改动点本身）。
3. 启动 `--open-panel` + `screencapture`，确认面板尺寸（日志 `菜单面板尺寸`）与渲染。
4. 涉及拖动：在顶部条和面板间隙各拖一次，确认窗口位移且按钮点击仍正常（点采样率芯片看状态栏数值变化最快）。
5. 涉及按键录入：`--record-mic` 或 UI 点胶囊录制，查 config.json。
