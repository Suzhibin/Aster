//
//  AIVoiceCallPalette.swift
//  Aster
//
//  通话页的**配色单一出处**（2026-10-10 建；2026-10-11 改深色）。
//
//  ## 底纹已经换成深空（`StarrySkyEngine` 星空）
//  ⇒ 这一页现在是**深色沉浸页**：控制器里 `overrideUserInterfaceStyle = .dark`、
//    状态栏 `.lightContent`、`view.backgroundColor = .black`。
//  ⛔ 别把这些换成 `.label` / `.systemBackground` 那类**动态色**：
//    动态色跟着**系统**深浅档翻，而这一页的深浅是**页面自己定死的**（不跟系统走）
//    ⇒ 用户把系统调成浅色时，动态色会翻成深字，压在深空上就是"一片看不见"。
//    这一页的规则很简单：**底色恒深 ⇒ 所有前景恒取亮色**。
//
//  ## 取色口径
//  数值都是按区域取的**中间值**（不是某一点的像素值 —— 图上到处是渐变，单点取值会取到噪）。
//  改配色时请整块换，别只动一颗按钮：这几颗按钮的深浅关系是**成组**的
//  （白底那颗 = "当前生效"，其余深色玻璃 = "未生效"，图标色也跟着底走），
//  单独调一颗会破坏这个语义。
//
//  ## ☠️ 深浅档的「更淡一档」是**反的**（调色时最容易搞错）
//  浅底上"更淡" = 更接近白底 = `white` 值更**大**；
//  深底上"更淡" = 更接近黑底 = `white` 值更**小**。
//  ⇒ `footer`（免责声明）在浅底上比 `hint` 更亮，换成深底后必须比 `hint` 更**暗** ——
//    否则最不重要的一行反而最抢眼，层级直接翻过来。
//

import UIKit

enum AIVoiceCallPalette {

    // MARK: - 页面文字

    /// 顶栏图标与文字（`…` / `选择情景` / `字`）——深空底上取近白（纯白会显得太硬）
    static let topBarInk = UIColor(white: 0.96, alpha: 1)

    /// 「说话或点击打断」
    static let hint = UIColor(white: 0.72, alpha: 1)

    /// 「内容由 AI 生成」——⚠️ 比 `hint` **暗**一档才是"更淡"（见文件头末段）。
    /// 档差取 **0.10**（与参考图里 `footer` 比 `hint` 亮 0.10 的层差**镜像**过来）。
    /// ☠️ 别再往下压：页面底部压着一片**亮星云**（实测背景亮度 ≈88，不是黑），
    ///    灰字压上去对比度掉得很快 —— 压到 0.45 时实测几乎糊进星空里。
    static let footer = UIColor(white: 0.62, alpha: 1)

    // MARK: - 顶栏

    /// 「选择情景」那颗胶囊的底：**深色玻璃**（低透明白压在深空上 ≈ 中深灰）
    static let scenePillFill = UIColor(white: 1, alpha: 0.24)

    // MARK: - 圆钮

    /// 「当前生效」那一颗的底：**纯白实心**（深色页里这颗白钮就是视觉焦点，别动它）
    static let buttonFilled = UIColor.white

    /// 其余三颗的底：**深色玻璃**（未生效 / 次要）
    static let buttonTranslucent = UIColor(white: 1, alpha: 0.24)

    /// 白底钮上的图标（深）
    static let buttonIconOnFilled = UIColor(white: 0.12, alpha: 1)

    /// 玻璃底钮上的图标（浅）
    static let buttonIconOnTranslucent = UIColor(white: 0.95, alpha: 1)

    /// 挂断那颗叉的红（比系统 `.systemRed` 更正的朱红；深底上略提亮一档更清楚）
    static let hangupRed = UIColor(red: 0.94, green: 0.30, blue: 0.24, alpha: 1)

    // MARK: - 提示语上方那三个点（音量指示）

    /// 三个点的颜色（`AIVoiceCallDotsView`）。
    ///
    /// ⚠️ 参考图（`Clipboard_Screenshot*.png`，浅底）实测：点的亮度 **118**、
    ///    同一帧提示语文字最深处 **110**、背景 238 ⇒ **点比文字略亮一点点、基本同一族**。
    ///    深底上按同一条关系镜像过来：`hint` 是 0.72，点取它上一档 ⇒ **0.80**。
    ///    （浅底"更实"= 更深；深底"更实"= 更亮，见文件头那段。）
    static let indicatorFill = UIColor(white: 0.80, alpha: 1)

    // MARK: - 中央那颗白球（`AIVoiceCallBallView`）

    /// 球本体：**纯白**（用户原话「白色圆球」）。
    static let ballCore = UIColor.white

    /// 球体的**明暗底色**（垫在纯白下面、只从球心偏左上露出高光）。
    ///
    /// ⚠️ 存在的理由：纯白实心压在深空上是一张贴纸 —— 没有体积、边缘也没有过渡。
    ///    压一层极淡的冷灰打底，白高光才"立"得起来。
    ///    色相刻意偏冷（蓝略高于红）：这一页底纹是深空，纯中性灰会显得发脏。
    static let ballShade = UIColor(red: 0.84, green: 0.86, blue: 0.93, alpha: 1)

    /// 球外那圈柔光（画在球体边界**外**，见 `AIVoiceCallBallView.glowInset`）
    static let ballGlow = UIColor.white
}
