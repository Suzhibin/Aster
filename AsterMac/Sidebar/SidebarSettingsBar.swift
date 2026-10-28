//
//  SidebarSettingsBar.swift
//  AsterMac
//
//  左栏**最下面**那一行：只剩一颗**设置齿轮**（右对齐）。
//
//  ## 🔴 2026-10-27 用户要求删掉「头像 + 姓名」
//  用户原话：「那就把头像和名称都删除吧」。
//  理由（也是本文件为什么可以只剩一颗齿轮）：本 App **没有账号体系** ——
//  纯本地沙盒、没有登录、没有云端身份。那一行原来的三样东西分别是：
//    · 头像   = 系统登录用户的图片（沙盒取不到 ⇒ 一直是「首字母 + 强调色圆底」的**假头像**）
//    · 姓名   = `NSFullUserName()`（**这台机器**的用户名，不是「这个 App 的用户」）
//    · `>`    = 点开账号菜单（设置… / GitHub / 退出登录）
//  ⇒ 前两样是在**假装有个"我"**，第三样里的「退出登录」本来就是占位（点了只弹一句话）。
//  三个动作现在都有真去处，所以整块删掉**功能零损失**：
//    设置 → 就是本文件这颗齿轮（原来那颗也一直在）
//    GitHub → 「设置 → 关于」页（`MacAboutSettingsView` 里那行 `repoURL`）
//    退出登录 → 删（占位项，本来就不做事）
//
//  ⛔ 别再把头像 / 姓名 / 账号菜单加回来：要加先回答「这个'我'是谁」——
//     没有账号体系时它只能是 `NSFullUserName()`，那在多用户 Mac 上显示的是**系统账号名**，
//     跟自己开源的 App 一点关系都没有。
//
//  ## 为什么文件名还叫「账号栏」那套常量（`accountBarRowHeight` 等）
//  常量名沿用历史（`MacTheme` 里那一组 `account*`）—— 它们现在是**侧栏底部栏**的尺寸口径，
//  值一个都没动：行高仍是用户 2026-10-21 点名保留的 **64**，内容按 24 的命中区居中。
//  ⚠️ 改这些常量会同时影响渲染脚本的契约断言（`render_mac_ui.sh` 里 ⑩⑪ 两条），
//     真要改名就把那边一起改，别只改一半（漏了 = 断言假红）。
//

import SwiftUI
import AICore

struct SidebarSettingsBar: View {

    /// 打开设置窗口。
    ///
    /// ⚠️ 走 `openSettings()` 而不是 `SettingsLink`：与侧栏其它入口保持同一种写法，
    ///    且 `SettingsLink` 是 `View`，将来若要塞进 `NSMenu`（本文件已经没有菜单了，
    ///    但别处还有）就用不了 —— 两条路径必须落到同一个动作上。
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 只有一颗齿轮 ⇒ 用 `Spacer` 把它顶到行尾（与改动前齿轮的位置一致）。
        // ⚠️ 原来这里有「左块 + 齿轮」两颗兄弟按钮、以及 hover 底的归属问题
        //   （用户 2026-10-03 要求「变色区域去掉设置按钮区域」）—— 左块删掉之后
        //   那条约束**没有对象了**，hover 底也一并去掉：只剩一颗按钮时，
        //   指针反馈交给系统（`Button` 自带的按下态），⛔ 别再补一层自绘 hover。
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            settingsButton
        }
        // 外层内边距 = 与固定入口那组同一层（`quickEntryPaddingH`）⇒ 齿轮右缘与上面那两条入口对齐
        .padding(.horizontal, MacTheme.quickEntryPaddingH)
        // 分隔线画在**自己身上**（而不是让调用方再加一个 `Divider()`）：
        // 这样这个视图单独拎出来渲染时，看到的就是它在侧栏里的完整样子。
        // ⚠️ 挂在 `padding` **之后** ⇒ 线横跨整条侧栏宽（与改动前一致）。
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MacTheme.accountBarBorder)
                .frame(height: 1)
        }
    }

    /// 齿轮 —— 侧栏底部唯一的设置入口（不弹菜单，直接开设置窗口）。
    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(MacTheme.ui(MacTheme.accountIconSize, weight: .medium))
                // 🔴 2026-10-21 第二版：`meta`（tertiaryLabel，浅灰）→ `bodyColor`（= `.primary`）。
                //    用户原话「设置按钮的颜色换成黑色」。
                //    ⚠️ 用的是 `bodyColor` 而不是写死 `.black`：浅色下就是黑，深色下自动变白 ——
                //      写死黑会在深色外观里变成「深底黑齿」= 完全看不见（本 App 外观三档、
                //      改一次要重启验证，这种一眼不可见的退化最容易漏）。
                .foregroundStyle(MacTheme.bodyColor)
                // 图标垫到 accountIconHitSize 才够点（图标本身只有十几个点）
                .frame(width: MacTheme.accountIconHitSize, height: MacTheme.accountIconHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 垂直内边距由 `accountBarRowHeight` 派生 ⇒ 这一行仍是 64 高（用户 2026-10-21 点名保留）
        .padding(.vertical, MacTheme.accountBarPaddingV)
        // 行内那一半内边距：与外层 `quickEntryPaddingH` 相加 = `accountBarPaddingH`
        // ⇒ 齿轮右缘与上面的入口、分组标题落在同一条竖线上。
        .padding(.trailing, MacTheme.accountBarPaddingH - MacTheme.quickEntryPaddingH)
        .help(L("打开设置"))
    }
}
