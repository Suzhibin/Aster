//
//  MacVoiceCallBallView.swift
//  AsterMac
//
//  通话窗中央那颗**白色圆球**（2026-10-27；用户原话：
//  「mac端 也要增加白球，当 AI 回复的时候 随着 AI 声音 白球关联呼吸动画」）。
//
//  ## 与 iOS 那支是同一件东西的第二份实现
//  iOS：`Aster/Voice/AIVoiceCallBallView.swift` —— UIKit + `CADisplayLink` 逐帧改 `transform`。
//  Mac：SwiftUI ⇒ `TimelineView(.animation(minimumInterval:))` 每帧给一个 `date`，
//       按它算缩放与柔光。这与 `MacVoiceCallDotsView` 是**同一条路子**，
//       ⛔ 别改成 `Timer` 驱动 `@State`、也别用 `withAnimation` 无限循环：
//       前者每帧改状态会整棵子树重算，后者在窗口被遮挡 / 切 Space 时相位会乱。
//
//  ## 🔴 「随 AI 声音」在这个仓库里的真相（两端一样，只看这一处就够）
//  **拿不到真实振幅。** `AISpeechReader` 对外只有 `isSpeaking` / `didStart` / `didFinish`；
//  `AVSpeechSynthesizer` **不提供输出电平**，`AVAudioSession` 也没有播放侧 metering。
//  唯一能拿到真振幅的路是把 TTS 输出改成 `write(_:toBufferCallback:)` + `AVAudioPlayerNode`
//  手动渲染 —— 那等于把整条朗读链路推倒重写。
//  ⇒ 这里用的是**合成包络**（三路互不通约的正弦叠出"音节感"，再乘一个 ~4.5s 的慢包络）。
//     观感上是"跟着 AI 的声音在喘"，但**它是画出来的节奏，不是量出来的振幅**。
//  ⛔ 别在 UI 文案 / 注释里把它说成"实时音量"。
//  ℹ️ 将来若真接上电平，只需把 `Self.envelope(_:)` 换掉 —— 出口只有那一处。
//
//  ## ⛔ 白球**不吃**用户麦克风的电平
//  用户音量归三点（"我在听你说"，`.listening`），白球归 AI（"AI 在说"，`.speaking`）。
//  合并以后两件事长得一样，用户分不出现在轮到谁 —— 与 iOS 那条铁律同源。
//  ⇒ 本视图**只认 `isVoiceActive`**，不接受 `level`。
//
//  ## 位置由父视图给，本视图只管自己多大、怎么动
//  它不参与 `content` 的 `VStack` 布局。2026-10-27 第二版（用户：「白球位置要居中」）起，
//  它由 `MacVoiceCallView.content` 摆在**舞台正中**（盒子中心 = 舞台中心），
//  三点与两行字另起一层从球下沿往下排 —— 两层的距离靠同一批主题常量对齐。
//  ⛔ 别把它塞回 VStack：插进去会让下面那簇重新均分、整页重心再漂一次。

import SwiftUI

struct MacVoiceCallBallView: View {

    /// AI 是否正在朗读。唯一来源是 `MacVoiceCallModel.isVoiceActive`（即 `.speaking`）。
    let isVoiceActive: Bool

    /// 🧪 验收钩子钉住的振幅（0~1）。`nil` = 用合成包络。
    ///
    /// 存在的理由与 iOS 那条一字不差：合成包络是**连续**的，截图抓的是某一帧 ——
    /// 「球在说话时确实变大」从单张图上分不出来（可能刚好抓到波谷）。
    /// 有这个口子就能把球钉在 `0` / `1` 各截一张，量外接圆直径逐点比。
    /// ⚠️ 生产路径上恒为 nil（唯一赋值点是模型的 `STARRY_CALL_BALL` 钩子）。
    var forcedLevel: Double?

    /// 档位切到"在说"的时刻（用来做 ≈0.4s 的开口过渡）
    @State private var activeSince: Date?
    /// 档位切回"静息"的时刻（收口过渡）
    @State private var idleSince: Date?

    // MARK: - 几何（全部来自主题，⛔ 别在这里写数字）

    private static var diameter: CGFloat { MacVoiceCallTheme.ballDiameter }
    private static var glowInset: CGFloat { MacVoiceCallTheme.ballGlowInset }
    /// 视图盒子边长 = 球直径 + 两侧柔光。
    /// ⚠️ 单一的出处是主题（`ballBoxSide`）—— 父视图排版时也要用这个数（它按盒子中心对齐），
    ///    这里只转发一次，⛔ 别在两边各写一遍 `diameter + glowInset * 2`。
    private static var boxSide: CGFloat { MacVoiceCallTheme.ballBoxSide }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            // ⚠️ 用**绝对时间**当相位基准（与三点同一个口径）：每次开窗所处的形态是随机的，
            //    但通话是长时间驻留的状态，没人会去对比两次开窗的第一帧。
            let t = timeline.date.timeIntervalSinceReferenceDate

            // ① 静息呼吸：正弦 ±5%。`wave` 同时用来算柔光明暗（只取一次 sin，两处口径不会各自漂）
            // ☠️ 验收钩子钉住振幅时，**呼吸相位也一起钉成 0**（`wave = 0`）。
            //    否则两次截图的呼吸相位不同，量出来的差里混着 ±5% 的噪声 ——
            //    2026-10-27 真踩：振幅 0/1 各截一张，量到 105 / 114（差 9pt），
            //    而 16pt 的说话幅度被相位差吃掉了大半，看起来像"钩子没生效"。
            let wave = forcedLevel == nil
                ? sin(t / MacVoiceCallTheme.ballBreathPeriod * 2 * .pi)        // -1 ~ 1
                : 0
            // ② AI 说话：档位先按 0.4s 爬到 1，再乘一个 0~1 的振幅
            let voice = voiceAmount(at: timeline.date) * (forcedLevel ?? Self.envelope(t))

