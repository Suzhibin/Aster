//
//  MacVoiceCallTheme.swift
//  AsterMac
//
//  Mac 端「打电话」独立窗口的**几何与配色单点**（2026-10-12）。
//
//  ## 为什么单独一个文件
//  同一批数字被三处用：窗口（内容尺寸）、内容视图（间距）、三个点（直径 / 上限）。
//  本仓库在「量算必须与渲染同源」上栽过不止一次 ⇒ 全部收在这里，别在视图里再写一遍。
//
//  ## 配色一律**语义色**（本工程 Mac UI 铁律）
//  ⛔ 别写死 `Color.white` / `Color.black`：窗口要同时吃浅色 / 深色主题。
//  参考图（`Clipboard_Screenshot*.png`，豆包那个通话窗）是浅色主题下的样子 ——
//  它给的是**明暗关系**（底白、点深、挂断红），不是具体色值。
//
//  ## 尺寸从哪来
//  参考图是 2x 截图（窗口约 587×800 px ⇒ 293×400 pt）。本页取 320×420 —— 略宽一点，
//  因为**头像被删掉了**（用户口径：「去掉中间豆包头像即可」），中间这块只剩三点与两行字，
//  太窄会让字挤在一起。
//

import AppKit
import SwiftUI

enum MacVoiceCallTheme {

    // MARK: - 窗口

    /// 内容区尺寸（**不含**标题栏）。标题栏透明、不显示标题，所以视觉上就是这块卡片。
    static let contentSize = NSSize(width: 320, height: 420)

    /// 内容区最小尺寸。窗口**不可缩放**（`styleMask` 里没有 `.resizable`），
    /// 这个值只用来兜住「系统给了一个奇怪的初始 frame」那一种情况。
    static let minContentSize = NSSize(width: 300, height: 380)

    // MARK: - 三个点（音量指示）

    /// 单点在**静止态**的直径。与 iOS 通话页同口径（12pt）。
    static let dotDiameter: CGFloat = 12

    /// 相邻两点的**净间隙**。比 iOS（4）略大一点：那边是手机窄屏、这边窗口更宽，
    /// 点位太挤会显得一坨。
    static let dotGap: CGFloat = 5

    /// 被音量顶到最高时的高度。
    /// 🔴 与 iOS 同一口径：**2.17 倍直径**（用户 2026-10-12 明确要求「幅度再扩大一些」，
    ///    不是参考图那个 1.62 倍）。⛔ 两端的三个点是同一个东西，别只改一边。
    static let dotMaxHeight: CGFloat = 26

    /// 驱动增益：`drive = min(1, level × 增益)`。
    /// 🔴 与上限是**一对**（只抬一个，用户看到的还是"幅度很小"）。同 iOS：1.45。
    static let dotGain: Double = 1.45

    /// 一个点走完「趴下 → 拉满 → 趴下」的周期（秒）。同 iOS：1.05。
    static let dotCycle: Double = 1.05

    /// 三点承载盒的高度（**恒定** = 拉满时的高度）。
    /// 🔴 点是从圆心朝上下两头长的，盒子高度不跟着变 ⇒ 下面那行文字不会随音量上下抖。
    static var dotBoxHeight: CGFloat { dotMaxHeight }

    /// 三点承载盒的宽度（= 3 个点 + 2 个间隙）。
    /// ⚠️ 点数（3）**只有这里知道** —— 视图别自己再数一遍。
    static var dotBoxWidth: CGFloat { dotDiameter * 3 + dotGap * 2 }

    // MARK: - 中央那颗白球（2026-10-27 加；iOS `AIVoiceCallBallView` 的 Mac 版）

    /// 球体直径。
    ///
    /// 🔴 与 iOS 的 `AIVoiceCallMetrics.ballDiameter`（180）**不同值**，这是刻意的：
    ///    那边是 402pt 宽的手机屏，这边窗口只有 **320pt** 宽。若按"占屏宽同样的比例"
    ///    折算（320 × 180/402 ≈ 143），球加柔光会顶到窗口上沿 ——
    ///    本窗口上方只有 ~130pt 可用（三点被两个等分 Spacer 摆在竖直中央）。
    ///    ⇒ 取 **100**（原始需求「100×100 的白球」那个数）。
    ///    ⛔ 别为了"和 iOS 一样"把它改成 180：那会压掉三点。
    static let ballDiameter: CGFloat = 100

