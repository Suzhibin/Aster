import UIKit
import SnapKit
import AICore

/// 助手回复下方的横排操作栏（**内容以 `AIRowAction.barActions` 为准**，别在这里列举 ——
/// 每次增删按钮都要同步两处的话迟早漂移）。
///
/// 只负责「长什么样 + 点了哪一项」；**是否显示由 `AIChatRow.showsActionBar` 决定**
/// （判定在 `AIChatManager`：当前会话最后一条已结束的文本回复才挂栏）。
///
/// ⚠️ 这里曾经在右侧挂过一条「本会话累计 token」文案（2026-09-17 删除）：聊天页不显示任何
/// 用量数字。要恢复的话，模型侧还留着 `AIUsageTotal.shortText`，接线即可 —— 但**别只加回视图**，
/// 栏宽与 cell 里那几条约束当初是为它调过的（见当日日志 / git 记录）。
///
/// ⚠️ 高度必须取 `AIChatRow.actionBarHeight` —— 行高量算与这里显示同源，
/// 写死数字迟早对不上（量的时候没算栏、显示时多了栏 → 气泡被挤变形）。
/// 这里的等式是：`AIChatRow.actionBarHeight == topPadding + chipSize`（当前 35 = 5 + 30），
/// 改动任一项都要同步，否则不是底被裁、就是末行被裁。
final class AIActionBarView: UIView {

    /// 点击某一项
    var onTap: ((AIRowAction) -> Void)?

    /// 本栏显示的动作。**必须用 `barActions` 而不是 `allCases`**：
    /// `allCases` 里还有「喜欢 / 不喜欢 / 选取文字 / 重试」—— 前两个已**从所有入口移除**（2026-09-18），
    /// 后两个只在长按操作卡里出现；按它建按钮会多出 4 颗（156pt → 324pt，右边被裁出屏幕）。
    private let actions = AIRowAction.barActions

    private let stack = UIStackView()
    /// 与 `actions` 一一对应（`setSpeaking` 要靠下标回查那一颗）
    private var buttons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        // 4 个：30×4 + 12×3 = 156pt（气泡左对齐 12、栏右侧再留 12 → 375pt 屏放得下）
        stack.spacing = Self.chipSpacing
        stack.alignment = .center
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            // 顶部留白撑出「与上方气泡的距离」（栏高已含这段留白，故这里不能用 centerY）
            make.top.equalToSuperview().offset(Self.topPadding)
        }

        for (index, action) in actions.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(Self.icon(named: action.icon), for: .normal)
            button.tintColor = Self.iconColor
            button.backgroundColor = Self.chipBackground
            // 圆角半径：想要正圆就写 chipSize / 2
            button.layer.cornerRadius = 6
            button.clipsToBounds = true
            // ⚠️ tag 是**在 `actions` 里的下标**，不是 `rawValue`：
            // 两者目前恰好同序，但它们没有约束关系（`barActions` 是子集），
            // 用下标才不会在有人调整 case 顺序时点「复制」执行了「分享」
            button.tag = index
            button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            button.snp.makeConstraints { make in
                make.width.height.equalTo(Self.chipSize)
            }
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard sender.tag < actions.count else { return }
        onTap?(actions[sender.tag])
    }

    /// 本行是否正在朗读。**只换 `.speak` 那一颗的图标**（未读 `speaker.wave.2` / 播放中 `stop.circle`），
    /// 图标变化不影响高度，因此不需要重算行高。
    func setSpeaking(_ speaking: Bool) {
        guard let index = actions.firstIndex(of: .speak), index < buttons.count else { return }
        let action = actions[index]
        let name = speaking ? action.activeIcon : action.icon
        buttons[index].setImage(Self.icon(named: name), for: .normal)
    }

    // MARK: - 尺寸与配色（高度口径见文件头等式，改这里请同步核对 `AIChatRow.actionBarHeight`）

    /// 按钮底色块的边长
    private static let chipSize: CGFloat = 30

    /// 顶部留白：按钮底与上方气泡之间的距离。
    /// **由栏高反推**而不是写死数字 —— 这样改 `chipSize` 或 `AIChatRow.actionBarHeight`
    /// 都不会让底被裁（栏高不够）或让末行被裁（行高算少了）。
    private static var topPadding: CGFloat { max(0, AIChatRow.actionBarHeight - chipSize) }

    /// 底块间距
    private static let chipSpacing: CGFloat = 12

    /// 图标字号：比底块小一圈，四周留出呼吸（默认 17pt 会顶到边）
    private static let iconPointSize: CGFloat = 15

    /// 图标配置（`setSpeaking` 换图时也要带上，否则播放态图标会跳回 17pt 大小）
    private static let symbolConfig = UIImage.SymbolConfiguration(pointSize: iconPointSize,
                                                                  weight: .regular)

    private static func icon(named name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: symbolConfig)
    }

    /// 图标色：系统蓝。
    /// 操作栏挂在 cell 的 contentView 上（背景 `.systemBackground`，**跟暗黑模式变**），
    /// 与气泡内的固定浅底不同，所以这里必须用动态色 —— 写死的蓝在暗色下会偏暗发闷。
    private static let iconColor = UIColor.systemBlue

    /// 底块色：淡蓝。先用 `resolvedColor(with:)` 把动态色解成当前主题的实色再降透明度
    /// （`withAlphaComponent` 直接作用在动态色上，其解析行为在暗色下不保证符合预期）；
    /// 暗色下背景本身变深，透明度要抬高一点才看得出底色。
    private static let chipBackground: UIColor = UIColor { trait in
        let alpha: CGFloat = trait.userInterfaceStyle == .dark ? 0.28 : 0.12
        return UIColor.systemBlue.resolvedColor(with: trait).withAlphaComponent(alpha)
    }
}
