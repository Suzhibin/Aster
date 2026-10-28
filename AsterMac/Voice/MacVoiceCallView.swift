//
//  MacVoiceCallView.swift
//  AsterMac
//
//  「打电话」窗口的**内容视图**（2026-10-12）。形态照参考图
//  （`Clipboard_Screenshot.png` / `Clipboard_Screenshot-1.png`，豆包那个通话窗）。
//
//  ## 🔴 与参考图的差别：**中间那个豆包头像**去掉，换成**一颗白球**
//  用户口径（2026-10-12）：「与图样式一样，**去掉中间豆包头像即可**」；
//  2026-10-27 追加：「mac端 也要增加白球，当 AI 回复的时候 随着 AI 声音 白球关联呼吸动画」，
//  同日又追加两条：「**白球位置要居中**」「底部四个按钮**去掉前面俩个**」。
//  ⇒ 自上而下是：**白球（正中）→ 三个点（音量指示）→ 状态行 →（静音态多一行副行）→ 底部两颗钮**。
//  ⚠️ 底部那排只剩**麦克风 + 挂断**：视频（本来就没做）与「消息」两颗已按用户要求删掉，
//     连带 `onShowChat` 这条通路也一起收了（没有入口的闭包就是死代码）。
//  ⚠️ 白球是**形状**（`Circle` + 渐变），不是图片、也不是 SF Symbol —— 它不参与
//     "头像计数断言"（那条守的是「SF Symbol 图标在视图里只该有 1 处」，见 render_mac_ui.sh ⑤）。
//     ℹ️ 注释里也别把那句 `Image(` + `systemName:` 的字面串写进来：那条断言是**按行 grep** 的，
//        注释会一起被数进去（2026-10-27 真踩过，刚加完球脚本就报"出现了 2 处"）。
//  中间这块的垂直重心**在 2026-10-27 第二版被用户改过一次**：
//  上一版是把球 overlay 挂在三点上方（球心在内容区 ~26% 处），用户嫌偏上 ⇒
//  现在球**自己站在舞台正中**，三点与两行字从球下沿往下排（见 `content`）。
//  ⛔ 别再退回"球挂在三点上方、整簇均分"那版：那是被否掉的形态。
//
//  ## 两个态（参考图两张就是这两张）
//  | | 未静音（图 1） | 已静音（图 2） |
//  |---|---|---|
//  | 三个点 | 显示（拾音时随音量跳） | **不显示**（参考图里就没有） |
//  | 状态行 | 「请开始说话」/ 实时字幕 / 「正在思考…」 | 「已静音」 |
//  | 副行 | 无 | 「按住 ⌥+E 可以暂时打开麦克风」 |
//  | 麦克风那颗 | `mic.fill` 常态色 | `mic.slash.fill` **红色** |
//  🔴 静音时三点是**透明**而不是"从布局里拿掉"：留着占位，两行字的上下位置才不会跳。
//
//  ## 这颗视图不碰业务
//  它只读 `MacVoiceCallModel`、只调它的方法。**没有一处**直接摸
//  `VoiceInputManager` / `AISpeechReader` / `ChatModel` —— 那些全在模型里
//  （窗口关掉时要在模型里成对收干净，散在视图里必然漏一条）。
//

import SwiftUI
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

struct MacVoiceCallView: View {

    /// 通话状态机。
    /// ⚠️ `@ObservedObject`（不是 `@StateObject`）：**它由窗口中心持有并注入**，
    ///    视图只是观察者 —— 用 `@StateObject` 会变成"视图自己造一份"，
    ///    而窗口关掉时要收尾的正是中心那一份（两份 = 麦克风收不干净）。
    @ObservedObject var model: MacVoiceCallModel

    /// 点「挂断」那颗：**关窗**。
    /// 🔴 传进来的是"关窗"而不是"收尾"：收尾只有一条路（`MacVoiceCallWindow.close()`），
    ///    这里自己收的话，走 ⌘W 的用户麦克风会一直开着（见窗口那份文件头）。
    let onHangUp: () -> Void

