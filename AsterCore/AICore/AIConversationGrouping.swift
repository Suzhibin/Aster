//
//  AIConversationGrouping.swift
//  AICore
//
//  会话列表的**分组投影**（2026-10-21，项目 / 会话文件夹能力）。
//
//  ## 为什么放在共享层而不是某一端的视图层
//  分组规则是**产品口径**，不是某一端的画法 —— 两条端必须画出同样的分组与顺序，
//  否则「Mac 上分了三组、手机上只有两组」这种偏差会成为长期 bug 温床。
//  纯函数、无副作用 ⇒ 也能被离线探针直接机读验证（两端的渲染台 / 单测都不用造 UI）。
//
//  ## 三条口径（⛔ 别改，改了两端行为就和豆包 / WorkBuddy 不一样了）
//  ① **置顶段没有分组头**：置顶是全局概念，不参与项目分组
//     （归进某个项目组会让「它到底属于哪」变浑）；
//  ② **空项目也保留**（配「暂无对话」占位）—— 否则「建了项目却看不见」像没建成；
//  ③ **「未归类」已消灭**（2026-10-25）：所有会话必有项目，无归属行的默认容器是
//     默认项目「任务」（`AIChatStore.defaultProjectId`，sortOrder = -1 恒在最前）。
//     存量 NULL 行由 v10 迁移写进它；新会话在 `newConversation` 就带上它。
//     ⛔ 别把 `.ungrouped` 加回来 —— 那等于给「编译得过、功能是坏的」 bug 重新开门。
//
//  ## 排序谁负责
//  **共享层的 `AIChatStore.fetchSummaries()`**（置顶 → 项目 sortOrder，默认组 -1 最前）。
//  本文件**只分组、不排序** —— 视图层原样画。
//

import Foundation

/// 会话列表的一组分（`AIConversationGrouping.groups(summaries:projects:)` 的产物）。
///
/// `title == nil` ⇒ **不画分组头**（置顶段）。
public struct AIConversationGroup: Identifiable {
    public enum Kind: Equatable {
        /// 置顶段（恒无头）
        case pinned
        /// 某个项目（有头、可管理：重命名 / 删除）
        case project(UUID)

        /// 项目段才有「…」管理菜单（重命名 / 删除）；置顶段没有可管理的东西。
        /// ⚠️ 默认项目「任务」也是 project —— 它的「删除」要在**UI 层**拦
        ///    （store 层 `deleteProject` 双保险），`isProject` 保持 true。
        public var isProject: Bool {
            if case .project = self { return true }
            return false
        }
    }

    public let kind: Kind
    /// 分组头标题（已本地化 / 或用户输入的项目名）；nil = 不画头
    public let title: String?
    public let items: [AIConversationSummary]

    public init(kind: Kind, title: String?, items: [AIConversationSummary]) {
        self.kind = kind
        self.title = title
        self.items = items
    }

    /// `ForEach` / `UITableView` 的稳定身份。用字符串而不用 UUID：置顶段
    /// 没有天然 UUID，且各自至多出现一次 ⇒ 字符串键够用且不会撞。
    public var id: String {
        switch kind {
        case .pinned:           return "pinned"
        case .project(let pid): return "p:" + pid.uuidString
        }
    }
}

/// 把扁平的 `summaries` 按「置顶 → 项目」投影成分组（纯函数，只分组不排序）。
public enum AIConversationGrouping {

    public static func groups(summaries: [AIConversationSummary],
                              projects: [AIChatProject]) -> [AIConversationGroup] {
        var result: [AIConversationGroup] = []

        // ① 置顶段：不受项目影响、无分组头（口径 ①）
        let pinned = summaries.filter { $0.isPinned }
        if !pinned.isEmpty {
            result.append(AIConversationGroup(kind: .pinned, title: nil, items: pinned))
        }

        // ② 项目段：按 `projects` 原序（共享层已按 sortOrder 排，默认项目 -1 恒最前）；
        //    空项目也保留（口径 ②）。2026-10-25 起所有非置顶会话都落在某个项目里
        //    （「未归类」已消灭）⇒ 不再需要尾部兜底段。
        for project in projects {
            let items = summaries.filter { !$0.isPinned && $0.projectId == project.id }
            result.append(AIConversationGroup(kind: .project(project.id),
                                              title: project.name,
                                              items: items))
        }

        return result
    }
}
