//
//  AIVoiceCallBallView.swift
//  Aster
//
//  通话页中央那颗**白色圆球**（2026-10-26；用户需求原话：
//  「在打电话页面 中间添加一个 100X100的白色圆球带呼吸动画功能，
//   当 AI 回复的时候 随着 AI 声音 关联呼吸动画」）。
//
//  ## 它跟被删掉那颗「流体球」不是同一件东西
//  2026-10-10 那版是一颗**铺满大半屏的多色流体球**（屏宽 × 0.59 ≈ 232pt），
//  按参考图 IMG_3166 逐块取色画的（见备份
//  `.workbuddy/backups/dead-voice-views-2026-10-26.tgz` 里的 `AIVoiceCallOrbView.swift`）。
//  用户现在要的是**一颗 100pt 的小白球** —— 语义从"这一页的视觉主体"变成了
//  "AI 正在说话的指示灯"。
//  ⇒ ⛔ 别把旧那颗整个搬回来：尺寸、位置、配色、动画口径**四项全不同**，
//     旧文件留着只为查"当年那颗长什么样"。
//
//  ## 🔴 「随 AI 声音」是怎么做到的（也是本文件最需要先看的一段）
//  **它拿不到真实的音频振幅。** `AISpeechReader` 对外只有三个信号：
//  `isSpeaking`、`didStart`、`didFinish`（见该文件）；`AVSpeechSynthesizer`
//  **不提供输出电平**，`AVAudioSession` 也没有播放侧 metering。
//  唯一能拿到真振幅的路是把 TTS 输出改成 `write(_:toBufferCallback:)` +
//  `AVAudioPlayerNode` 手动渲染 —— 那等于把整条朗读链路推倒重写，
//  而那条链路上每一个字都是踩出来的（见 `AISpeechReader` 文件头 1~6 条）。
//  ⇒ 这里用的是**合成包络**：三路互不通约的正弦叠出"音节感"、再乘一个 ~4.5s 的
//     慢包络（像一句一句的起伏）。观感上是"跟着 AI 的声音在喘"，
//     但**它是画出来的节奏，不是量出来的振幅**。⛔ 别在注释或 UI 上把它说成"实时音量"。
//     ⚠️ 将来若真要做真振幅（换掉 TTS 输出层），只需把 `setVoiceLevel(_:)` 接到
//        那路真电平上、把 `Self.voicePulse` 停用即可 —— 出口已经留好了。
//
//  ## 🔴 为什么用**一条** display link 同时算呼吸和说话，而不是 CAAnimation + UIView.animate
//  旧那颗流体球是两层分开挂（`self` 挂音量、`artView` 挂呼吸），因为它那两层是父子关系。
//  这里只有一个球，两个动画要改的是**同一个 `transform`** ——
//  ☠️ CAAnimation 与逐帧赋值抢同一个 keyPath 会互相顶掉（顶掉的那个**不报错**，
//     只是"忽然不呼吸了"或"忽然不随声音了"）。所以合成一路算：
//     `scale = 静息呼吸 + 说话幅度`，一个出口赋值。
//  代价是 display link 常驻（静息时也在跑）。这一页本来就常驻动画
//  （`StarrySkyEngine` 的 emitter + 拾音中三点的 display link），多一条不改变性质；
//  ⛔ 别为省这点 CPU 拆回"静息用 CA、说话用 link"双轨 —— 相位对不上，切换那一拍会跳一下。
//
//  ## ⛔ 白球**不吃**用户麦克风的电平
//  用户这次只要了"AI 回复时随 AI 声音"。拾音时这颗球保持**自己的静息呼吸**，
//  用户的音量仍由底部那三个点指示（`AIVoiceCallDotsView`）—— 两者分工不同：
//  三点 = "我在听你说"，白球 = "AI 在说"。⛔ 别顺手也喂给白球：
//  那样两个指示器会同时随用户声音跳，反而看不出"现在轮到谁"。
//

import UIKit

final class AIVoiceCallBallView: UIView {

    // MARK: - 几何 / 节奏

    /// 球体本体直径（唯一出处是 `AIVoiceCallMetrics.ballDiameter`）
    private static var diameter: CGFloat { AIVoiceCallMetrics.ballDiameter }

    /// 球外那圈柔光**向外扩出**多少 pt。
    /// ⚠️ 它画在 `bounds` **外面**（本视图 `clipsToBounds = false`）——
    ///    这样"球 = 100×100"这条口径不被柔光改变，柔光只是氛围。
    private static let glowInset: CGFloat = 22

    /// 静息呼吸一个来回的时长（秒）。3.4s 是"睡着了的呼吸"，再快就像在喘。
    private static let breathPeriod: Double = 3.4