    /// 球外那圈柔光**向外扩出**多少 pt。
    /// ⚠️ 它画在球体之外（视图盒子 = 直径 + 两侧各这么宽）⇒「球 = 100×100」这条口径不被柔光改掉。
    /// 🔴 与 iOS 同值：那边也是 22（`AIVoiceCallBallView.glowInset`）。
    static let ballGlowInset: CGFloat = 22

    /// 球视图的**盒子**边长（= 直径 + 两侧柔光）。
    ///
    /// 🔴 定位时按**盒子**算，别按直径：柔光画在球体之外，盒子比球大 44pt。
    ///    `MacVoiceCallView` 把"盒子中心"对齐到舞台中心（2026-10-27 用户：「白球位置要居中」），
    ///    这里若按直径算，球会整体往上偏 22pt（而且截图量出来是"居中"的球心不居中）。
    static var ballBoxSide: CGFloat { ballDiameter + ballGlowInset * 2 }

    /// 球下沿 → 三点承载盒上沿的净间隙。
    /// ⚠️ 球与三点是**两个独立图层**：`MacVoiceCallView.content` 用这条常量算"三点该从哪开始"，
    ///    球自己则按舞台中心定位 ⇒ 改这个数只会挪三点，不会挪球。
    static let ballToDots: CGFloat = 18

    /// 静息呼吸一个来回的时长（秒）。🔴 与 iOS 同值 3.4 —— 两端"睡着了的呼吸"要同一个节奏。
    static let ballBreathPeriod: Double = 3.4

    /// 静息呼吸幅度（±5%）。⛔ 别加大：这一档要的是"它活着"，不是"它在动"。与 iOS 同值。
    static let ballBreathAmplitude: Double = 0.05

    /// AI 说话时在静息呼吸**之上再**叠多少（最多 +16% ⇒ 峰值 ≈ 1.21 倍）。与 iOS 同值。
    static let ballVoiceAmplitude: Double = 0.16

    /// 开口 / 收口的过渡时长（秒）。
    /// ⚠️ iOS 那边是逐帧 `mix += (target - mix) * 0.08`（≈0.4s 收敛）；SwiftUI 这里
    ///    没有"每帧存一个中间值"的写法，改成**按时间线性爬到 1**（两个相位都从切换那一刻算）。
    static let ballVoiceRamp: Double = 0.4

    /// 球体高光中心（纯白，本页亮度档的最高一档）
    /// 🎨 与 iOS `AIVoiceCallPalette.ballCore` 同色（那边是 `.white`）。
    static let ballCore = Color(white: 1)

    /// 球体底色（冷灰）。
    /// 🎨 与 iOS `AIVoiceCallPalette.ballShade` 同值 —— 纯白实心压在深空上像一张贴纸，
    ///    压一层极淡的冷灰打底、再从左上打一团白高光，出来才是颗"球"。
    static let ballShade = Color(red: 0.84, green: 0.86, blue: 0.93)

    /// 球外柔光的颜色（白，靠渐变从 0.34 → 0 收掉）。
    /// ⚠️ 与 iOS `AIVoiceCallPalette.ballGlow` 同色。
    static let ballGlow = Color(white: 1)

    // MARK: - 中间那两行字

    /// 状态行（「请开始说话」/「正在思考…」/「已静音」）
    static let statusFontSize: CGFloat = 15
    /// 副行（静音态那句「按住 ⌥+E 可以暂时打开麦克风」）
    static let hintFontSize: CGFloat = 12
    /// 三点盒 → 状态行
    static let statusTopSpacing: CGFloat = 22
    /// 状态行 → 副行
    static let hintTopSpacing: CGFloat = 6

    // MARK: - 底部那一排按钮

