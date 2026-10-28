//
//  AIMathBlockView.swift
//  Aster
//
//  块级公式（`$$...$$` / ```math）的显示单元：**一张位图**。
//
//  ## 为什么不是 `MTMathUILabel`
//  公式的排版与绘制全部在业务层完成（`AIPlatformMath.render` → `AIMathBlockMetrics`），
//  这里只负责把结果铺上去。三条理由：
//   ① 「量算与渲染同源」：行高是 `AIMarkdown.contentHeight` 按同一张图的尺寸算的，
//      这里若自己再排版一次（塞 `MTMathUILabel`），两边随时可能差一像素 ⇒ 裁行；
//   ② 池化：`UIImageView` 复用是零成本的，`MTMathUILabel` 每次 configure 都要重排；
//   ③ 与 `AICodeBlockView` 同一套「业务层给尺寸、视图层只画」的分工，读起来一致。
//
//  ## ⚠️ 宽度必须由外部给
//  本视图**不读** `UIScreen`、也不自己算 0.8×屏宽 —— 那个口径的唯一来源是
//  `AIChatRow.height` 的 `maxTextW`（`AIMarkdown.contentHeight` 吃的是同一个值）。
//  视图自己再算一遍 = 两套账，本工程反复栽过。
//

import UIKit
import SnapKit
import AICore

final class AIMathBlockView: UIView {

    private let imageView = UIImageView()
    private var widthConstraint: Constraint?
    private var heightConstraint: Constraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // `.scaleAspectFit` 而不是 `.center`：`displaySize` 已经缩过一次，
        // 正常不会二次缩放；留着 fit 是为了极端情况下（1pt 的取整误差）宁可整体缩一点，
        // 也不要让公式被裁掉右边一列。
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        imageView.snp.makeConstraints { make in
            // 左右留白与正文同值（`sideInset`）：不留这一手公式会贴着气泡左边缘，
            // 比上下那段文字更靠左，一眼就看得出没对齐。
            // 上下留白在这里；宽度贴左（公式与正文左边对齐，不在气泡里居中漂浮）
            make.left.equalToSuperview().offset(AIMathBlockMetrics.sideInset)
            make.top.equalToSuperview().offset(AIMathBlockMetrics.paddingV)
            make.bottom.equalToSuperview().offset(-AIMathBlockMetrics.paddingV)
            // 尺寸由 `configure` 给（= 业务层量高用的那个尺寸）
            widthConstraint = make.width.equalTo(0).constraint
            heightConstraint = make.height.equalTo(0).constraint
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - image: 业务层渲好的位图（已按当前墨色）。
    ///   - displaySize: **应显示尺寸**（已按可用宽等比缩小），与量高同源。
    func configure(image: UIImage, displaySize: CGSize) {
        imageView.image = image
        widthConstraint?.update(offset: displaySize.width)
        heightConstraint?.update(offset: displaySize.height)
    }

    /// 回池前清干净：尺寸归零，免得下一次 configure 之前先按旧尺寸撑一下高度。
    func prepareForReuse() {
        imageView.image = nil
        widthConstraint?.update(offset: 0)
        heightConstraint?.update(offset: 0)
    }
}