    /// 静息呼吸的幅度（±5%）。⛔ 别加大：这一档要的是"它活着"，不是"它在动"。
    private static let breathAmplitude: CGFloat = 0.05

    /// AI 说话时在静息呼吸之上**再**叠多少（最多 +16%）。
    /// 与静息那 5% 相加 ⇒ 峰值 ≈ 1.21 倍，和三点那边的放大口径是同一量级。
    private static let voiceAmplitude: CGFloat = 0.16

    // MARK: - 子视图

    /// 球外柔光（画在 bounds 外，见 `glowInset`）
    private let glowView = UIImageView()
    /// 球本体
    private let coreView = UIImageView()

    // MARK: - 状态

    private var displayLink: CADisplayLink?
    /// 动画时间原点（进窗口那一刻）
    private var clock: CFTimeInterval = 0

    /// 目标档位：1 = AI 正在说话，0 = 静息
    private var voiceTarget: CGFloat = 0
    /// 平滑后的档位 —— 让"开口 / 收口"是一段过渡，而不是一帧跳过去
    private var voiceMix: CGFloat = 0

    /// 🧪 验收用：外部直接灌一个 0~1 的振幅（默认 nil = 用合成包络）。
    ///
    /// 存在的理由：合成包络是**连续**的，截图抓的是某一帧 ——
    /// 「球在说话时确实变大」这件事从单张图上分不出来（可能刚好抓到波谷）。
    /// 有这个口子就能把球**钉在最大 / 最小**两档各截一张，逐像素比外接圆直径。
    /// ⚠️ 生产路径上恒为 nil（唯一赋值点是 DEBUG 的验收钩子）。
    var levelOverride: CGFloat?

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // ☠️ 必须允许画出边界：柔光是往外扩的（见 `glowInset`）
        clipsToBounds = false
        // 白球只做展示：它压在"点页面空白处打断朗读"那块手势区上，
        // 一旦可交互就会把点击吃掉（表现是"中间那块点不动"）
        isUserInteractionEnabled = false