            let scale = 1
                + MacVoiceCallTheme.ballBreathAmplitude * wave
                + MacVoiceCallTheme.ballVoiceAmplitude * voice

            ZStack {
                // 柔光比球体更"会呼吸"：同时跟静息相位与说话振幅走 ⇒
                // 静息档下球外那圈光也在缓慢明灭，这才是"呼吸"的主要观感来源。
                glow.opacity((0.50 + 0.30 * ((wave + 1) / 2)) * (0.75 + 0.25 * voice))
                core
            }
            .scaleEffect(scale)
        }
        .frame(width: Self.boxSide, height: Self.boxSide)
        // 纯展示：它压在"点窗宽处打断朗读"那块区域上，一旦可交互就会把点击吃掉
        .allowsHitTesting(false)
        .onAppear {
            // 开窗那一刻就已经在朗读（比如验收钩子直接钉住）⇒ 过渡**直接给满**：
            // 球从来没有以"静息"出现过，没有"从 0 涨上来"这件事可言。
            // ⚠️ 别写成 `activeSince = Date()`：那会让它白白爬 0.4s，
            //    钩子截图正好卡在这段时间里 ⇒ 量到的振幅永远差一截（2026-10-27 真踩，
            //    114pt vs 应有的 121pt）。回拨一个 ramp 时长即可。
            if isVoiceActive { activeSince = Date().addingTimeInterval(-MacVoiceCallTheme.ballVoiceRamp) }
        }
        .onChange(of: isVoiceActive) { _, active in
            if active {
                activeSince = Date()
                idleSince = nil
            } else {
                idleSince = Date()
                activeSince = nil
            }
        }
    }

    // MARK: - 档位过渡

    /// 0（静息）→ 1（在说）之间的平滑量。
    ///
    /// 🔴 为什么要它：直接拿 `isVoiceActive ? 1 : 0` 去乘幅度，开口 / 收口都是**一帧跳过去**
    ///    （球会"啪"地涨一下）。iOS 那边是逐帧 `mix += (target - mix) * 0.08`（≈0.4s 收敛）；
    ///    SwiftUI 没有"每帧存中间值"的写法，改成**按时间线性爬**（两端都用同一个 ramp 时长）。
    private func voiceAmount(at date: Date) -> Double {
        let ramp = MacVoiceCallTheme.ballVoiceRamp
        if isVoiceActive {
            guard let start = activeSince else { return 0 }
            return min(1, max(0, date.timeIntervalSince(start) / ramp))
        }
        guard let stop = idleSince else { return 0 }
        return max(0, 1 - date.timeIntervalSince(stop) / ramp)
    }

    /// 合成振幅（0~1）：三路**互不通约**的正弦叠出音节感，再乘一个 ~4.5s 的慢包络。
    ///
    /// ☠️ 三条频率之间不能有整数倍关系（4.3 / 6.7 / 2.9）：一旦通约，三路会周期性地
    ///    **同时归零** ⇒ 球会在说话中途"死"一下（三点那边踩过一模一样的坑，
    ///    见 `MacVoiceCallDotsView` 文件头那张实测表）。
    /// 🔴 与 iOS `AIVoiceCallBallView.voicePulse` **逐字同参** —— 两端是同一件事，别只改一边。
    private static func envelope(_ t: Double) -> Double {
        let raw = sin(t * 2 * .pi * 4.3)
                + 0.70 * sin(t * 2 * .pi * 6.7 + 1.1)
                + 0.45 * sin(t * 2 * .pi * 2.9 + 2.4)
        let shaped = (raw / 2.15 + 1) / 2                    // 0~1
        let phrase = (sin(t / 4.5 * 2 * .pi) + 1) / 2        // 0~1，一句一句的起伏
        // 平方压窄波峰（同三点的曲线口径）：波峰窄、波谷平 ⇒ 读起来像"音节"而不是"抖动"
        let value = shaped * shaped * (0.40 + 0.60 * phrase) * 1.9
        return min(max(value, 0), 1)
    }

    // MARK: - 画

    /// 球外柔光：中心白 → 边缘**必须到 0**。
    /// ⚠️ 不到 0 会在球外糊出一圈能看见的硬边（比没有光还难看）。
    private var glow: some View {
        Circle()
            .fill(RadialGradient(
                colors: [MacVoiceCallTheme.ballGlow.opacity(0.34),
                         MacVoiceCallTheme.ballGlow.opacity(0.10),
                         MacVoiceCallTheme.ballGlow.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: Self.boxSide / 2))
            .frame(width: Self.boxSide, height: Self.boxSide)
    }

    /// 球体：**冷灰底 + 偏左上的一团白高光**。
    ///
    /// ⚠️ 为什么不画成一块死白圆：纯白实心压在深空上会像一张贴纸（没有体积、也没有边缘过渡）。
    /// ⛔ 别把高光挪到正中：正中的径向高光会变成"发光圆片"，同样没有体积。
    /// 🎨 底 / 高光的比例与位置与 iOS `renderCore(side:)` 同参（0.38 / 0.34 / 0.78）。
    private var core: some View {
        Circle()
            .fill(MacVoiceCallTheme.ballShade)
            .overlay {
                Circle().fill(RadialGradient(
                    colors: [MacVoiceCallTheme.ballCore,
                             MacVoiceCallTheme.ballCore.opacity(0.85),
                             MacVoiceCallTheme.ballCore.opacity(0)],
                    center: UnitPoint(x: 0.38, y: 0.34),
                    startRadius: 0,
                    endRadius: Self.diameter * 0.78))
            }
            .frame(width: Self.diameter, height: Self.diameter)
    }
}
