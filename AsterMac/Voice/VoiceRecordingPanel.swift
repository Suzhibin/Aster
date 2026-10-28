//
//  VoiceRecordingPanel.swift
//  AsterMac
//
//  录音浮层（2026-10-03 改版）：**铺满整宽、贴在窗口最底部**的一块蓝色光晕 + 白色刻度波形。
//
//  ## 为什么从「输入栏上方的小卡片」改成「贴窗口底」
//  用户拿豆包语音输入的截图对标，原话是「按照豆包的**屏幕最底部**语音输入动画，样式/动画/颜色都改」。
//  豆包那套是：一道深蓝光晕从屏幕底边长上来（顶部是弧形边界）、一句提示、下方一排白色刻度波形。
//  **没有卡片边框、没有红点、没有「正在聆听」标题。**
//  ⇒ 旧版那套（深色玻璃卡片 + 红点 + 标题 + 圆角描边，长在输入栏那一列里）整个换掉。
//  ⚠️ 它因此从 `MacInputBar` 的 VStack **搬到了 `ChatDetailView` 的 `.overlay(alignment: .bottom)`**
//     —— 只有挂在详情页那一层，才会真的盖住输入栏（豆包那块也是盖住输入区的）。
//
//  ## 🔴 为什么它不吃触摸（除了波形两侧那两颗圆钮）
//  浮层现在盖住了输入栏 ⇒ 它若参与命中测试，「点 🎤 结束并发送」就点不着了。
//  ⇒ 展示层（光晕 + 文案）整体 `.allowsHitTesting(false)`，让点击**穿透到下面的输入栏**；
//    波形本体自带 `.allowsHitTesting(false)`，所以它跟按钮同处一行也只让**按钮**吃触摸。
//  ⚠️ 容器**不能**给 `background` / `contentShape`：SwiftUI 里没有绘制的区域本来就不参与命中测试，
//     一旦给了底色，整块 310pt 就会挡住输入栏（这是上面那条能成立的前提，⛔ 别顺手加）。
//
//  ## ✗ / ✓ 两颗圆钮（2026-10-03 加，用户要求）
//  用户原话：「在**音浪的左侧**放置结束按钮、图标是 X；在**音浪的右侧**放发送按钮、图标是对号」。
//  ⇒ 波形那一行做成 `[✗] ── 带子 ── [✓]`：
//    · 左 ✗ = **结束并放弃**（`onCancel`，与原「取消」同一个动作），Esc 也走它；
//    · 右 ✓ = **结束并发送**（`onSend` → `ChatModel.finishVoice()`，与点 🎤 同一条路）。
//  🔴 中间那块**就是波形本体**，宽度取 `MacTheme.voiceWaveformBandWidth(count:)` ⇒
//     「带子中心 = 整行中心 = 面板中轴」恒成立，两颗按钮永远对称贴在带子两端（⛔ 别改成
//     各自 `Spacer` 撑开 —— 那样带子宽度一变，两颗按钮就会离带子忽远忽近）。
//  ⚠️ 两颗按钮在 `isFinishing` 那一拍**一起收起**（与旧版「收掉取消」同一条约定）。
//
//  ## 竖直排布（⛔ 数字是按参考图像素实测换算的，与 iOS 逐字相同，改之前先看图）
//  以**浮层底边**为 0，向上为正（单位 pt，参考机 414×896）：
//
//  | 元素 | 中心距底边 | 说明 |
//  |---|---|---|
//  | 计时 | 38 | 豆包没有这项，放最下方深蓝区（不抢视线、白字可读） |
//  | 波形 | 74 | 实测带子中心 y=1643px ⇒ 距底 74.5pt |
//  | 提示语 | 122 | 实测文字中心 y=1532px ⇒ 距底 130pt，这里略压低给识别文字让位 |
//  | 识别文字 | 158 | 豆包没有这一行（它的识别结果显示在输入区），本 App 需要 |
//
//  位置一律「显式高度 + `.padding(.bottom, 中心距底 − 高度/2)`」钉死
//  ——⛔ 别用 `Spacer` 分配：那会被字体行高与容器高度一起带偏，改一个字号整排都漂。
//
//  ## 文案：两端**故意不同**
//  iOS 是「按住说话」⇒ 提示写「松手发送，上移取消」；Mac 是**点按式**
//  （波形两侧两颗圆钮 + 点 🎤 也能结束并发送，见 `ChatModel.toggleVoice`）⇒
//  「松手」「上移」在这里都没有对应动作，照抄会**误导**用户。
//  所以 Mac 保留自己的交互文案（点 ✗ 结束 / 点 ✓ 发送）。对标的是**样式 / 动画 / 颜色**，
//  不是把交互形态也改掉。
//
//  ## 🔴 为什么是「纯视图」：数据全部走参数
//  这个面板不读环境里的 `ChatModel`。这样做换来两件事：
//  ① 渲染台能在**任意状态**下把它渲出来（有波形、静止、正在整理文字…），而不需要在业务模型上
//     开一个「造态用」的口子；
//  ② 「面板长什么样」与「录音状态从哪来」彻底分开 —— 前者改样式不会碰到后者。
//  代价只是 `ChatDetailView` 里多写几个参数。
//

