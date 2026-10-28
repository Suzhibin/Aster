//
//  MacStarrySkyView.swift
//  AsterMac
//
//  通话窗的**深空背景**（2026-10-12）：`TimelineView` + `Canvas` 画的粒子星空。
//
//  ## 为什么不用 iOS 那套（`Aster/StarryKit/StarrySkyEngine.swift`）
//  iOS 那个是 `UIImageView` 子类（`layerClass = CAEmitterLayer`）。搬这个**类**到 Mac 有两道墙：
//  ① 🔴 **没有 UIKit 可混编** —— Mac target 是原生 macOS 14（非 Catalyst）。
//     那个类里的 `#if targetEnvironment(macCatalyst)` 在**原生** macOS 下恒为 false，
//     于是走 `#else` 撞上 `UIDevice.current`（原生 macOS 上不存在）⇒ **直接编译不过**。
//  ② 就算改写成 `NSViewRepresentable` 包一个 AppKit 视图，**本仓库的离屏渲染台照不到**
//     （已记录：`NSViewRepresentable` 离屏 = 黄条 + ⊘）⇒ 改完看不见、没法无人值守验收。
//  ⇒ 星空全部走 **SwiftUI 绘制**（上面两道墙一个都不碰）。
//
//  ## 🔴 但**底图**用回了 iOS 那张（2026-10-12，用户要求）
//  用户原话：「iOS 端的 `bj_Starry` 图片 也要在Mac端的打电话页面作为背景显示」。
//  ⇒ `bj_Starry.imageset` 已复制进 `AsterMac/Assets.xcassets/`。
//  ⚠️ 这是一份**物理副本**、不是共享：两端各持一份同名 imageset
//     （与 `AIVoiceCallPalette` / `MacVoiceCallTheme` 各写一份是同一个口径 —— 资源不外挂包）。
//  ⚠️ 渲染台那边是**裸可执行文件**（`swiftc -o /tmp/macrender_bin`）、没有 `Assets.car`，
//     所以靠「把 png 拷到可执行文件旁」让 `NSImage(named:)` 命中 ——
//     `Bundle.main.resourcePath` 对裸可执行文件就是**可执行文件所在目录**（已实测）。
//     见 `render_mac_ui.sh` 里那一行 `cp`。
//
//  ## 与 iOS 的视觉关系（**同一"关系"，参数各自标定**）
//  iOS：`emitterShape = .circle` + `emitterMode = .outline` + `preservesDepth`
//       ⇒ 观感 = **从中心圆周向外缓慢扩散的星点，带前后层次**。
//  本文件保留这个关系（中心向外 / 慢 / 稀疏 / 有闪烁），但数值全部走 `MacVoiceCallTheme`
//  的 `sky*` 系列 —— iOS 那套 `lifetime 50s` 是**为全屏手机调的**（位移 ≈ 1000pt），
//  直接搬到 320×420 的窗口等于"星星一秒就飞出画面"，什么都看不见。
//
//  ## 🔴 时间口径：**绝对时间取模**，不能用"打开窗口那一刻"当起点
//  `TimelineView` 每次重绘都会重新求值 `body`，拿不到一个稳定的 `t0`
//  （`@State` 里也存不了 —— 首帧赋值会立刻触发重绘循环）。所以取
//  `timeIntervalSinceReferenceDate % 3600`：
//  ① 任何一帧都能画出**完整**星空（相位由粒子各自的 `phase` 错开）
//     ⇒ 离屏渲染台哪怕只给一帧，也照得到东西；
//  ② 取模把数量级压到 0..3600 ⇒ `sin` 的精度充足
//     （直接喂 7.8e8 那种量级会让闪烁抖起来）；
//  ③ 每 3600 秒相位重置一次 —— 星空本来就在循环，看不出接缝。
//
//  ## 参数生成的确定性
//  🔴 粒子参数**全部由序号 `i` 唯一确定**（`noise(i, salt)`），时间只负责推进 `age`。
//  ⛔ 别改成 `Double.random(in:)`：那样每次重绘参数都重掷，星点会在原地狂闪
//  （看起来是噪点、不是星空），而且截图无法比对。
//