    /// 图标字号
    static let buttonIconSize: CGFloat = 21
    /// 单颗按钮的**命中区**（⛔ 不是图标大小 —— 图标 21pt 直接当命中区太小了）
    static let buttonHitSize: CGFloat = 44
    /// 相邻两颗的间距（**按钮之间**，不含命中区内边距）
    static let buttonSpacing: CGFloat = 22
    /// 按钮行**下沿**到内容区底边的距离
    static let buttonRowBottomInset: CGFloat = 26

    // MARK: - 星空背景（`MacStarrySkyView` 的粒子参数）

    /// 粒子总数。
    /// ⚠️ 与 iOS 的 `birthRate × lifetime`（≈500）**不是同一口径** ——
    ///    那边是"每秒生 10 个、活 50 秒"，且多数早飘出全屏；本窗口小，直接给"同时存在数"。
    static let skyParticleCount = 110

    /// 单个粒子的寿命区间（秒）。各自错相位，不要求同步。
    static let skyLifetimeMin: Double = 12
    static let skyLifetimeMax: Double = 22

    /// 飘散速度区间（pt/s）。
    /// ⚠️ iOS 是 `velocity 20 ± 10`，那是给**全屏手机**调的；320×420 的窗口按同样的
    ///    位移量算，星星一秒就飞出画面 ⇒ 这里重新标定，**别照抄 iOS 的数**。
    static let skySpeedMin: Double = 4
    static let skySpeedMax: Double = 14

    /// 出生点半径的上限（pt）：粒子从**中心附近**出发再向外飘
    /// （对应 iOS 的 `emitterShape = .circle` + `emitterMode = .outline`）。
    static let skyBirthRadius: Double = 24

    /// 星点直径区间（pt）。iOS 的 `scale 0.02` 是**相对原图尺寸的比例**，
    /// 本方案没有位图 ⇒ 没法换算，按窗口观感直接标定。
    static let skyStarSizeMin: Double = 0.8
    static let skyStarSizeMax: Double = 2.2

    /// 星点基础不透明度（闪烁 / 淡入淡出 / 层次再往上乘）
    static let skyStarAlpha: Double = 0.85

    /// 深空底（最暗那一层）—— **NSColor 版本**（窗口的 `backgroundColor` 用）。
    ///
    /// 窗口的 `backgroundColor` 只吃 `NSColor`，而视图只吃 `Color`
    /// （见 `MacVoiceCallWindowCenter.open` 里那一行）⇒ 必须有这一对。
    /// 🔴 两处**必须从同一个常量来**：各写一个必然漂 ——
    ///    症状是标题栏那一条与内容区差一档色，像一道横缝。
    static let skyDeepestNSColor = NSColor(srgbRed: 0.043, green: 0.035, blue: 0.086, alpha: 1)

    /// 深空底（最暗那一层）。
    /// 🔴 必须**不透明**，它同时担两个角色：
    ///    ① **兜底**：真实银河照（`bj_Starry`）取不到时，内容区就靠它兜住
    ///       （取不到的来路见 `MacStarrySkyView.skyPhoto` 注释）；
    ///    ② **压暗层**：照片在时以 `skyPhotoDim` 的透明度压一层（见下面那条）。
    static let skyDeepest = Color(nsColor: skyDeepestNSColor)

    /// 真实银河底图（`bj_Starry`）之上压暗的强度（0 = 原图，1 = 全盖掉成纯深空）。
    ///
    /// 🔴 **为什么这里要压、iOS 那边不压**：这张照片中部偏亮（银河核心那一带），
    ///    而本页前景是**白字 + 白点**。iOS 的窗口是**全屏手机**，三点 / 状态行落在
    ///    上三分之一，正好是照片最暗的一片；本窗口更矮（320×420），文字更靠中，
    ///    不压一档就会在银河亮部上糊掉。
    /// ⚠️ 别往大调：这一层的目的是**保可读**，不是把照片盖掉 ——
    ///    超过 0.6 照片基本就看不见了，那还不如不放图（直接走纯深空那版）。
    static let skyPhotoDim: Double = 0.22

    /// 中心那团「银河辉」（以中心偏上为圆心，压在 `skyDeepest` 上）
    static let skyGlow = Color(red: 0.28, green: 0.20, blue: 0.48).opacity(0.55)

