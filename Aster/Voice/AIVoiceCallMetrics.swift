//
//  AIVoiceCallMetrics.swift
//  Aster
//
//  通话页的**几何单一出处**（2026-10-10，参考图 IMG_3166.PNG）。
//
//  ## 为什么单独一个文件
//  这张页上的元素分布在四个视图里（背景 / 球 / 控件 / 控制器），同一件东西的尺寸往往
//  被不止一处用到（球的直径 = 球自己 + 自检脚本；三个点的高度 = 点自己 + 承载盒 + 提示语锚点）。
//  各写一份必然漂（本仓库在「量算必须与渲染同源」上栽过不止一次）⇒ 全部收在这里。
//
//  ## 参考图怎么换算的（500 × 1013 px）
//  ⚠️ 这张图的**横纵比例与任何一款 iPhone 都对不上**（1013/500 = 2.026，而 iPhone 是 2.16）。
//  所以**不能用同一个系数**去换算横纵：
//  - **横向**按 `500px ↔ 屏宽`（`k = 屏宽 / 500`）；
//  - **纵向**改用**比例**（`y / 1013`），也就是「占整个视高的百分之几」。
//  凡是「距底多少」的元素一律**贴底锚定**，这样换机型时底部那一簇不会跟着飘。
//
//  | 元素 | 参考图量到的 | 落成的口径 |
//  |---|---|---|
//  | 球直径 | 295px 宽 | ~~屏宽 × 0.59~~（那颗流体球 2026-10-26 已删，现在是 100pt 白球） |
//  | 球心纵向 | 425 / 1013 | ~~视高 × 0.42~~（同上，现在由控制器在「顶部安全区 → 底部控件簇」之间居中） |
//  | 圆钮直径 | 76px 宽 | **60pt**（横向换算 59.3） |
//  | 圆钮左右边距 | 27px / 29px | **20pt**（等分后实测 20 / 22） |
//
//  ⚠️ 提示语上方那颗元素 IMG_3166 上是「小方块」，但 10-11 用户给了新参考图
//     （`Clipboard_Screenshot*.png`）：那里真正的形态是**三个点**、且是**音量指示**。
//     换过后它的口径改按新参考图量（见下面 `indicator*` 那一组常量的注释）。
//

import UIKit

enum AIVoiceCallMetrics {

    // MARK: - 中央那颗白球

    /// 白球直径 = **180pt 固定**。
    ///
    /// 🔴 这里**刻意不按屏宽比例**，与下面那张参考图表格里的"球直径 = 屏宽 × 0.59"是两回事：
    ///    那颗 0.59 的**多色流体球**已于 2026-10-26 删除（备份在
    ///    `.workbuddy/backups/dead-voice-views-2026-10-26.tgz`），
    ///    现在这颗的语义是"**AI 正在说话的指示灯**"，尺寸与屏宽无关。
    ///    ⛔ 别改回比例口径 —— 那会在 iPad / 横屏上把它撑成一团。
    static let ballDiameter: CGFloat = 180

    // MARK: - 顶部三件套

    /// 顶栏高度（三件套共用一行）
    static let topBarHeight: CGFloat = 44

    /// 顶栏中心距**安全区顶边**的距离（参考图：状态栏中心 → 顶栏中心 ≈ 24pt）
    static let topBarCenterBelowSafeTop: CGFloat = 24

    /// 「选择情景」胶囊高度（参考图 38px 纵向 → 取整成 30）
    static let scenePillHeight: CGFloat = 30

    /// 胶囊左右内边距
    static let scenePillPaddingH: CGFloat = 12

    /// 胶囊里图标与文字之间的间距
    static let scenePillIconSpacing: CGFloat = 6

    /// 左右两颗按钮的边长（图标按钮的可点区域，⛔ 别按图形大小给）
    static let topBarButtonSide: CGFloat = 38

    /// 左右两颗按钮距屏幕边缘
    static let topBarButtonInset: CGFloat = 10

    // MARK: - 底部控件

    /// 圆钮直径（参考图 76px 横向 → 59.3pt）
    static let buttonDiameter: CGFloat = 60

    /// 圆钮行距屏幕左右边缘（参考图 4 颗等分后实测 20 / 22，取 20）。
    /// ⚠️ 2026-10-12 删掉第 2 颗（静音）后只剩 3 颗 —— **这个边距不变**，
    ///    钮间距由 `.equalSpacing` 自己等分（因此比 4 颗时更宽，⛔ 别写死间距）。
    static let buttonRowInset: CGFloat = 50

    /// 圆钮行**下沿**到「内容由 AI 生成」上沿的距离
    static let buttonRowToFooter: CGFloat = 20

    /// 「内容由 AI 生成」到**安全区底边**的距离
    static let footerToSafeBottom: CGFloat = 12

