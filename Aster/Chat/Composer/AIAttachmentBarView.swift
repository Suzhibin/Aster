//
//  AIAttachmentBarView.swift
//  AIModule
//
//  输入**卡片内部**的「待发附件」预览条：横向滚动的 chip 列表，每项可单独删除。
//
//  2026-10-08 起它住在带描边的输入**卡片里面**（卡片最上方、输入框之上）。
//  用户原话「图片的位置需要放在底部输入框，也就是描边内」⇒ 与 Mac 端输入卡片同构。
//  之前它在卡片**外面**（卡片上方、状态条下面），看着像另起一条。
//
//  为什么做进 `InputToolbar` 内部而不是在 VC 里另浮一层：
//  输入栏是 frame 布局且高度由 `heightThatFits()` 统一算出（要跟着键盘走），
//  预览条作为它的子视图，高度一加进 `cardContentHeight()`，键盘跟随 / 列表底部内边距
//  （`updateBottomOccupancy` 读的是输入栏 frame）就全部自动正确。
//  在外面另起一层的话，得再造一套「跟随输入栏 y」的同步逻辑。
//

import UIKit
import SnapKit
import AICore

final class AIAttachmentBarView: UIView {

    /// 整条高度（含上下 padding）。`InputToolbar` 直接拿它当卡片内部的一段内容高。
    ///
    /// 🔴 2026-10-08 起它是**输入卡片内部**的一段（不再在卡片外面），
    ///    口径与它的高度都由 `InputToolbar.cardContentHeight()` 那一处统一算。
    static let barHeight: CGFloat = 72

    private enum Metrics {
        static let padding: CGFloat = 8
        static let itemSide: CGFloat = 56
        static let spacing: CGFloat = 8
        static let fileItemWidth: CGFloat = 148
        static let corner: CGFloat = 8
        static let deleteSide: CGFloat = 20
    }

    /// 点某个 chip 的删除按钮。**回调的是下标**（基于当前 items）——
    /// 数据由调用方（VC）持有，这里只负责「第几个被点了」。
    var onRemove: ((Int) -> Void)?

    /// 点末尾那颗「＋」（继续加附件）。
    ///
    /// 🔴 **不带下标**：它不是某一项的操作，宿主收到后自己去弹 picker
    /// （iOS 侧接 `presentPhotoPicker()` = 系统相册，见 `+InputToolbar`）。
    /// ⚠️ 也正因为它不在 `items` 的下标体系里，那条 `sender.tag` 驱动的删除路径**碰不到它**。
    var onAddMore: (() -> Void)?

    /// 附件数上限；达到上限就不再显示末尾那颗「＋」。
    ///
    /// ⚠️ 唯一真身在宿主（`AIModuleViewController.maxAttachmentCount` = 9）。
    /// 这里默认 `Int.max`＝不限，是**纯防御值** —— ⛔ 别让这个视图反过来给业务定规矩。
    ///
    /// 🔴 必须走 `setMaxCount(_:)` 而不是直接赋值：上限是在 `setItems` **之后**才被宿主传进来的
    ///    （`InputToolbar` 的 `didSet`），只赋值不重画的话，已经摆出来的加号不会被收掉。
    var maxCount: Int = .max
    func setMaxCount(_ value: Int) {
        guard value != maxCount else { return }
        maxCount = value
        if !items.isEmpty { rebuild() }
    }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private(set) var items: [AIAttachment] = []

    /// 🗑 **这里原来有一颗蓝色圆形「发送」按钮（`onSend`），2026-10-08 已删**。
    ///
    /// 删它的理由（用户原话：「那个发送按钮去掉，底部加号按钮在发送图片时切换为发送按钮状态」）：
    /// 附件条自己带一颗发送钮，等于输入栏有**两个**发送入口，而真正的主入口应该是
    /// 按钮行里那颗「＋」—— 它在**同一个位置**随「有附件 / 生成中 / 面板开合」换三种面孔
    /// （`InputToolbar` 的加号⇄停止⇄发送，见 `InputToolbar.refreshMoreButtonState`）。
    /// 两颗发送钮并排既占位置，又会让人分不清当前该按哪个。
    ///
    /// ⚠️ 这条约束有**验证点**：本文件**不得**再出现 `onSend` / `arrow.up` / `.systemBlue` 底色
    ///   （`typecheck_aster.sh` 之外的契约脚本按需复查）。

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Metrics.spacing
        scrollView.addSubview(stack)