    /// 左下星云（暖紫）
    static let skyNebulaWarm = Color(red: 0.42, green: 0.20, blue: 0.46).opacity(0.34)

    /// 右上星云（冷蓝）
    static let skyNebulaCool = Color(red: 0.13, green: 0.28, blue: 0.55).opacity(0.30)

    // MARK: - 前景配色

    // ────────────────────────────────────────────────────────────────────────
    // 🔴 以下是**前景**。2026-10-12 起本页是「**恒深空**」页 ⇒ 前景一律恒取亮色。
    //
    //  ## 为什么这里不再是语义色（**本工程里唯一的例外**，照 iOS `AIVoiceCallPalette` 口径）
    //  参考图（浅色主题）给的是**明暗关系**（底白 · 点深 · 挂断红），不是色值。
    //  底色换成深空之后，「底」就**不跟系统深浅档走**了 —— 这时若前景还取
    //  `labelColor` / `secondaryLabelColor` 这类**动态色**，用户把系统调成浅色档时
    //  它们会翻成深字，压在深空上就是"一片看不见"。
    //  ⇒ 本页规则很简单：**底色恒深 ⇒ 所有前景恒取亮色**。
    //  ⛔ 别把下面这些改回 `NSColor.labelColor` 之类；要调的是**亮度档位**，
    //     不是"换回语义色"。
    //
    //  ## 档位与 iOS 成组对齐（改一边必须改另一边）
    //    iOS `AIVoiceCallPalette`：三点 0.80 · 提示语 0.72 · footer 0.62 · 挂断红 (0.94, 0.30, 0.24)
    //    Mac 本文件：            三点 0.80 · 状态行 0.92 · 副行 0.62 · 挂断红 (0.94, 0.30, 0.24)
    // ────────────────────────────────────────────────────────────────────────

    /// 挂断 / 静音那颗的红。
    /// ⚠️ 与 iOS `AIVoiceCallPalette.hangupRed` **同值**：深底上比系统 `.systemRed`
    ///    更清楚，而且两端不能各自漂。
    static let hangUpRed = Color(red: 0.94, green: 0.30, blue: 0.24)

    /// 三个点。⚠️ 0.80 —— 与 iOS `AIVoiceCallPalette.indicatorFill` 同值
    ///    （那边实测：点比提示语略亮一点、基本同一族）。
    static let dot = Color(white: 0.80)

    /// 状态行文字（「请开始说话」/「正在思考…」/「已静音」）—— 本页最亮的一档
    static let statusText = Color(white: 0.92)

    /// 副行文字（静音态那句 ⌥+E 提示）—— 比状态行弱一档
    static let hintText = Color(white: 0.62)

    /// 常规图标（麦克风 / 挂断）
    static let icon = Color(white: 0.95)

    /// ⚠️ 2026-10-27 删掉了 `iconDisabled`（0.38 那档）：它唯一的消费者是底部那颗
    ///    "视频通话暂未支持"的灰摆设，而用户要求「底部四个按钮去掉前面俩个」时把它一起删了。
    ///    ⛔ 别为了"凑齐档位表"把它加回来 —— 主题里的常量必须**有消费者**，
    ///    没人用的色值只会在下一次调色时骗人（改了半天，界面上什么都没变）。

    /// 挂断（红）
    static let hangUp = hangUpRed

    /// 静音态的麦克风（红）
    static let mutedIcon = hangUpRed

    /// 悬停时的圆底。
    /// ⚠️ 深空上是**提亮**，不是压暗 ⇒ ⛔ 别用 `.primary.opacity(...)`
    ///    （那是"把底压黑"的语义，在深色底上等于什么都没画）。
    /// ⚠️ 写 `Color(white: 1)` 而**不是** `Color.white`：本页前景全部走**亮度档**这一个
    ///    坐标系（1 / 0.95 / 0.92 / 0.80 / 0.62 / 0.38），裸命名色是另一套语汇，
    ///    混用会让"档位"这条线断掉（且契约也会拦，见 `render_mac_ui.sh` 的反向断言）。
    static let hoverFill = Color(white: 1).opacity(0.12)
}
