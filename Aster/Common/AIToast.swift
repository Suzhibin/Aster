//
//  AIToast.swift
//  AIModule
//
//  Created by Suzhibin on 2026/10/03.
//

import UIKit
import SnapKit

/// 轻量 Toast：把一句短提示贴在指定视图的**底部安全区上方**，约 4.2s 后淡出。
///
/// ## 为什么不复用会话页那个 `showToast`
/// `AIModuleViewController.showToast` 把 label 贴在**会话页自己的 view** 上 —— 而抽屉菜单
/// 是**模态呈现**的（SideMenu），主页面被整体推到右边、还盖了一层遮罩 ⇒ 在抽屉里点东西时
/// 会话页的 toast **在画外**（用户看不到，只会以为「点了没反应」）。
/// 所以抽屉这类「不在会话页上」的地方要各自有一份贴在**自己**视图上的 toast。
///
/// ## 为什么是 enum + 静态方法（而不是某个 VC 的私有 label）
/// 现在有一处要用（侧滑菜单的扫一扫占位），且只需「一句话 + 自己消失」，
/// 不值得各自复制一遍约束与定时器。做成无状态工具：**label 挂在宿主视图上**（`tag` 复用），
/// 本类型自己不持有任何状态 —— 宿主没了 label 就跟着没了，不会留下野指针。
enum AIToast {

    /// 挂在宿主视图上的 tag（同一个宿主反复弹时复用同一个 label，避免叠一堆）
    private static let labelTag = 88_5001

    /// 显示时长（秒）。**全 App 的 toast 都读这一个数**（`AIToast` 自己 + 会话页
    /// `AIModuleViewController.showToast`），换地方不换手感。
    ///
    /// 🔴 2026-10-26 用户反馈「报错的吐司看不清楚」⇒ 由 **2.2 提到 4.2（+2s）**。
    ///    这些提示多半是**一整句可操作指引**（例如「语音识别初始化失败：本机的中文离线识别
    ///    模型没就绪。请到「设置 › 通用 › 键盘 › 听写」确认「普通话」已下载完再回来」），
    ///    2.2s 只够扫到前四个字，用户还没读完就没了 —— 那等于没提示。
    /// ⛔ 别为了"手感轻快"改回 2.2：这是**读得完**的下限。
    /// ⚠️ 只有一处定义：会话页原来自己写了一份字面量 2.2，改一处漏一处就会出现
    ///    「通话页看得清、输入框看不清」这种莫名其妙的不一致。
    static let duration: TimeInterval = 4.2

    /// 在 `host` 上弹一句提示。
    ///
    /// - Parameters:
    ///   - message: 提示文案（**别带首尾空格**，内边距由本方法自己加）
    ///   - host: 把 label 贴到谁的视图上。⚠️ 必须是**当前真的看得见**的那一层：
    ///     抽屉里点出来的提示要贴抽屉（这项目前只有扫一扫那一处）。
    ///   - bottomInset: 距宿主**底部安全区**的距离。抽屉菜单底部有账号栏（49pt），
    ///     传 61 才是「压在账号栏上方 12pt」，否则会盖在头像名称那一行上。
    static func show(_ message: String, in host: UIView, bottomInset: CGFloat = 24) {
        let label = existingLabel(in: host) ?? makeLabel(in: host, bottomInset: bottomInset)
        // 文案带上首尾空格当内边距：label 没有 contentEdgeInsets（UILabel 本来就不给），
        // 而给它加一层容器只为了撑这 12pt 不划算（本工程一贯做法，会话页 toast 同款）。
        let text = "  \(message)  "
        label.text = text
        label.alpha = 1

        // ⚠️ 用「文案没被改过」当作这次定时器的有效期判据，**不引入任何静态计数/当前实例**：
        //    连点两次时，第一次那个闭包发现 text 已经变了就自行放弃 ——
        //    否则新 toast 会被旧定时器提前藏掉（也是本文件刻意不做全局单例的原因）。
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard label.text == text else { return }
            UIView.animate(withDuration: 0.25) { label.alpha = 0 }
        }
    }

    private static func existingLabel(in host: UIView) -> UILabel? {
        host.viewWithTag(labelTag) as? UILabel
    }

    private static func makeLabel(in host: UIView, bottomInset: CGFloat) -> UILabel {
        let label = UILabel()
        label.tag = labelTag
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor(white: 0, alpha: 0.8)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        // 🔴 必须关掉交互：菜单账号栏在它下方，toast 盖住谁就点不动谁
        //    （label 默认 `isUserInteractionEnabled = false`，这里写出来是防「顺手打开」）
        label.isUserInteractionEnabled = false
        host.addSubview(label)
        label.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(host.safeAreaLayoutGuide.snp.bottom).offset(-bottomInset)
            // 高度给一个下限但不锁死：长文案换行时能长高（`>= 32` 而不是 `== 32`）
            make.height.greaterThanOrEqualTo(32)
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
        }
        return label
    }
}