import SwiftUI
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

/// 录音浮层。调用方（`ChatDetailView`）负责把模型状态灌进来。
struct VoiceRecordingPanel: View {

    /// 音量滚动历史（队尾最新）。长度决定条数。
    let levels: [CGFloat]
    /// 实时识别文本（空 → 显示占位提示）
    let transcript: String
    /// 已录时长（秒）
    let elapsed: TimeInterval
    /// 已松开、正在等识别器吐最终文字（那一拍波形定住、提示换文案、两颗按钮都收起来）
    let isFinishing: Bool
    /// 左钮 ✗：**结束并放弃**这次录音（= 原有的取消；Esc 也走它）
    let onCancel: () -> Void
    /// 右钮 ✓：**结束并发送**（识别结果直接作为一条消息发出，与点 🎤 同一条路）
    let onSend: () -> Void

    /// 蓝光呼吸用
    @State private var breathing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── 展示层：一点触摸都不吃（点击要穿透到下面的输入栏）──────────────
            ZStack(alignment: .bottom) {
                VoiceGlowView()
                    // 呼吸：缩放 + 透明度一起（与 iOS 的 `CABasicAnimation` 同参）。
                    // ⚠️ anchor 用默认的 `.center`（与 iOS 一致）：光晕的圆心距底只有 23pt，
                    //    ±1.5% 的缩放带来的位移不到 0.4pt，看不出来；⛔ 别为此改成 `.bottom`，
                    //    那会让两端的动效不一致。
                    .scaleEffect(breathing ? MacTheme.voiceGlowBreathScaleHigh
                                           : MacTheme.voiceGlowBreathScaleLow)
                    .opacity(breathing ? 1 : MacTheme.voiceGlowBreathOpacityLow)

                timerLabel
                    .padding(.bottom, MacTheme.voiceTimerCenterAboveBottom
                                      - MacTheme.voiceTimerHeight / 2)
                hintLabel
                    .padding(.bottom, MacTheme.voiceHintCenterAboveBottom
                                      - MacTheme.voiceHintHeight / 2)
                transcriptLabel
                    .padding(.bottom, MacTheme.voiceTranscriptCenterAboveBottom
                                      - MacTheme.voiceTranscriptHeight / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // ── 波形那一行：**带子两侧各一颗按钮**（唯一可点的东西）───────────────
            // ⚠️ 波形放在这一行里（而不是展示层）：它自己就带 `.allowsHitTesting(false)`
            //    （见文件末尾 `VoiceWaveform`），所以放进来只让**两颗按钮**吃触摸，
            //    带子与两侧留白照旧穿透到下面的输入栏。
            waveformRow
                .padding(.bottom, MacTheme.voiceWaveformCenterAboveBottom
                                  - MacTheme.voiceWaveformHeight / 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MacTheme.voicePanelHeight)
        // ⚠️ 用 `.onAppear` 起动画：这个动画没有终点（`repeatForever`），挂在「值变化」上
        //    每次重建都会重新起一遍、且旧的不会停（与 `ComposerSpinner` 同一个坑）。
        .onAppear {
            withAnimation(.easeInOut(duration: MacTheme.voiceGlowBreathDuration)
                .repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    // MARK: - 波形行（带子 + 两侧按钮）

    /// `[✗] ── 波形带子 ── [✓]`，整行**居中**。
    ///
    /// 🔴 波形本体就放在这一行里（它自带 `.allowsHitTesting(false)`，见文件末尾 `VoiceWaveform`）——
    ///    于是「带子 + 两侧留白」照旧穿透到下面的输入栏，只有两颗按钮吃触摸。
    ///    中间那块必须**正好是带子宽度**（`MacTheme.voiceWaveformBandWidth`），
    ///    这样「带子中心 = 整行中心 = 面板中轴」恒成立，两颗按钮对称贴在带子两端。
    private var waveformRow: some View {
        HStack(spacing: MacTheme.voiceActionButtonGap) {
            if !isFinishing {
                sideButton(symbol: "xmark",
                           help: L("结束并放弃这次语音输入（Esc）"),
                           action: onCancel)
                // Esc 结束（= 左钮那颗）。挂在按钮上而不是 `onExitCommand` —— 后者要求视图拿到
                // 键盘焦点，而这块浮层**故意是不可聚焦的**（输入框自己可能正握着焦点）。
                .keyboardShortcut(.escape, modifiers: [])
            }
            VoiceWaveform(levels: levels)
                .frame(width: MacTheme.voiceWaveformBandWidth(count: levels.count))
            if !isFinishing {
                sideButton(symbol: "checkmark",
                           help: L("结束并发送"),
                           action: onSend)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 波形两侧的圆钮（✗ / ✓）。半透明白底压在蓝光上，图标白色。
    private func sideButton(symbol: String,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(MacTheme.ui(MacTheme.voiceActionIconSize, weight: .semibold))
                .foregroundStyle(MacTheme.voiceActionIconColor)
                .frame(width: MacTheme.voiceActionButtonSize,
                       height: MacTheme.voiceActionButtonSize)
                .background(Circle().fill(MacTheme.voiceActionButtonFill))
                .overlay(Circle().strokeBorder(MacTheme.voiceActionButtonStroke, lineWidth: 1))
                // 命中区 = 圆本身（`.buttonStyle(.plain)` 下 label 即命中区）。
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 各行

    private var timerLabel: some View {
        Text(Self.timeText(elapsed))
            .font(MacTheme.ui(MacTheme.voiceTimerFontSize))
            .monospacedDigit()
            .foregroundStyle(MacTheme.voiceTimerColor)
            .frame(maxWidth: .infinity)
            .frame(height: MacTheme.voiceTimerHeight)
    }

    private var hintLabel: some View {
        Text(hintText)
            .font(MacTheme.ui(MacTheme.voiceHintFontSize))
            .foregroundStyle(isFinishing ? MacTheme.voiceHintBusyColor : MacTheme.voiceHintColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: MacTheme.voiceHintHeight)
    }

    private var transcriptLabel: some View {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // 尾部截断而不是头部：说话是**往后长**的，要看的是刚说出来的那几个字。
        return Text(trimmed.isEmpty ? Self.transcriptPlaceholder : trimmed)
            .font(MacTheme.ui(MacTheme.voiceTranscriptFontSize))
            .foregroundStyle(trimmed.isEmpty
                             ? MacTheme.voiceTranscriptPlaceholderColor
                             : MacTheme.voiceTranscriptColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .frame(height: MacTheme.voiceTranscriptHeight)
    }

    private var hintText: String {
        isFinishing ? Self.finishingHint : Self.recordingHint
    }

    // MARK: - 文案与格式
    //
    // 🔴 下面三条**必须是计算属性**（2026-10-13 接本地化时踩到）：`static let` 会在第一次
    //    读到就把 `L()` 的结果**进程级缓存**住 ⇒ 切完语言永远是旧语言那份，**连视图重建都救不回来**。
    //    同款坑本仓还有十来处，见 `.workbuddy/memory/I18N.md`。

    private static var transcriptPlaceholder: String { L("请开始说话…") }
    /// ⚠️ Mac 是**点按式**（两颗圆钮在波形两侧：✗ 结束 / ✓ 发送），所以不是 iOS 那句
    ///    「松手发送，上移取消」—— 照抄会误导（Mac 没有「松手」「上移」这两个动作）。
    private static var recordingHint: String { L("点 ✗ 结束 · 点 ✓ 发送") }
    private static var finishingHint: String { L("正在整理文字…") }

    /// `m:ss`。**只在这里写一遍** —— 别在模型里再算一个字符串（两处口径迟早对不上）。
    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 波形

/// 一排竖条，高度由音量历史驱动。
///
/// 观感（2026-10-03 改成与 iOS `VoiceWaveformView` **同参**，两端看起来得是同一个东西）：
/// 1. **滚动历史**（每次推进整体左移、新的进队尾）→ 肉眼看到的是波形在流动；
/// 2. **条宽固定 3pt、带子整组居中**（⛔ 不再「可用宽度 ÷ 条数」反推 —— 反推在宽栏上会把条拉成药丸）；
/// 3. **没有空间包络**（实测参考图峰值散落各处，不是「中间高两侧低」）；
/// 4. **基线 6pt 可见**（那条「刻度线」的本体），条围绕水平中轴上下**对称**生长。
///
/// ⚠️ 条数由 `levels.count` 决定（模型给的历史长度就是它），这里**不另设** `barCount` ——
///    两处各存一个数字，迟早出现「历史 46 条、视图画 40 根」这种对不齐。
struct VoiceWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            let count = levels.count
            // 窄窗口兜底：带子比可用宽度还长时整体等比压一压。
            // ⚠️ Mac 上 46 条 × 3pt + 45 × 2pt = 228pt，比任何窗口都窄 ⇒ 永远走不到；
            //    这是给极端窄栏留的安全阀，⛔ 不要因此把条宽改回「反推」。
            // 🔴 带子总宽走 `MacTheme.voiceWaveformBandWidth`（**单点**）—— 面板要靠同一个数
            //    在带子两侧给两颗按钮让位，两处各算一遍迟早对不上。
            let natural = MacTheme.voiceWaveformBandWidth(count: count)
            let scale = (natural > geometry.size.width && natural > 0)
                ? geometry.size.width / natural : 1
            let barWidth = max(1.5, MacTheme.voiceWaveformBarWidth * scale)
            let spacing = max(1, MacTheme.voiceWaveformSpacing * scale)
            let maxHeight = min(MacTheme.voiceWaveformMaxBarHeight, geometry.size.height)
            let minHeight = min(MacTheme.voiceWaveformMinBarHeight, maxHeight)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { item in
                    // 圆头：半径恒为条宽的一半 ⇒ 不管长多高都是胶囊端（参考图那排就是这个形状）
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(MacTheme.voiceWaveformBarColor)
                        .frame(width: barWidth,
                               height: barHeight(for: item.element,
                                                 minHeight: minHeight,
                                                 maxHeight: maxHeight))
                }
            }
            // 居中：条宽固定之后，多出来的宽度留给两侧留白（而不是让条继续长胖）。
            // 也不做顶部对齐 —— 条的视觉重心在中轴（`alignment: .center`）。
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .frame(height: MacTheme.voiceWaveformHeight)
        // 纯展示：不吃点击（它整块都在浮层里，浮层靠 `allowsHitTesting(false)` 放行点击）
        .allowsHitTesting(false)
    }

    private func barHeight(for level: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let clamped = min(max(level, 0), 1)
        // 🔴 **没有任何空间包络**：条高只由音量决定（基线 + 增量）。
        return minHeight + (maxHeight - minHeight) * clamped
    }
}
