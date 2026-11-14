import SwiftUI

// MARK: - 设备线稿（严格按设计稿 550×300 坐标系，55×30mm 实机比例）

struct DeviceLineArt: View {
    var musicOn: Bool
    var gameOn: Bool
    var s71On: Bool
    var micOn: Bool
    var rate: Double

    var body: some View {
        // 7.1 灯官方定义为「8 声道闪烁 / 2 声道常亮」，开启时用 TimelineView 驱动闪烁
        TimelineView(.periodic(from: .now, by: s71On ? 0.5 : 3600)) { timeline in
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
            // 官方说明书：音乐/游戏灯 PCM≤48kHz 浅蓝、>48kHz 黄、DSD 绿；
            // 7.1 灯 8 声道闪烁 / 2 声道常亮；mic 灯开=浅蓝、关=灭
            let modeTint = rate <= 48050 ? Color(hex: 0x4FC3F7) : Color.yellow
            let s71Lit = s71On && (Int(timeline.date.timeIntervalSince1970 * 2) % 2 == 0)
            led(ctx, center: CGPoint(x: 213.1, y: 238.1), d: 21.4, on: musicOn, tint: modeTint)
            led(ctx, center: CGPoint(x: 251.2, y: 238.1), d: 16.7, on: gameOn, tint: modeTint)
            led(ctx, center: CGPoint(x: 289.3, y: 238.1), d: 16.7, on: s71Lit, tint: Color(hex: 0x4FC3F7))
            led(ctx, center: CGPoint(x: 327.4, y: 238.1), d: 21.4, on: micOn, tint: Color(hex: 0x4FC3F7))
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
        } // TimelineView
    }

    private func led(_ ctx: GraphicsContext, center: CGPoint, d: CGFloat, on: Bool,
                     tint: Color) {
        // 灯色取自官方说明书（浅蓝/黄/绿），点亮用同色光晕
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