        scrollView.snp.makeConstraints { make in
            // ⚠️ **上下这两条 padding 也只能是 999**（同 `AIAttachmentPanelView` / `AIComposerBannerView`）：
            // 本视图高度同样由宿主 frame 摆，init→上屏之间高是 **0**，引擎翻译成 `height == 0`（required）；
            // 而「上留 8 + 下留 8」在 required 下会让滚动区高 = **-16**，尺寸不能为负 → 无解。
            // 装不下时该牺牲的是留白，不是滚动区（实测被破坏的正是 `scroll.bottom`，差 16pt；
            // 若此时滚动区里已塞了 chip（56pt），引擎会优先保住「容纳内容」的那条链）。
            make.top.equalToSuperview().offset(Metrics.padding).priority(999)
            make.bottom.equalToSuperview().offset(-Metrics.padding).priority(999)
            // 🔴 2026-10-08：预览条搬进**卡片内部**后，chip 不能再贴着卡片左沿 ——
            // 卡片内缘就是描边内侧，贴上去等于「压着描边」。左右各内缩 8。
            // ⚠️ 左右这三条都保持 999（同上：本视图是 frame 布局，上屏前宽 0，required 的
            //    「右 -8」会让滚动区宽度为负 → 无解）。正常宽度下依然精确满足。
            make.leading.equalToSuperview().offset(Metrics.padding).priority(999)
            make.trailing.equalToSuperview().offset(-Metrics.padding).priority(999)
        }
        // 挂 scrollView 的子视图 → UIKit 会把约束解析成相对 contentLayoutGuide，
        // contentSize 随 stack 宽度自动撑开
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.height.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 数据