import AppKit
import SwiftUI

struct MacStarrySkyView: View {

    var body: some View {
        ZStack {
            deepSpace
            starField
        }
        // 铺满整个内容区。⚠️ 深空底是**不透明**色 ⇒ 它与窗口自己的 `backgroundColor`
        //    取的是**同一个常量**（`MacVoiceCallTheme.skyDeepestNSColor` ↔ `skyDeepest`）——
        //    标题栏那一条本来就该跟内容区同色，不同源就会显出一道横缝。
        .ignoresSafeArea()
    }

    // MARK: - 底：兜底深空 → 真实银河照 → 压暗 → 三团柔光

    /// 四层叠出来的「底」：
    /// ① 不透明深空（照片取不到时的兜底，同时与窗口 titlebar 同色 ⇒ 无缝）
    /// ② 真实银河照（iOS 同款 `bj_Starry`）
    /// ③ 压暗（照片中部偏亮，而本页前景是白字白点 —— 见 `skyPhotoDim` 注释）
    /// ④ 三团柔光（`RadialGradient` + `.clear` 收边，给中心一个"光源"感）
    private var deepSpace: some View {
        ZStack {
            MacVoiceCallTheme.skyDeepest

            skyPhoto

            MacVoiceCallTheme.skyDeepest.opacity(MacVoiceCallTheme.skyPhotoDim)

            RadialGradient(colors: [MacVoiceCallTheme.skyGlow, .clear],
                           center: UnitPoint(x: 0.50, y: 0.36),
                           startRadius: 0,
                           endRadius: 250)

            RadialGradient(colors: [MacVoiceCallTheme.skyNebulaWarm, .clear],
                           center: UnitPoint(x: 0.20, y: 0.82),
                           startRadius: 0,
                           endRadius: 200)

            RadialGradient(colors: [MacVoiceCallTheme.skyNebulaCool, .clear],
                           center: UnitPoint(x: 0.86, y: 0.16),
                           startRadius: 0,
                           endRadius: 180)
        }
    }

    /// 真实银河底图（iOS 同款 `bj_Starry`）。
    ///
    /// 🔴 **取图只有一条路**：`NSImage(named:)` —— 两处运行环境都靠它命中，
    ///    只是命中的「bundle 资源目录」不同（见文件头）：
    ///      ① 正常 App：Xcode 把 `bj_Starry.imageset` 编进 `Assets.car`；
    ///      ② 渲染台：裸可执行文件没有 `Assets.car`，`Bundle.main.resourcePath`
    ///         **就是可执行文件所在目录** ⇒ 脚本把 png 拷到那儿即可。
    /// ⚠️ 取不到时**不崩、只是少一层**（`if let` 不成立就什么都不画）——
    ///    与 iOS `StarrySkyEngine` 那句「缺图 = 少一层装饰，不崩」同一口径。
    ///    底下的 ① 深空色会兜住，画面仍然是完整的一片深空。
    /// ⚠️ 用 `static let` 只查一次：`body` 里有 `TimelineView`，**每帧都会重求值**，
    ///    没必要每帧查一遍（`NSImage(named:)` 自带缓存，但这更省也更直白）。
    private static let skyPhotoImage = NSImage(named: "bj_Starry")

