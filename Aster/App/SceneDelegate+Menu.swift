//
//  SceneDelegate+Menu.swift
//  Aster
//
//  Created by Suzhibin on 2026/9/20.
//
//  左侧抽屉菜单（SideMenu）。
//
//  📌 2026-10-04 由 `SceneDelegate+Navigator.swift` **改名**而来，同一轮做了三件事：
//     · URLNavigator 依赖整体摘除（路由从没被 push/present 过，见 `AIModuleRouter.register()`）
//     · 原 `setupNavigator()` → 改名 `registerAIModule()`，并**搬去 `SceneDelegate+Init.swift`**
//       （它做的是模块注册、不是路由）
//     · `NavigatorDelegate` 那两个只打 `print` 的调试钩子删除
//     所以本文件只剩菜单，文件名随之改掉。⛔ 别再把路由相关的东西塞回来。

import UIKit
import SideMenu
import StarryKitCore

/// 抽屉菜单拉出时，覆盖在主页面（presenting view）之上的遮罩层。
/// 作为主页面的子视图添加，会随主页面一起被 SideMenu 平移，从而实现「主页面上有遮罩感」。
private var menuDimView: UIView?

extension SceneDelegate {

    /// 左侧抽屉菜单（对话标题 / 新对话 / AI 创作 / 历史对话选择）。
    /// 菜单数据由 AIModuleViewController 在加载时接线（setupMenu 复用此处注册的实例）。
    ///
    /// ## 🔴 实例**全进程只造一份**（2026-10-13 定案）
    /// 冷启动时 manager 上是 nil ⇒ 这里造一个；之后任何「重建界面」的路径（切语言）再调进来时
    /// **一律复用**，只把呈现配置重套一遍（下面那几个属性都是幂等的）。
    ///
    /// ## ☠️☠️ 为什么不能「重造一份来刷新文案」（用户 2026-10-13 报的那条 bug）
    /// SideMenu 6 给 `leftMenuNavigationController` 装了闸门，赋值会走进
    /// `Protected.value` 的 `setMenu(fromMenu:toMenu:)`：
    /// ```swift
    /// if fromMenu?.isHidden == false {          // isHidden = presentingViewController == nil
    ///     Print.warning(.menuInUse, …)
    ///     return fromMenu                       // ☠️ 静默拒绝：原样返回**旧**菜单
    /// }
    /// ```
    /// ⇒ **旧菜单还在呈现时，新菜单根本当不上**（不报错，只在控制台留一条 warning）。
    /// 而用户切语言的那一刻，抽屉恰好**开着**（账号弹窗是从抽屉里弹的，关掉它抽屉还在）
    /// ⇒ 那一刻造的新菜单必然被丢掉 —— 白造一个马上释放的 nav，还让人以为「已经重挂了」。
    /// （逐字源码 + 真机实测证据见技能 `ios-sidemenu-drawer` §4.5。）
    ///
    /// ⇒ 想刷新抽屉里的文案只有一条正路：**别把文案放进实例的存储属性里**
    ///   （`quickItems` 改计算属性 + `viewWillAppear` 里重读，见 `AIMenuViewController` 里那段铁律）。
    func setupAIMenu() {
        let menuNav: SideMenuNavigationController
        if let existing = SideMenuManager.default.leftMenuNavigationController,
           existing.viewControllers.first is AIMenuViewController {
            menuNav = existing
        } else {
            menuNav = SideMenuNavigationController(rootViewController: AIMenuViewController())
            // ⚠️ 只有真的新建时才需要挂上去（复用时赋同一个对象也会过那道闸门，纯多余）
            SideMenuManager.default.leftMenuNavigationController = menuNav
        }

        // 监听菜单出现/消失，见文件下方的 SideMenuNavigationControllerDelegate
        menuNav.sideMenuDelegate = self
        menuNav.statusBarEndAlpha = 0           // 菜单显示后状态栏区域叠加透明度（0=不绘制）
        menuNav.menuWidth = 300                 // 菜单宽度（默认 240）
        menuNav.dismissOnPush = false           // 从菜单 push 新页时是否自动关闭（默认 true）

        // ⚠️ 必须显式设 false（SideMenu 默认 **true**）：设置页改成「在菜单上模态弹出」，
        // 而 dismissOnPresent = true 会在「从菜单 present 新页面」时自动把菜单 dismiss 掉
        // （源码：SideMenuNavigationController 里 `if dismissOnPresent { transition(presenting: false...) }`，
        //  且 viewDidDisappear 里还会 `view.isHidden = true`）→ 抽屉就关了，与预期相反。
        menuNav.dismissOnPresent = false

        menuNav.presentationStyle = .viewSlideOutMenuIn
    }
}

extension SceneDelegate: SideMenuNavigationControllerDelegate {

    func sideMenuWillAppear(menu: SideMenuNavigationController, animated: Bool) {
        guard let host = menu.presentingViewController?.view else { return }
        let dim = UIView(frame: host.bounds)
        dim.backgroundColor = .black.withAlphaComponent(0.2)
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        host.addSubview(dim)          // 作为主视图子视图 → 随主视图一起被 SideMenu 平移
        menuDimView = dim
        let duration = animated ? 0.35 : 0
        UIView.animate(withDuration: duration) { dim.alpha = 0.5 }
    }

    func sideMenuDidAppear(menu: SideMenuNavigationController, animated: Bool) {
        // 菜单完全展开时触发触感反馈（抽屉到位感）
        StarryHaptic.impact(.light)
    }

    func sideMenuWillDisappear(menu: SideMenuNavigationController, animated: Bool) {
        guard let dim = menuDimView else { return }
        dim.alpha = 0
        dim.removeFromSuperview()
        menuDimView = nil
    }

    func sideMenuDidDisappear(menu: SideMenuNavigationController, animated: Bool) {
    }
}
