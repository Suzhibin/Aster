import UIKit
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

/// 「多选删除」选择模式下**顶替输入栏**的底部操作条（2026-09-18 产品要求）。
///
/// ## 为什么单独做一条、而不是把按钮留在导航栏
/// 删除是**不可逆**的动作，触发它的手指必须够得着 —— 顶部右上角是单手最难碰到的位置，
/// 而底部这块本来就是拇指区（输入栏平时就在这儿）。所以进入选择模式时：
/// **输入栏整条藏起来、这条顶上去**，用户看到的底部换了内容、位置一动没动。
///
/// ## 它与输入栏的关系：**同位置同高**（由宿主摆）
/// 宿主 `layoutSelectionToolbar()` 直接拿 `inputToolbar.frame` 当自己的 frame，
/// 于是列表底部内边距（`updateBottomOccupancy`）**一格都不用改** ——
/// 高度不一致的话，最后几条消息会被这条盖住（本工程踩过同类坑：底部占位的唯一口径）。
///
/// ## 为什么不用 `UIToolbar`
/// `UIToolbar` 自带一套 item 间距 / 安全区处理，想让它与输入栏**等高同位**还得反过来
/// 迁就它的尺寸；这里只有两颗按钮，自己摆 frame 反而最短。
/// ⚠️ 布局全在 `layoutSubviews` 里按 frame 手摆：**内容区必须排除底部安全区**
/// （`bounds.height - safeAreaInsets.bottom`），否则两颗按钮会被 Home 指示条顶上去。
final class AISelectionToolbar: UIView {

    /// 点「取消」= 退出选择模式，一条都不动
    var onCancel: (() -> Void)?
    /// 点「删除(N)」= 走二次确认再删
    var onDelete: (() -> Void)?

    private let topLine = UIView()
    private let cancelButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    /// 两侧边距（与输入栏的 `configure.horizontalMargin` 同值 —— 视觉上两颗按钮与
    /// 平时的相机 / 加号对齐）
    private static let horizontalMargin: CGFloat = 16
    /// 按钮热区高度（44 = 最小可点尺寸；这一条整体才 6x pt，别再压）
    private static let buttonHeight: CGFloat = 44
    /// 文字左右的额外留白：让热区比文字宽一点，别贴着边
    private static let titlePadding: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        // 输入栏顶部那条发丝线是它自己的子视图，输入栏一藏就跟着没了 —— 这里自带一条同款
        topLine.backgroundColor = .separator
        addSubview(topLine)

        cancelButton.setTitle(L("取消"), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.setTitleColor(.label, for: .normal)
        cancelButton.accessibilityLabel = L("取消选择")
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(cancelButton)

        // 危险动作画红（与长按操作卡里那一项、以及删除确认框的 destructive 同一个色系）
        deleteButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        deleteButton.setTitleColor(.systemRed, for: .normal)
        // 一条都没勾时是 `.system` 按钮的默认置灰（半透明）—— 再压一档，让「点不动」更明确
        deleteButton.setTitleColor(.tertiaryLabel, for: .disabled)
        deleteButton.accessibilityLabel = L("删除选中的消息")
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        addSubview(deleteButton)

        setSelectedCount(0)
    }

    // ⚠️ 不能写 `public`：本类是 internal，初始化器的访问级别不能高于它所在的类型
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按勾选条数刷新「删除(N)」的标题与可用性（`0` → 置灰不可点）。
    ///
    /// 数量写进按钮里：用户不用去数屏上的对号，也知道按下去会删几条（与导航栏报数同一个理由）。
    func setSelectedCount(_ count: Int) {
        deleteButton.setTitle(count > 0 ? String(format: L("删除(%d)"), count) : L("删除"), for: .normal)
        deleteButton.isEnabled = count > 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        topLine.frame = CGRect(x: 0, y: 0,
                               width: bounds.width,
                               height: 1 / UIScreen.main.scale)
        // ⚠️ 安全区要减掉：整条的高度来自输入栏（含底部安全区），内容却只能占上面那段
        let contentHeight = bounds.height - safeAreaInsets.bottom
        let height = Self.buttonHeight
        let y = max((contentHeight - height) / 2, 0)

        // 宽度取「文字实际宽 + 留白」：`删除(12)` 比 `删除` 宽得多，写死宽度会截断
        let cancelWidth = fittedWidth(of: cancelButton, height: height)
        cancelButton.frame = CGRect(x: Self.horizontalMargin, y: y,
                                    width: cancelWidth, height: height)

        let deleteWidth = fittedWidth(of: deleteButton, height: height)
        deleteButton.frame = CGRect(x: bounds.width - Self.horizontalMargin - deleteWidth, y: y,
                                    width: deleteWidth, height: height)
    }

    /// 按钮包住标题所需的宽度（标题宽 + 两侧留白）
    private func fittedWidth(of button: UIButton, height: CGFloat) -> CGFloat {
        let titleWidth = button.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: height)).width
        return titleWidth + Self.titlePadding * 2
    }

    @objc private func cancelTapped() { onCancel?() }

    @objc private func deleteTapped() { onDelete?() }
}
