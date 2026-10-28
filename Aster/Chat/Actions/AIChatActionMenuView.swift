//
//  AIChatActionMenuView.swift
//  AIModule
//
//  点击消息 cell 弹出的操作卡（豆包/微信式自定义气泡菜单）：
//  圆角卡片 + 指向点击位置的小箭头；内容分两段——
//  首行横排 `gridCount` 个选项（icon 在上 + title 在下，等宽），其后选项各占一整行竖排（icon 左 + title 右）；
//  ⚠️ 两段的分界由调用方**显式传入**（`gridCount:`），这里不写死 3 —— 竖排第一项是谁是产品指定的事
//  （本工程要求「选取文字」永远第一个），写死格子数会让它随集合大小滑动；
//  弹出时全屏罩一层黑色半透明背景（点击背景即收起）。
//  替代 UIMenuController / UIContextMenu / UIEditMenuInteraction。
//  定位策略：以用户实际点击位置为锚弹出——优先弹在点击点下方，空间不足自动翻到上方；
//  箭头尖端对准点击点（点击点贴屏边时自动夹紧，卡片主体始终保持在屏幕内）。
//
//  说明：选项不用 UIButton 的 image+title 组合（insets 布局不可控），改为
//  icon(UIImageView) + title(UILabel) 在按钮上按 frame 手排，间距精确；
//  点按反馈用按钮背景色变化（微信式整行灰底）。
//

import UIKit

/// 操作卡菜单
final class AIChatActionMenuView: UIView {

    /// 单行/单元配置
    struct Item {
        let icon: String   // SF Symbol 名
        let title: String
        /// 破坏性动作（当前只有「删除」）：icon 与 title 都画成红色。
        /// 卡片没有别的「危险色」机制，这是**唯一**的视觉警示来源。
        var isDestructive: Bool = false
    }

    /// 首行横排的选项个数（= 调用方 `grid` 段的长度；`0` = 没有横排）
    private let gridCount: Int

    /// 单行视图：整行按钮 + 手排的 icon/title
    private final class RowView {
        let button = UIButton(type: .system)
        let iconView = UIImageView()
        let label = UILabel()
        let isGrid: Bool

        init(item: Item, isGrid: Bool) {
            self.isGrid = isGrid
            iconView.image = UIImage(systemName: item.icon)
            // 破坏性项整条画红（icon + title 一起）—— 只红一个会看着像渲染错了
            iconView.tintColor = item.isDestructive ? .systemRed : .label
            iconView.contentMode = .scaleAspectFit
            label.text = item.title
            // 首行单元是「icon 上 title 下」的紧凑布局，标题用 13pt；竖排整行保持 15pt
            label.font = .systemFont(ofSize: isGrid ? 13 : 15)
            label.textColor = item.isDestructive ? .systemRed : .label
            button.addSubview(iconView)
            button.addSubview(label)
            button.setTitle(nil, for: .normal)
        }
    }

    private let items: [Item]
    private let onTap: (Int) -> Void
    private var rows: [RowView] = []

    /// 全屏遮罩：点击非菜单区域关闭
    private let dimmingControl = UIControl()

    /// 动画容器：承载箭头 + 卡片，缩放淡入以箭头尖端为锚点
    private let popContainer = UIView()

    /// 卡片背景（带圆角与阴影）
    private let cardView = UIView()

    /// 内容裁剪层（行高亮被圆角裁剪，不遮挡卡片阴影）
    private let clipBody = UIView()

    /// 指向气泡的箭头
    private let arrowLayer = CAShapeLayer()

    /// 分隔线
    private var separatorLines: [UIView] = []

    // MARK: - 几何常量

    private let cardWidth: CGFloat = 228
    private let rowHeight: CGFloat = 44
    private let arrowHeight: CGFloat = 8
    private let cornerRadius: CGFloat = 14
    private let gap: CGFloat = 4            // 箭头尖端与气泡之间的呼吸间距
    private let edgeMargin: CGFloat = 10    // 卡片距屏幕边缘最小间距
    private let gridIconTitleGap: CGFloat = 3   // 首行单元 icon 与下方 title 的间距
    private let gridIconSide: CGFloat = 20      // 首行单元 icon 的显示边长（scaleAspectFit 内框）
    private let listIconTitleGap: CGFloat = 8   // 竖排整行 icon/title 间距
    private let listLeading: CGFloat = 16        // 竖排整行内容左边距
    private let dimmingAlpha: CGFloat = 0.2     // 全屏遮罩（黑色半透明背景）不透明度

    // MARK: - 初始化