    @ViewBuilder
    private var skyPhoto: some View {
        if let image = Self.skyPhotoImage {
            // 🔴 必须用 `GeometryReader` 把尺寸**锁死**：`scaledToFill` 的 `Image`
            //    在**不受约束**时会以自身像素尺寸（1076×1046）参与布局，
            //    把外面这个 `ZStack` 撑到 1076pt 宽 —— 那是"窗口内容区突然变得巨大"。
            //    `GeometryReader` 拿到的是**容器提议的尺寸**（= 320×420），切断这条传播。
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    // ⚠️ `scaledToFill`（不是 `fit`）：照片近方形、窗口竖长
                    //    ⇒ 按比例放大到**盖满**，左右多出来的裁掉。
                    //    与 iOS 那边 `UIImageView` 默认的 `scaleToFill`（填满、允许裁）观感一致。
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
    }

    // MARK: - 面：粒子

    /// ⚠️ `TimelineView(.animation)` = 跟着显示器刷新走（60 / 120Hz）。
    ///    窗口不显示时 SwiftUI 自己就不驱动了，不需要手动加"失焦暂停"。
    private var starField: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                drawParticles(in: context, size: size, time: Self.clock(timeline.date))
            }
        }
    }

    // MARK: - 绘制

    private func drawParticles(in context: GraphicsContext,
                               size: CGSize,
                               time: Double) {
        guard size.width > 0, size.height > 0 else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        /// 画面中心到**对角**的距离 —— 粒子飘过它就彻底看不见了
        let reach = sqrt(size.width * size.width + size.height * size.height) / 2

        for i in 0..<MacVoiceCallTheme.skyParticleCount {
            // ── 参数（由序号唯一确定，见文件头「参数生成的确定性」）──────────────
            let life = MacVoiceCallTheme.skyLifetimeMin
                     + Self.noise(i, 1) * (MacVoiceCallTheme.skyLifetimeMax - MacVoiceCallTheme.skyLifetimeMin)
            let phase = Self.noise(i, 2) * life
            let age = (time + phase).truncatingRemainder(dividingBy: life)
            let progress = age / life

            let angle = Self.noise(i, 3) * 2 * Double.pi
            let speed = MacVoiceCallTheme.skySpeedMin
                      + Self.noise(i, 4) * (MacVoiceCallTheme.skySpeedMax - MacVoiceCallTheme.skySpeedMin)
            let radius = Self.noise(i, 5) * MacVoiceCallTheme.skyBirthRadius + speed * age

            // 飘出画幅就不画了（留一点余量，免得贴边时"啪"地消失）
            guard radius < reach * 1.08 else { continue }

            let x = center.x + cos(angle) * radius
            let y = center.y + sin(angle) * radius

            // 生命曲线的淡入 / 淡出
            let fade = sin(progress * Double.pi)
            // 每个粒子自己的闪烁频率
            let twinkle = 0.62 + 0.38 * sin(time * (1.6 + Self.noise(i, 6) * 2.6) + phase * 3.1)
            // 越靠外越淡 ⇒ 前后层次（对应 iOS 的 `preservesDepth`）
            let depth = 1 - min(1, radius / reach) * 0.55

            let alpha = MacVoiceCallTheme.skyStarAlpha * fade * twinkle * depth
            guard alpha > 0.015 else { continue }

            let diameter = MacVoiceCallTheme.skyStarSizeMin
                         + Self.noise(i, 7) * (MacVoiceCallTheme.skyStarSizeMax - MacVoiceCallTheme.skyStarSizeMin)

            context.fill(
                Path(ellipseIn: CGRect(x: x - diameter / 2,
                                       y: y - diameter / 2,
                                       width: diameter,
                                       height: diameter)),
                with: .color(Color(white: 1).opacity(alpha))
            )
        }
    }

    // MARK: - 工具

    /// 时间口径（见文件头）：绝对时间**取模**到一小时，既有完整相位、精度又够。
    private static func clock(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
    }

    /// 确定性伪随机（splitmix64 的尾部混合），返回 `0..<1`。
    ///
    /// 🔴 这是「序号 → 参数」的唯一入口：同样的 `(index, salt)` 永远给同一个值，
    ///    所以**同一时刻的星图可复现**（截图能比对、改动能看出差异）。
    private static func noise(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(truncatingIfNeeded: salt) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= (x >> 31)
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }
}