    var body: some View {
        ZStack {
            // 深空星空底（`MacStarrySkyView`）—— 2026-10-12 起取代原来的不透明卡片底。
            // ⚠️ 它是**恒深**的 ⇒ 本页所有前景色也恒取亮色（口径见 `MacVoiceCallTheme` 配色段）。
            MacStarrySkyView()

            content
        }
    }

    /// 内容层：**球在舞台正中**，三点 / 两行字 / 两颗钮依次往下。
    ///
    /// ## 为什么用 `GeometryReader` 算位置（2026-10-27 第二版）
    /// 用户：「白球位置要居中」。上一版是"球 overlay 挂在三点上方"，球心落在 26% 处，
    /// 下面是**一大片空**（球 110 / 文字 230 / 钮 385）—— 那是被否掉的形态。
    ///
    /// 现在的口径：**"舞台" = 内容区减去底部那条固定高度的控制条**（`buttonHitSize` +
    /// `buttonRowBottomInset` = 70pt），球心钉在**舞台的垂直中心**（420 高的窗口里 = 175pt）。
    ///
    /// ⚠️ 为什么不钉在"内容区的几何中心"（210pt）：球(100) + 间隙(18) + 三点(26) +
    ///    间距(22) + 两行字(≈39) 一共 205pt，钉在 210 会让**提示语压进按钮的命中区**
    ///    （实测只差 3pt，字与钮会粘在一起）。舞台上沿对齐内容区上沿 ⇒ 175 才是
    ///    这一页"看着正中"的那条线。
    /// 🔴 纵向位置**由容器高度算出**，⛔ 别改成写死的数字 / 屏幕比例：
    ///    窗口尺寸只有一个出处（`MacVoiceCallTheme.contentSize`），写死就会两处漂。
    private var content: some View {
        GeometryReader { geo in
            let stage = max(0, geo.size.height
                               - MacVoiceCallTheme.buttonHitSize
                               - MacVoiceCallTheme.buttonRowBottomInset)
            ZStack(alignment: .top) {
                // ① 球：横向由 `frame(maxWidth:)` 居中，纵向让**盒子中心**落在舞台中心。
                //    ⚠️ 减的是**盒子**（直径 + 两侧柔光），不是直径 —— 柔光是画在球体之外的，
                //    按直径算会让球整体矮 22pt（`MacVoiceCallBallView` 的 frame 就是盒子）。
                ballLayer
                    .frame(maxWidth: .infinity)
                    .padding(.top, stage / 2 - MacVoiceCallTheme.ballBoxSide / 2)

                // ② 三点 → 两行字 → 底部两颗钮
                VStack(spacing: 0) {
                    // 这段空白 = 「球心 → 球下沿（直径的一半）→ 间隙」，把三点顶到球的正下方。
                    // ⚠️ 它跟上面那颗球是**两个独立图层**：球不在这条 VStack 里 ⇒
                    //    三点 / 文字的度量变化（字号、静音副行）**不会**把球挤走。
                    Color.clear
                        .frame(height: stage / 2
                                        + MacVoiceCallTheme.ballDiameter / 2
                                        + MacVoiceCallTheme.ballToDots)

                    dotsRow

                    statusBlock
                        .padding(.top, MacVoiceCallTheme.statusTopSpacing)

                    Spacer(minLength: 0)

                    buttonRow
                        .padding(.bottom, MacVoiceCallTheme.buttonRowBottomInset)
                }
            }
        }
    }

    // MARK: - 中央那颗白球

    /// 白球（2026-10-27 加；同日第二版改成**正中**）。
    ///
    /// ⚠️ 它不参与下面那条 `VStack` 的布局：那条 VStack 里的 `Color.clear` 是**按同一个
    ///    公式**算出来的空白，两处口径来自同一批主题常量（`ballDiameter` / `ballToDots`），
    ///    改一个必须看另一个。
    /// 🧪 验收钩子：`STARRY_CALL_BALL=0/1` 把振幅钉在两端（见 `MacVoiceCallModel`）。
    private var ballLayer: some View {
        MacVoiceCallBallView(isVoiceActive: model.isVoiceActive,
                             forcedLevel: model.forcedBallLevel)
    }

    // MARK: - 三个点