    /// 提示语（「说话或点击打断」）下沿到圆钮行上沿的距离（参考图这块留白很大，别收窄）
    static let hintToButtonRow: CGFloat = 49

    /// 提示语距屏幕左右边缘的**最小**留白。
    ///
    /// ⚠️ 这一行在通话中会临时变成**实时字幕**（用户说的整句都会灌进来，见
    ///    `AIVoiceCallViewController.refreshHint`），所以它必须有宽度上限 ——
    ///    没有它，一句长话会横着撑出屏幕。提示语本身很短、居中，留白大小对观感几乎无影响。
    static let hintSideInset: CGFloat = 24

    // MARK: - 音量指示的三个点（2026-10-11 替代原「小方块」，见 `AIVoiceCallDotsView`）

    /// 单个点在**静止态**的直径（= 圆的直径）。
    /// 参考图实测：点 21px 宽，而同帧「正在听…」那行汉字字高 26px
    /// ⇒ 点 ≈ 0.81 × 提示语字高，按本页 15pt 的提示语字号折出 12pt。
    static let indicatorDotDiameter: CGFloat = 12

    /// 相邻两点的**净间隙**（参考图实测圆心距 28.5px ≈ 1.36 × 直径 ⇒ 间隙 = 0.36 × 直径）
    static let indicatorDotGap: CGFloat = 4

    /// 被音量顶到最高时的高度。
    ///
    /// 🔴 2026-10-12 用户反馈「说话时变化幅度太小」⇒ 由参考图口径的 1.62 倍**主动放大**：
    ///    `19 → 26`（= **2.17 倍直径**，每侧伸长 7pt）。
    ///    ⚠️ 这是**故意偏离参考图**的一处 —— 参考图 `Clipboard_Screenshot*.png` 上是 34px ÷ 21px
    ///    = 1.62 倍，但那个倍率落到本页 12pt 的点上只有 7pt 高差，说话时几乎看不出来。
    ///    ⛔ 别再按参考图"改回去"；真要改，先问用户。
    ///
    /// 🔴 必须**明显大于**直径 —— 否则"随音量上下变大变小"这件事根本看不出来，
    ///    而且**跑图看不出来**（静音态照样正确，只有说话时才发现它没动）。
    ///    契约脚本里为此有一条数值断言（`max > 直径 × 2.0`）。
    static let indicatorDotMaxHeight: CGFloat = 26

    /// 指示器**承载盒**的下沿 → 提示语上沿。
    /// ⚠️ 盒子高度**恒等于 `indicatorDotMaxHeight`**，点在盒内**恒居中**：
    ///    点是从圆心朝两头长的（参考图两张图实测），盒子高度不跟着变 ⇒ 提示语一动不动。
    ///    ⛔ 别让盒子高度跟着点走（那会让提示语随音量上下抖，而且截图里看不出来是"算错了"）。
    static let indicatorToHint: CGFloat = 22

    // MARK: - 轻提示（toast）的停靠位置

    /// toast **底边**距「安全区底边」的距离（= `AIToast.show(_:in:bottomInset:)` 的那个入参）。
    ///
    /// 🔴 2026-10-26 实测（iPhone 18 Pro，屏高 874pt）：原来的 **130 会压住提示语** ——
    ///    toast 占 y = 678~710，而提示语在 672~686，字被切掉一半。用户说的「看不清楚」
    ///    有一半是这个（另一半是时长太短，见 `AIToast.duration`）。
    ///
    /// 口径：**按底部那一簇自下而上串**（⛔ 别写死"屏高 × 几%"—— 簇本身是贴底锚定的，
    /// 换机型会整块平移，比例必然漂）：
    /// ```
    /// 12(免责声明→底) + 13(免责声明) + 20(免责声明→钮) + 60(圆钮)
    /// + 49(钮→提示语) + 18(提示语) + 22(提示语→指示器盒) + 26(指示器盒)
    /// + 12(留白) = 232
    /// ```
    /// ⚠️ 提示语变**多行字幕**时这一簇会整体上移，理论上 toast 会贴到三点上；
    ///    但字幕只在拾音中出现，而错误 toast 会先把麦关掉 ⇒ 两者不会同时在场，不额外处理。
    static let toastBottomInset: CGFloat = 232

    // MARK: - 字号（参考图按 500px 宽换算）

    /// 「选择情景」
    static let scenePillFontSize: CGFloat = 14
    /// 右上角那个「字」
    static let subtitleFontSize: CGFloat = 17
    /// 提示语「说话或点击打断」
    static let hintFontSize: CGFloat = 15
    /// 最底下「内容由 AI 生成」
    static let footerFontSize: CGFloat = 11

    /// 圆钮里的图标（参考图图标高约 30px / 76px 直径 ≈ 0.4）
    static let buttonIconPointSize: CGFloat = 24
}