    /// 重设待发附件。空数组等于「收起这一条」（由 `InputToolbar` 把高度收回）。
    func setItems(_ items: [AIAttachment]) {
        self.items = items
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, item) in items.enumerated() {
            let chip = item.isImage ? makeImageChip(item, index: index) : makeFileChip(item, index: index)
            stack.addArrangedSubview(chip)
        }
        // 🔴 末尾那颗「＋」排在**所有 chip 之后**（用户原话：「图片的位置 后面增加加号按钮」）。
        //    它是横向列表的**最后一项**，所以图多了它必然在最右、要横滚才看得到 ——
        //    这是「跟在图后面」这个要求的必然结果，不是缺陷。
        //    达到上限就不摆它：留着只会让用户点了得到一句「最多带 N 个附件」。
        if items.count < maxCount {
            stack.addArrangedSubview(makeAddButton())
        }
        // 布局完再滚到**最右**（新加的那项在末尾）。
        // ⚠️ 2026-10-08 修正：原来这里滚 `.zero`（最左），与它自己那句注释
        //    「新加一项时用户最想看到的是新加的那个」正好相反 —— 新项永远在末尾，
        //    滚最左等于让用户看不到自己刚加的那张。末尾还有那颗「＋」，同理。
        //
        // 🔴 `viewport > 0` 这个钳制必须有：首次 `setItems` 常发生在**上屏之前**
        //    （输入栏要先算高度），那时 `scrollView.bounds.width` 还是 0 ——
        //    不钳的话 `stack.bounds.width - 0` 会算成一个很大的正偏移，等布局真上屏
        //    时滚动条已经被推到中段，**看起来像内容莫名其妙缺了一截**。
        layoutIfNeeded()
        let viewport = scrollView.bounds.width
        let maxX = viewport > 0 ? max(0, stack.bounds.width - viewport) : 0
        scrollView.setContentOffset(CGPoint(x: maxX, y: 0), animated: false)
    }

    // MARK: - chip

    /// 末尾那颗「＋」：**与图片 chip 同边长**（`Metrics.itemSide`，用户要求「和图片一样大」）。
    ///
    /// 外观用「浅灰底 + 圆角 + 灰色加号」而不是虚线描边：
    /// 虚线要自己画 `CAShapeLayer` 且要跟 `layoutSubviews` 同步，而这里的 chip 全是实心圆角块，
    /// 同族的外观才不像贴上去的零件。⛔ 别改成虚线。
    private func makeAddButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "plus"), for: .normal)
        button.tintColor = .secondaryLabel
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = Metrics.corner
        button.layer.masksToBounds = true
        button.accessibilityLabel = L("继续添加图片")
        button.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        button.snp.makeConstraints { make in
            make.width.height.equalTo(Metrics.itemSide)
        }
        return button
    }

    @objc private func addTapped() {
        onAddMore?()
    }

    private func makeImageChip(_ item: AIAttachment, index: Int) -> UIView {
        let chip = UIView()

        let thumb = UIImageView()
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = Metrics.corner
        thumb.backgroundColor = .tertiarySystemFill
        // 降采样读图：直接解整张 1600px 会白占内存，缩略图只要 56pt 的量
        thumb.image = AIAttachmentStorage.image(at: item.fileURL, maxPixelSize: Metrics.itemSide * 2)
        chip.addSubview(thumb)

        let delete = makeDeleteButton(index: index)
        chip.addSubview(delete)

        chip.snp.makeConstraints { make in
            make.width.height.equalTo(Metrics.itemSide)
        }
        thumb.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        placeDeleteButton(delete, in: chip)
        return chip
    }

    private func makeFileChip(_ item: AIAttachment, index: Int) -> UIView {
        let chip = UIView()
        chip.backgroundColor = .secondarySystemFill
        chip.layer.cornerRadius = Metrics.corner

        let icon = UIImageView(image: UIImage(systemName: "doc.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit

        let name = UILabel()
        name.text = item.displayName
        name.font = .systemFont(ofSize: 12)
        name.textColor = .label
        name.lineBreakMode = .byTruncatingMiddle   // 文件名尾巴是扩展名，保留它比保留前缀有用
        name.numberOfLines = 1

        let size = UILabel()
        size.text = item.sizeText
        size.font = .systemFont(ofSize: 10)
        size.textColor = .secondaryLabel

        let texts = UIStackView(arrangedSubviews: [name, size])
        texts.axis = .vertical
        texts.spacing = 2
        texts.alignment = .leading

        let delete = makeDeleteButton(index: index)

        chip.addSubview(icon)
        chip.addSubview(texts)
        chip.addSubview(delete)

        chip.snp.makeConstraints { make in
            make.width.equalTo(Metrics.fileItemWidth)
            make.height.equalTo(Metrics.itemSide)
        }
        icon.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(22)
        }
        texts.snp.makeConstraints { make in
            make.leading.equalTo(icon.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-10)
            make.centerY.equalToSuperview()
        }
        placeDeleteButton(delete, in: chip)
        return chip
    }

    private func makeDeleteButton(index: Int) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        // 深色圆底 + 白色叉：在浅色缩略图上也看得清
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = Metrics.deleteSide / 2
        button.tag = index
        button.addTarget(self, action: #selector(deleteTapped(_:)), for: .touchUpInside)
        return button
    }

    /// 删除按钮放 chip 右上角（**完全落在 chip 内**：chip 半外溢会被 scrollView 裁掉）
    private func placeDeleteButton(_ button: UIButton, in chip: UIView) {
        button.snp.makeConstraints { make in
            make.width.height.equalTo(Metrics.deleteSide)
            make.trailing.equalToSuperview().offset(-1)
            make.top.equalToSuperview().offset(-1)
        }
    }

    @objc private func deleteTapped(_ sender: UIButton) {
        let index = sender.tag
        guard items.indices.contains(index) else { return }
        onRemove?(index)
    }
}
