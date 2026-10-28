//
//  AIMentionBarView.swift
//  AIModule
//
//  输入**卡片内部**的「本轮 @ 到的项目资料」待发条（2026-10-21）。
//
//  ## 为什么单独一条、不并进附件条
//  两者在语义上是两件事：
//  - **附件**（`AIAttachmentBarView`）= 我这一轮**上传**的文件，会变成对话里的一行，对外可见；
//  - **@ 资料** = 我给这一轮**补的参考资料**，来自项目里已有的文件，**不会**多出一行消息。
//  并成一条的话，用户会把「@ 的那份」误认为「已经发出去了」，而它只是这轮的上下文。
//  ⚠️ 形态上刻意做得比附件条**矮一档**（44 vs 72）：它更接近「一行提示」而不是「一堆卡片」。
//
//  ## 与 Mac 的同构
//  Mac 那边是 `ComposerMentionBar`（SwiftUI 一行 HStack），语义完全一致：
//  位置都在**引用条 / 附件条之后、输入框之前**。⛔ 别一端放上面一端放下面。
//
//  ## 高度口径
//  `barHeight` 是**唯一**高度来源，`InputToolbar.cardContentHeight()` 直接读它 ——
//  同 `AIAttachmentBarView.barHeight` 的分工。⛔ 别让这个视图自己按内容算高度：
//  输入栏是 frame 布局、按底部锚点向上长，高度必须在 `cardContentHeight()` 里算完。
//

import UIKit
import SnapKit
import AICore

final class AIMentionBarView: UIView {

    /// 整条高度（含上下 padding）。`InputToolbar` 拿它当卡片内部的一段内容高。
    static let barHeight: CGFloat = 44

    private enum Metrics {
        static let padding: CGFloat = 8
        /// 胶囊高度：比附件条的 56 矮一档，但仍够点（删除钮单独垫了命中区）
        static let pillHeight: CGFloat = 28
        static let spacing: CGFloat = 8
        static let nameMaxWidth: CGFloat = 150
        static let deleteSide: CGFloat = 22
        static let corner: CGFloat = 14
    }

    /// 点某个 chip 的删除按钮。**回调下标**（基于当前 items）——
    /// 数据由调用方（VC）持有，这里只负责「第几个被点了」。
    var onRemove: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private(set) var items: [AIMention] = []

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

        // ⚠️ 全部 999：本视图是 frame 布局，上屏前高/宽都是 0（同 `AIAttachmentBarView` 的注释）
        scrollView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(Metrics.padding).priority(999)
            make.bottom.equalToSuperview().offset(-Metrics.padding).priority(999)
            // 左右内缩与附件条一致（卡片内缘就是描边内侧，贴上去等于压着描边）
            make.leading.equalToSuperview().offset(Metrics.padding).priority(999)
            make.trailing.equalToSuperview().offset(-Metrics.padding).priority(999)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.height.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 数据

    /// 重设待发资料。空数组等于「收起这一条」（由宿主把高度收回）。
    func setItems(_ items: [AIMention]) {
        guard items != self.items else { return }
        self.items = items
        rebuild()
    }

    // MARK: - 重画

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, mention) in items.enumerated() {
            stack.addArrangedSubview(makePill(mention, index: index))
        }
    }

    private func makePill(_ mention: AIMention, index: Int) -> UIView {
        let pill = UIView()
        pill.backgroundColor = .secondarySystemFill
        pill.layer.cornerRadius = Metrics.corner
        // ⚠️ 圆角与子视图一起裁：否则片头那个 `@` 会顶到圆角外面
        pill.layer.masksToBounds = true

        let icon = UILabel()
        icon.text = "@"
        // 用它替代 SF Symbol：`at` 这个符号在 iOS 15 上是有的，但字号基线各版本略有差异，
        // 直接画一个等宽字符最稳（也与输入框里那串 `@名字` 长得一样）
        icon.font = .systemFont(ofSize: 13, weight: .semibold)
        icon.textColor = .tertiaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let name = UILabel()
        name.text = mention.displayName
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .label
        // 长文件名**末尾截断**（`@` 与删除钮是固定两端，中间那份名字才是可牺牲的）
        name.lineBreakMode = .byTruncatingMiddle
        name.numberOfLines = 1

        let size = UILabel()
        size.text = mention.sizeText
        size.font = .systemFont(ofSize: 11)
        size.textColor = .secondaryLabel
        size.setContentHuggingPriority(.required, for: .horizontal)
        size.setContentCompressionResistancePriority(.required, for: .horizontal)

        let remove = UIButton(type: .custom)
        remove.setImage(UIImage(systemName: "xmark"), for: .normal)
        remove.tintColor = .secondaryLabel
        remove.tag = index
        remove.addTarget(self, action: #selector(removeTapped(_:)), for: .touchUpInside)
        // 图标只有 14pt，垫到 22 才够点（同账号栏齿轮那条口径）
        remove.snp.makeConstraints { make in
            make.width.height.equalTo(Metrics.deleteSide)
        }
        // 🔴 命中区跟着 label 走（Button 的命中区就是 label 边界），所以图标小一点没关系，
        //    外面那圈 22 是它的实际可点范围

        let row = UIStackView(arrangedSubviews: [icon, name, size, remove])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        pill.addSubview(row)
        row.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.trailing.equalToSuperview().offset(-4)
            make.centerY.equalToSuperview()
        }
        pill.snp.makeConstraints { make in
            make.height.equalTo(Metrics.pillHeight)
        }
        name.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(Metrics.nameMaxWidth)
        }
        return pill
    }

    @objc private func removeTapped(_ sender: UIButton) {
        onRemove?(sender.tag)
    }
}