        setUpImages()
        layoutImages()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // ☠️ display link 会**强引用** target ⇒ 不失效它就是一个不随本视图释放的定时器。
        //    （`deinit` 是 nonisolated，但 `invalidate()` 本身不是隔离方法，就地调合法。）
        displayLink?.invalidate()
    }

    // MARK: - 装配

    private func setUpImages() {
        for image in [glowView, coreView] {
            image.isUserInteractionEnabled = false
            image.contentMode = .scaleAspectFit
            addSubview(image)
        }
        let side = Self.diameter
        coreView.image = Self.renderCore(side: side)
        glowView.image = Self.renderGlow(side: side + Self.glowInset * 2)
        glowView.alpha = 0.55
    }

    /// 两层都按**固定像素坐标**摆，不走约束：
    /// 本视图的 frame 由外部约束钉成 100×100，内部这两层只跟这个尺寸走，不需要再参与求解。
    private func layoutImages() {
        let side = Self.diameter
        let glowSide = side + Self.glowInset * 2
        coreView.frame = CGRect(x: 0, y: 0, width: side, height: side)
        glowView.frame = CGRect(x: -Self.glowInset, y: -Self.glowInset,
                                width: glowSide, height: glowSide)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 尺寸是常量，这里只是兜底：万一将来改成跟随屏宽，这一行保证两层不脱节
        if coreView.frame.size.width != Self.diameter {
            layoutImages()
        }
    }

    // MARK: - 对外

    /// AI 是否正在朗读（唯一调用方：控制器的 `apply(state:)`，只在 `.speaking` 时为 true）
    ///
    /// ⚠️ 只**记目标档**，真正的形变在 display link 里（与三点同一个分层）。
    /// ℹ️ 这里**不清** `levelOverride`：静息档下 `voiceMix` 会自己衰减到 0，
    ///    覆写值即便留着也乘不出幅度；清了反而会让"先灌振幅、再切状态"的验收顺序变脆。
    func setVoiceActive(_ active: Bool) {
        voiceTarget = active ? 1 : 0
    }

    /// 🧪 直接指定振幅（0~1）。传 `nil` 回到合成包络。**只有验收钩子会调它。**
    func setVoiceLevel(_ level: CGFloat?) {
        levelOverride = level.map { min(max($0, 0), 1) }
    }

    // MARK: - 逐帧

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        clock = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // ⚠️ `.common`：默认 mode 在滚动 / 手势跟踪时会被挂起（与 `startVAD` / 三点同一条规矩）
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// ☠️ App 切后台再回来，CA 会把无限循环的动画摘掉（渲染服务器在挂起时清动画）⇒
    ///    这里用 display link 不受那条影响，但仍按 `window` 开关：不在窗口上就不该跑。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    @objc private func tick() {
        let t = CACurrentMediaTime() - clock

        // ① 静息呼吸：正弦，±5%。`wave` 同时用来算柔光的明暗（只取一次 sin，两处口径不会各自漂）
        let wave = sin(t / Self.breathPeriod * 2 * Double.pi)          // -1 ~ 1
        let breath = 1 + Self.breathAmplitude * CGFloat(wave)
        let glowPhase = CGFloat((wave + 1) / 2)                        // 0 ~ 1

        // ② AI 说话：档位先平滑（≈0.4s 过渡），再乘一个 0~1 的振幅
        voiceMix += (voiceTarget - voiceMix) * 0.08
        let voice = voiceMix * (levelOverride ?? Self.voicePulse(t))

        let scale = breath + Self.voiceAmplitude * voice
        transform = CGAffineTransform(scaleX: scale, y: scale)
        // 柔光比球体更"会呼吸"：它同时跟着静息相位与说话振幅走，
        // 这样即使在静息档，球外那圈光也在缓慢明灭 —— 这才是"呼吸"的主要观感来源。
        glowView.alpha = (0.50 + 0.30 * glowPhase) * (0.75 + 0.25 * voice)
    }

    /// 合成振幅（0~1）：三路**互不通约**的正弦叠出音节感，再乘一个 ~4.5s 的慢包络。
    ///
    /// ☠️ 三条频率之间不能有整数倍关系（4.3 / 6.7 / 2.9 互为质数化的比例）：
    ///    一旦通约，三路会周期性地**同时归零** ⇒ 球会在说话中途"死"一下
    ///    （三点那边踩过一模一样的坑，见 `AIVoiceCallDotsView` 文件头那张实测表）。
    private static func voicePulse(_ t: Double) -> CGFloat {
        let raw = sin(t * 2 * .pi * 4.3)
                + 0.70 * sin(t * 2 * .pi * 6.7 + 1.1)
                + 0.45 * sin(t * 2 * .pi * 2.9 + 2.4)
        let shaped = (raw / 2.15 + 1) / 2                    // 0~1
        let phrase = (sin(t / 4.5 * 2 * .pi) + 1) / 2        // 0~1，一句一句的起伏
        // 平方压窄波峰（同三点的曲线口径）：波峰窄、波谷平 ⇒ 读起来像"音节"而不是"抖动"
        let value = shaped * shaped * (0.40 + 0.60 * phrase) * 1.9
        return CGFloat(min(max(value, 0), 1))
    }

    // MARK: - 渲染

    /// 球本体：**底色 + 偏左上的高光**。
    ///
    /// ⚠️ 为什么不画成一块死白圆：纯白实心压在深空上会像一张贴纸（没有体积、也没有边缘过渡）。
    ///    压一层极淡的冷灰打底、再从左上打一团白高光，出来才是颗"球"。
    ///    ⛔ 别把高光挪到正中：正中的径向高光会变成"发光圆片"，同样没有体积。
    private static func renderCore(side: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            let cg = context.cgContext
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            cg.addEllipse(in: rect)
            cg.clip()

            cg.setFillColor(AIVoiceCallPalette.ballShade.cgColor)
            cg.fill(rect)

            let highlight = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [AIVoiceCallPalette.ballCore.cgColor,
                         AIVoiceCallPalette.ballCore.withAlphaComponent(0.85).cgColor,
                         AIVoiceCallPalette.ballCore.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 0.55, 1])
            if let highlight {
                let center = CGPoint(x: side * 0.38, y: side * 0.34)
                cg.drawRadialGradient(highlight,
                                      startCenter: center, startRadius: 0,
                                      endCenter: center, endRadius: side * 0.78,
                                      options: [])
            }
        }
    }

    /// 球外柔光：一个从中心白到透明的径向渐变，**边缘必须到 0** ——
    /// 不到 0 会在球外糊出一圈能看见的硬边（比没有光还难看）。
    private static func renderGlow(side: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            let cg = context.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let glow = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [AIVoiceCallPalette.ballGlow.withAlphaComponent(0.34).cgColor,
                         AIVoiceCallPalette.ballGlow.withAlphaComponent(0.10).cgColor,
                         AIVoiceCallPalette.ballGlow.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 0.62, 1])
            if let glow {
                cg.drawRadialGradient(glow,
                                      startCenter: center, startRadius: 0,
                                      endCenter: center, endRadius: side / 2,
                                      options: [])
            }
        }
    }
}