    /// - Parameters:
    ///   - items: **按显示顺序**（横排在前、竖排在后）；`onTap` 回调的下标就是它在 `items` 里的下标
    ///   - gridCount: 前几项进首行横排，余下的各占一整行竖排（夹紧到 `0...items.count`）
    init(items: [Item], gridCount: Int, onTap: @escaping (Int) -> Void) {
        self.items = items
        self.gridCount = max(0, min(gridCount, items.count))
        self.onTap = onTap
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        // 遮罩：全屏黑色半透明背景（点击非菜单区域关闭）
        dimmingControl.backgroundColor = UIColor.black.withAlphaComponent(dimmingAlpha)
        dimmingControl.alpha = 0   // 展示时随菜单淡入
        dimmingControl.addTarget(self, action: #selector(dimmingTapped), for: .touchUpInside)
        addSubview(dimmingControl)

        addSubview(popContainer)

        // 卡片：底色 + 圆角 + 阴影
        cardView.backgroundColor = .systemBackground
        cardView.layer.cornerRadius = cornerRadius
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.15
        cardView.layer.shadowRadius = 12
        cardView.layer.shadowOffset = CGSize(width: 0, height: 4)
        popContainer.addSubview(cardView)

        // 内容裁剪层：行按钮装在这里，按压高亮会被圆角裁掉
        clipBody.backgroundColor = .clear
        clipBody.layer.cornerRadius = cornerRadius
        clipBody.layer.masksToBounds = true
        popContainer.addSubview(clipBody)

        // 行按钮：首行横排 gridCount 个，其余各占一整行
        for (i, item) in items.enumerated() {
            let row = RowView(item: item, isGrid: i < gridCount)
            row.button.tag = i
            row.button.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            row.button.addTarget(self, action: #selector(pressIn(_:)), for: .touchDown)
            row.button.addTarget(self, action: #selector(pressOut(_:)),
                                 for: [.touchUpInside, .touchUpOutside, .touchCancel])
            rows.append(row)
            clipBody.addSubview(row.button)
        }

        // 箭头（颜色与卡片一致，指向被点气泡）
        arrowLayer.fillColor = UIColor.systemBackground.cgColor
        popContainer.layer.addSublayer(arrowLayer)
    }

    // MARK: - 展示

    /// 在容器内弹出；anchorPoint 为「用户点击位置」在 container 坐标系中的坐标。
    /// 卡片以点击点为锚弹出（优先弹在点击点下方，空间不足翻到上方），箭头尖端尽量对准点击点。
    func show(in container: UIView, anchorPoint: CGPoint) {
        container.addSubview(self)
        frame = container.bounds
        dimmingControl.frame = bounds

        // 行数 = 横排首行（可能没有）+ 竖排整行数
        let totalRows = totalRowCount()
        let menuH = CGFloat(totalRows) * rowHeight
        let popW = cardWidth
        let popH = menuH + arrowHeight

        // 布局卡片内部：横排首行在上，竖排整行依次往下
        layoutRows(menuH: menuH, popW: popW)

        let containerW = bounds.width
        let containerH = bounds.height
        // 卡片主体距屏幕上下边缘的最小间距
        let vMargin = edgeMargin + 4

        // 垂直：点击点下方空间足够 → 弹在下方（箭头尖贴点击点）；否则翻到上方
        let belowOK = containerH - anchorPoint.y >= popH + gap + vMargin
        let aboveOK = anchorPoint.y >= popH + gap + vMargin
        let showsBelow = belowOK || (!aboveOK && (containerH - anchorPoint.y) >= anchorPoint.y)

        var cardY: CGFloat
        if showsBelow {
            let arrowTipY = anchorPoint.y + gap
            cardY = arrowTipY + arrowHeight
            // 兜底：卡片底部不超出屏幕
            cardY = min(cardY, containerH - vMargin - menuH)
        } else {
            let arrowTipY = anchorPoint.y - gap
            cardY = arrowTipY - arrowHeight - menuH
            // 兜底：卡片顶部不低于屏幕顶
            cardY = max(cardY, vMargin)
        }

        // 水平：卡片中心尽量对齐点击点，夹紧在屏幕内
        var cardX = anchorPoint.x - popW / 2
        cardX = max(edgeMargin, min(cardX, containerW - edgeMargin - popW))

        // 缩放淡入的锚点需在最终 frame 上计算，先粗排一次确定箭头尖端 x
        popContainer.frame = CGRect(x: cardX, y: showsBelow ? anchorPoint.y + gap : cardY,
                                    width: popW, height: popH)
        let arrowTipX = min(max(anchorPoint.x - cardX, 16), popW - 16)

        // 卡片与裁剪层：箭头在卡片上方时卡 y=arrowH，否则卡 y=0
        let cardInPopY = showsBelow ? arrowHeight : 0
        let cardRect = CGRect(x: 0, y: cardInPopY, width: popW, height: menuH)
        cardView.frame = cardRect
        cardView.layer.shadowPath = UIBezierPath(roundedRect: cardRect, cornerRadius: cornerRadius).cgPath
        clipBody.frame = cardRect

        // 箭头：尖端对准点击点（夹紧在卡片区域内）
        let arrowPath = UIBezierPath()
        let baseY = showsBelow ? arrowHeight : popH - arrowHeight
        let tipY = showsBelow ? 0 : popH
        arrowPath.move(to: CGPoint(x: arrowTipX, y: tipY))
        arrowPath.addLine(to: CGPoint(x: arrowTipX - arrowHeight * 0.875, y: baseY))
        arrowPath.addLine(to: CGPoint(x: arrowTipX + arrowHeight * 0.875, y: baseY))
        arrowPath.close()
        arrowLayer.path = arrowPath.cgPath

        // 以箭头尖端为锚点缩放淡入（从点击位置生长）
        popContainer.layer.anchorPoint = CGPoint(x: arrowTipX / popW, y: (showsBelow ? 0 : 1))
        popContainer.frame = CGRect(x: cardX, y: showsBelow ? anchorPoint.y + gap : cardY,
                                    width: popW, height: popH)

        popContainer.alpha = 0
        popContainer.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            self.dimmingControl.alpha = 1
            self.popContainer.alpha = 1
            self.popContainer.transform = .identity
        }
    }

    /// 按「首行横排（icon 上 title 下）+ 其余整行（icon 左 title 右）」排布按钮、内容与分隔线
    private func layoutRows(menuH: CGFloat, popW: CGFloat) {
        // 横排等分卡片宽度（`gridCount == 0` 时这个值没人用，`max` 只为不除零）
        let gridRowWidth = popW / CGFloat(max(gridCount, 1))
        // 竖排起始 y：有横排就让出 1 行，没有就从卡片顶部开始
        let listStartY = gridCount > 0 ? rowHeight : 0

        for (i, row) in rows.enumerated() {
            if i < gridCount {
                // 首行横排单元：等宽
                row.button.frame = CGRect(x: CGFloat(i) * gridRowWidth, y: 0,
                                          width: gridRowWidth, height: rowHeight)
            } else {
                // 竖排整行：从横排之下依次排
                let listIndex = i - gridCount
                row.button.frame = CGRect(x: 0, y: listStartY + CGFloat(listIndex) * rowHeight,
                                          width: popW, height: rowHeight)
            }
            layoutContent(of: row)
        }

        // 分隔线：每行边界（跳过首行顶边），覆盖横排底与各整行底
        separatorLines.forEach { $0.removeFromSuperview() }
        separatorLines.removeAll()
        if totalRowCount() > 1 {
            for rowIndex in 1..<totalRowCount() {
                let y = CGFloat(rowIndex) * rowHeight
                let line = UIView()
                line.backgroundColor = .separator
                clipBody.addSubview(line)
                line.frame = CGRect(x: 12, y: y, width: popW - 24, height: 0.5)
                separatorLines.append(line)
            }
        }
    }

    /// 卡片里的行数：横排占 1 行（可能没有），竖排各项各占一行
    private func totalRowCount() -> Int {
        (gridCount > 0 ? 1 : 0) + max(0, items.count - gridCount)
    }

    /// 在按钮内排 icon 与 title：
    /// - 首行单元（isGrid）：icon 上、title 下，整组水平/垂直居中
    /// - 竖排整行：icon 左、title 右，左对齐 listLeading
    private func layoutContent(of row: RowView) {
        let button = row.button
        let icon = row.iconView
        let label = row.label
        let contentW = button.bounds.width

        if row.isGrid {
            label.sizeToFit()
            let labelH = label.bounds.height
            // 整组高 = icon 显示高 + 间距 + 标题高，垂直居中（高度不足时向下让 2pt）
            let groupH = gridIconSide + gridIconTitleGap + labelH
            let groupTop = max((rowHeight - groupH) / 2, 2)
            icon.frame = CGRect(x: (contentW - gridIconSide) / 2,
                                y: groupTop,
                                width: gridIconSide, height: gridIconSide)
            label.frame = CGRect(x: (contentW - label.bounds.width) / 2,
                                 y: groupTop + gridIconSide + gridIconTitleGap,
                                 width: label.bounds.width, height: labelH)
        } else {
            icon.sizeToFit()
            label.sizeToFit()
            let iconW = icon.bounds.width
            let iconH = icon.bounds.height
            let labelH = label.bounds.height
            icon.frame = CGRect(x: listLeading,
                                y: (rowHeight - iconH) / 2,
                                width: iconW, height: iconH)
            label.frame = CGRect(x: listLeading + iconW + listIconTitleGap,
                                 y: (rowHeight - labelH) / 2,
                                 width: label.bounds.width, height: labelH)
        }
    }

    // MARK: - 关闭与事件

    /// 收起（带动画）；无需动作时（点遮罩）调用
    func dismiss(animated: Bool = true) {
        let cleanup = { self.removeFromSuperview() }
        guard animated else { cleanup(); return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn], animations: {
            self.dimmingControl.alpha = 0
            self.popContainer.alpha = 0
            self.popContainer.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }, completion: { _ in cleanup() })
    }

    @objc private func dimmingTapped() {
        dismiss()
    }

    @objc private func rowTapped(_ sender: UIButton) {
        pressOut(sender)
        let index = sender.tag
        dismiss()
        // 等收起动画结束后再执行动作，避免 share 等 present 与收起动画冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self = self else { return }
            self.onTap(index)
        }
    }

    /// 按压：整行灰底（微信式反馈）
    @objc private func pressIn(_ sender: UIButton) {
        sender.backgroundColor = UIColor.systemGray5.withAlphaComponent(0.6)
    }

    @objc private func pressOut(_ sender: UIButton) {
        sender.backgroundColor = .clear
    }
}