    /// 三个点（音量指示）。静音时**透明但留位**：参考图第 2 张里没有三点，
    /// 但从布局里拿掉的话，下面两行字会整块往上跳一下。
    private var dotsRow: some View {
        MacVoiceCallDotsView(level: model.level, isActive: model.isDotsActive)
            .opacity(model.isMuted ? 0 : 1)
    }

    // MARK: - 中间那两行字

    /// 状态行 +（静音态才有的）副行。
    ///
    /// 🔴 **两行都要恒占位**（第二行用空串 + `opacity(0)`）：只让它在静音时出现的话，
    ///    整块文字会在两态之间上下跳，而且三点也跟着动 —— 那是本页最容易被看成"闪一下"的地方。
    private var statusBlock: some View {
        VStack(spacing: MacVoiceCallTheme.hintTopSpacing) {
            Text(model.notice ?? model.statusText)
                .font(MacTheme.ui(MacVoiceCallTheme.statusFontSize))
                .foregroundStyle(model.notice == nil ? MacVoiceCallTheme.statusText
                                                      : MacVoiceCallTheme.hangUp)
                // ⚠️ 单行 + **截头**不截尾：这一行在拾音时会临时变成实时字幕
                //   （用户说的整句都灌进来），而要看的是**刚说出来的那几个字**。
                //    与 iOS 通话页那条口径逐字相同。
                .lineLimit(1)
                .truncationMode(.head)

            Text(model.hintText ?? " ")
                .font(MacTheme.ui(MacVoiceCallTheme.hintFontSize))
                .foregroundStyle(MacVoiceCallTheme.hintText)
                .lineLimit(1)
                .opacity(model.hintText == nil ? 0 : 1)
        }
        // 字幕再长也不撑破窗口（一行 + 截断之外再加一道保险）
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 底部那一排

    /// 底部那一排：**两颗**（2026-10-27 第二版）。
    ///
    /// 用户口径：「底部四个按钮**去掉前面俩个**」⇒ 删掉的是
    /// ① 视频（本来就没做、只是个灰摆设）和 ② 消息（把会话窗提到前面）。
    /// ⚠️ 剩下的两颗是**麦克风 · 挂断**，顺序与参考图一致（左右对称摆）；
    ///    用户若想再调位置（比如挂断挪到正中），改的是 `buttonRow` 里的顺序 / `buttonSpacing`。
    private var buttonRow: some View {
        HStack(spacing: MacVoiceCallTheme.buttonSpacing) {
            // ① 麦克风：**我的麦**开 / 关（静音态 = 红色斜杠）
            iconButton(symbol: model.isMuted ? "mic.slash.fill" : "mic.fill",
                       tint: model.isMuted ? MacVoiceCallTheme.mutedIcon : MacVoiceCallTheme.icon,
                       help: model.isMuted ? L("打开麦克风") : L("静音（不再拾音）"),
                       action: model.toggleMic)

            // ② 挂断：关窗（收尾在窗口的 `close()` 里，见文件头）
            iconButton(symbol: "phone.down.fill",
                       tint: MacVoiceCallTheme.hangUp,
                       help: L("挂断"),
                       action: onHangUp)
        }
    }

    /// 一颗圆钮。
    ///
    /// 🔴 命中区（`buttonHitSize`）**必须大于图标**：21pt 的图标直接当命中区，
    ///    鼠标要点得很准 —— 参考图上那几颗的间距明显是按"能点得着"留的。
    /// ⚠️ `.contentShape(Circle())`：`.buttonStyle(.plain)` 下没有它，命中区会退化成
    ///    图标本身的**绘制边界**（细长图标旁边那圈是点不着的）。
    /// ℹ️ 2026-10-27 去掉了 `disabled:` 参数：唯一用它的"视频"那颗已被用户删掉，
    ///    留着一个没有调用点的开关就是死代码。
    private func iconButton(symbol: String,
                            tint: Color,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(MacTheme.ui(MacVoiceCallTheme.buttonIconSize))
                .foregroundStyle(tint)
                .frame(width: MacVoiceCallTheme.buttonHitSize,
                       height: MacVoiceCallTheme.buttonHitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
