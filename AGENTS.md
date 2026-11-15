# AGENTS.md（索引）

本文件是智能体/开发者入口。完整开发日志（协议逆向全过程、每次改动的原因与结论）
在 [docs/dev-log.md](docs/dev-log.md)，**改代码前必读其末尾几节**（最近状态）。

## 快速事实（不读日志时的最小上下文）

- 项目：MAGE 声卡 macOS 控制软件。构建：`cd MageController && bash scripts/build-app.sh`
  （新机器先跑一次 `scripts/setup-signing.sh`）。
- 产物 `MageController/dist/MAGE Controller.app`；重启：pgrep -f 精确路径 kill 后 `open`。
- 日志 `~/.mage-controller.log`（UTC=本地-8h）；配置 `~/.config/mage-controller/config.json`。
- 设备有两个同名 HID 接口：`0x4022`=厂商通道（可用），`0x0144`=无响应。
- 厂商协议 64 字节帧，命令速查见 [docs/protocol.md](docs/protocol.md)。
- 探针模板与坑（RunLoop/独立通道/通道竞争）见 docs/checklist.md 与 dev-log 末节。
- 回归清单：[docs/checklist.md](docs/checklist.md)；使用说明：[docs/usage.md](docs/usage.md)。
- 目录约定：`docs/`=文档，`design/`=设计资产（图标/界面稿/产品图），
  `v2-poc/`=免拦截架构概念验证（已并入主应用，无需构建）。
