# 协议速查（MAGE 厂商通道）

设备：SNOWSKY MAGE。厂商通道 = HID 接口 **0x4022**（另一个同名 0x0144 无响应）。
帧格式：64 字节输出报告，命令 ID + payload，详见 `MageController/Sources/MageKit/MageProtocol.swift`。

## 命令表

| cmd | 名称 | 读写 | 说明 |
|-----|------|------|------|
| 6 | ledLight | RW | 指示灯总开关（0/1） |
| 18 | micSwitch | RW | 麦克风开/关（0/1）。mic 键由固件经此通道推送 |
| 21 | peqParams | W | PEQ 参数（10 段，面板 -24..+12dB） |
| 22 | peqPre | RW | EQ 预设：240=BYPASS(HiFi)，257-260=游戏(FPS/ACT/MOBA/MUG)；≥256 即判定游戏模式 |
| 26 | peqSwitch | W | EQ 开关 |
| 33 | resetFactory | W | 恢复出厂（四灯齐红闪 1 秒→重启，破坏性） |
| 34 | micVol | RW | 麦克风音量（实测 89） |
| 51 | ledCtrl | ? | 无响应（灯不可控，灯态=固件管） |
| 52 | micNrLevel | ? | 无响应 |
| 53 | gain3d | RW | 3D 增益（实测 10，面板 0-10） |
| 54 | reverbLevel | RW | 混响（实测 0，面板 0-100） |
| 55 | channel71Config | R | 7.1 声道角度，16 字节小端（默认 315/45/0/0/270/90/225/135） |
| 56 | channel71Switch | RW | 7.1 虚拟环绕开关 |
| 58 | channel71Gain | ? | 7.1 增益 |
| 11 | firmwareVersion | ? | 无响应 |
| 122 | rebootDevice | W | 设备硬重启（模式切换失联兜底；设备可能不支持，需真机验证） |
| 1/2/4/7/8 | 音量/滤波/平衡 | — | 协议笔记待补 |

## 按键（consumer usage page 0x0C）

| usage | 键 | 系统 NX 码 |
|-------|----|-----------|
| 0xE9 | 音量+（右键） | 0 SOUND_UP |
| 0xEA | 音量-（左键） | 1 SOUND_DOWN |
| 0xCD | 播放/暂停（Menu/上/下） | 16 PLAY |

mic 键不走 consumer 页，走厂商 cmd18 推送。

## 指示灯（官方说明书 docs/reference/MAGE_manual.pdf 第 3 页）

- 音乐/游戏灯：PCM≤48k **浅蓝**、>48k **黄**、DSD **绿**；关=灭
- 7.1 灯：**浅蓝**，8 声道=闪烁、2 声道=常亮；关=灭
- mic 灯：开=**浅蓝**、关=灭；红色仅恢复出厂序列出现
- 灯完全由固件控制，主机写入无法改变（官方面板同样如此）

## 固件行为备忘

- 模式切换/7.1 切换会重启 USB 音频接口，切出 7.1 有 1-2s 延迟属正常
- AI 降噪：3.5mm 麦克风输入在**非 7.1 模式**下支持（无主机开关，面板"麦克风滑块"=micVol 音量）
- M 键：短按=播放/暂停，双击=7.1，长按 2 秒=模式切换；M+mic 同按 1 秒=恢复出厂
