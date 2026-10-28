//
//  AIChatMediaGrouping.swift
//  AICore
//
//  「**连续的助手媒体行 = 一条横滑缩略图条**」这条规则的**唯一出处** —— iOS 与 Mac 共用。
//
//  ## 为什么这条规则要放在业务层
//
//  数据层是「**一块一行**」：助手侧每来一个 `.image` / `.video` 流事件就 append 一行
//  （`AIChatManager.handle(_:)`）⇒ 「一次回复里来了 5 张图」在容器里本来就是**五行**。
//  而界面要的是「5 张排一条、横向滑」。中间那一次**投影**（谁跟谁算同一条）两个平台
//  都要做，那就只能有一份实现 —— 各写一份必然漂移（iOS 改了 kind 判据、Mac 没改，
//  症状是「同一段回复，手机上图片和视频挤一条、Mac 上分两条」，而且很难联想到是这个原因）。
//
//  ## 两个平台**怎么用**这份规则（各有各的活法，但判据同源）
//
//  | | Mac（SwiftUI） | iOS（UIKit 表格） |
//  |---|---|---|
//  | 数据源 | 换成「显示项」`ChatTranscriptItem.group(_:)` | **不动**：`indexPath.row` 仍是行号 |
//  | 谁渲染整条 | 那个 `.media` 显示项 | 组首那一行的 cell（`AIAssistantMediaStripCell`） |
//  | 组内其余行 | 不产生显示项 | **行高归零**（`AIChatManager.normalizeMediaGroupHeights()`） |
//
//  🔴 iOS 侧刻意选了「组首渲染整条、其余行高 0」而不是跟着 Mac 换数据源：这样
//     `indexPath.row` 的语义不变，**多选删除 / 搜索定位 / TTS / 编辑态 / 操作卡
//     全都不用加「显示项 ↔ 行」的映射层**（那一层是本工程最容易出错的地方）。
//
//  ⚠️ 「其余行高 0」有两个连带后果，**只出现在 iOS**（Mac 那几行压根不产生显示项）——
//     判据与成因见 `occupiesOwnRow(_:at:)`，⛔ 别绕过它自己按行号处理：
//     ① 零高度的行在**表格编辑态**下照样会被画勾选圈 ⇒ 图片横滑条与视频横滑条交界处
//        冒出一个半截蓝圈（2026-09-29 用户实拍）；
//     ② 它们**不能进勾选集合** ⇒ 否则「取消勾选整条横滑条」是假的（组内其余行还勾着）。
//
//  ## 两条判据，⛔ 别简化
//
//  1. **只认助手侧**（`role == .assistant`）：用户 2026-09-28 明确「只改 AI 回复侧」——
//     自己发的图仍是「一图一行、按真实比例」（`AIUserImageCell`）。
//  2. **kind 必须分**：用户原话「图片和视频不能在一个 cell」⇒
//     `图,图,视频,图` 是**三条**，不是一条。⛔ 别退化成「只看是不是媒体行」。
//
//  ## 🔴 用户侧的分组是**另一个函数**（`isUserImage` / `userImageGroupRange`，2026-10-08）
//
//  用户 2026-10-08 要求「Mac端发送一条消息内含多个图片要横排显示」⇒ Mac 把**连续的用户
//  图片行**也投影成一条（`ChatTranscriptItem` 的 `.userImages`）；2026-10-09 用户要求
//  iOS 同样横排 ⇒ **两端现在都消费**下面这组函数。
// ⛔⛔ **判据绝不能并进上面那个 `kind(of:)`** —— 它同时是「助手侧横滑条」与
//     「iOS 行高归零」的判据，用户图一旦进去有两个后果：
//     ① 助手侧 `groupRange` 会把用户图当媒体行划组（划组范围整个错位）；
//     ② iOS `normalizeMediaGroupHeights()` 会按 `mediaStripRowHeight`（192+12）给
//        用户图组定高 ⇒ **用户图被强行拉成 9:16 竖条那一档**，尺寸彻底错。
// ⇒ 规矩：**助手侧走 `kind(of:)`，用户侧走 `isUserImage`**，两个函数各服务各的规则。
//    两端**形态**不同只体现在「谁来消费」（Mac 换显示项 / iOS 组首渲染整条），
//    不体现在判据本身 —— 判据同源才不会有「同一段对话两端分条数不同」。
//
// ⚠️ 两处消费点必须同步：Mac `ChatTranscriptItem.group(_:)` 与 iOS
//   `AIChatManager.normalizeMediaGroupHeights()`。漏一端 ⇒ 那一端仍是「一图一行」。
//

import Foundation

/// 把「一块一行」的 `AIChatRow` 数组按「同一条横滑条」划组。
///
/// 全部是纯函数、只看 `role` 与 `block.kind` ⇒ 不碰数据库、不碰任何 UI 类型，
/// 两个平台的渲染层与业务层的行高量算都能直接用。
public enum AIChatMediaGrouping {

    /// 该行是不是「助手的媒体行」；是的话返回它的 kind（`.image` / `.video`），否则 `nil`。
    ///
    /// 这两个判据就是「同一条横滑条」的全部定义（见文件头），别在调用点另写一份。
    public static func kind(of row: AIChatRow) -> AIBlockKind? {
        guard row.role == .assistant else { return nil }
        switch row.block.kind {
        case .image, .video: return row.block.kind
        default:             return nil
        }
    }

    /// 该行是不是它所在媒体组的**组首** —— 也就是「那条横滑条挂在哪一行」。
    /// 非媒体行恒为 `false`。
    ///
    /// 组首的判据只有一条：**上一行不是同一个 kind 的助手媒体行**
    ///（上一行不存在 / 是别的 kind / 是文本 / 是用户行 ⇒ 都算组首）。
    public static func isGroupHead(_ rows: [AIChatRow], at index: Int) -> Bool {
        // ⚠️ 局部变量**不能**叫 `kind`：那会把这个静态方法本身遮蔽掉，
        //    下面第二句 `kind(of:)` 就被解析成「调用一个 AIBlockKind 值」⇒
        //    `cannot call value of non-function type 'AIBlockKind'`（2026-09-28 实打实踩了）。
        guard rows.indices.contains(index), let rowKind = Self.kind(of: rows[index]) else { return false }
        guard index > 0 else { return true }
        return Self.kind(of: rows[index - 1]) != rowKind
    }

    /// 这一行在界面上**自己占一行**吗？（= 它有没有属于自己的位置与勾选圈）
    ///
    /// 非媒体行恒 `true`；媒体行**只有组首**为 `true` —— 组内第 2..N 张不占高
    /// （iOS 侧把它们的高度归零，见 `AIChatManager.normalizeMediaGroupHeights()`）。
    ///
    /// ## 谁在用它：iOS 的「多选删除」（2026-09-29 加）
    /// 勾选集合、以及「这一行能不能被点选」都**只收** `true` 的行。⛔ 别改回「按行号一律可选」，
    /// 那样会同时踩两个坑（第一个是用户实拍报上来的）：
    ///
    /// - **症状一**：图片横滑条与视频横滑条**交界处冒出一个被切掉上半截的蓝圈**。
    ///   不是多画了控件 —— 是「有一个高度为 0 的行被勾上了」，而 `UITableView` 在编辑态下
    ///   **照样**给零高度的 cell 摆勾选圈（控件贴着 cell 顶边往下落 ⇒ 只看得见下半截）。
    /// - **症状二（更严重、也更难发现）**：零高度的行留在勾选集合里 ⇒ 用户**取消勾选**那条横滑条
    ///   （点上的是组首那一行）时，组内其余行**仍然是勾着的** ⇒ 删除时它们照样被 `groupIds`
    ///   展开删掉。表现是「我明明取消了，图还是没了」。
    ///
    /// ⚠️ 整组一起删**不靠**这个判据：删除时按 `groupIds` 把勾中的那一行展开成整组
    ///（见 `AIModuleViewController+Selection.selectedMessageIds()`）。
    ///
    /// ## 🔴 用户图片组同样适用（2026-10-09）
    /// iOS 的用户多图横排与助手侧是**同一套机制**（组首渲染整条、其余行高 0），
    /// 所以上面两个症状对用户图组**一模一样**会出现。判据仍是同一个函数，只是多问一句
    /// 「它是不是用户图组的非组首」。⚠️ `userImageGroupRange` 对**单张**也返回 1 行区间
    /// ⇒ 单张的组首就是它自己 ⇒ 仍返回 `true`，**单张图片不受影响**。
    public static func occupiesOwnRow(_ rows: [AIChatRow], at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        guard Self.kind(of: rows[index]) != nil else {
            // 非助手媒体行：只有「用户图片组的非组首」不占行，其余一律占行。
            guard Self.isUserImage(rows[index]) else { return true }
            return Self.isUserImageGroupHead(rows, at: index)
        }
        return Self.isGroupHead(rows, at: index)
    }

    /// 该行所在媒体组的**行下标区间**；非媒体行返回 `nil`。
    public static func groupRange(_ rows: [AIChatRow], at index: Int) -> Range<Int>? {
        guard rows.indices.contains(index), let rowKind = Self.kind(of: rows[index]) else { return nil }
        var first = index
        while first > 0, Self.kind(of: rows[first - 1]) == rowKind { first -= 1 }
        var last = index
        while last + 1 < rows.count, Self.kind(of: rows[last + 1]) == rowKind { last += 1 }
        return first ..< (last + 1)
    }

    /// 该行所在媒体组的**全部行**（按时间顺序）；非媒体行返回 `[自己]`（下越界时返回 `[]`）。
    ///
    /// 给「组首要渲染整条」用（Mac 的 `MediaThumbStrip(rows:)` 与 iOS 的
    /// `AIAssistantMediaStripCell.configure(rows:)` 取的都是它）。
    public static func groupRows(_ rows: [AIChatRow], at index: Int) -> [AIChatRow] {
        guard let range = groupRange(rows, at: index) else {
            return rows.indices.contains(index) ? [rows[index]] : []
        }
        return Array(rows[range])
    }

    /// 该行所在媒体组的**全部消息 id**。
    ///
    /// 给「多选删除时整组一起删」用（用户 2026-09-28 选定）：勾中一条横滑条 =
    /// 删掉它包含的全部图片 / 视频 —— 横滑条看起来就是**一个东西**，删一半会让人以为没删干净。
    public static func groupIds(_ rows: [AIChatRow], including index: Int) -> [UUID] {
        groupRows(rows, at: index).map { $0.block.id }
    }

    // MARK: - 用户侧「同一次发送里的多张图」（2026-10-08 加，Mac 先用 · 2026-10-09 iOS 也用）

    /// 该行是不是「用户一次发送里的那张图片」。
    ///
    /// ⚠️ **刻意与 `kind(of:)` 分开成两个函数**，⛔ 别为了「少一个函数」把用户侧并进 `kind(of:)`：
    /// 它是「助手侧横滑条」与「iOS 行高归零」的判据 —— 用户图一旦并进去，
    /// 助手侧划组范围错位、iOS 上更会按 `mediaStripRowHeight`（192+12）把用户图定高，
    /// **尺寸彻底错**（成因见文件头）。
    public static func isUserImage(_ row: AIChatRow) -> Bool {
        row.role == .user && row.block.kind == .image
    }

    /// 用户侧「同一次发送里的连续图片行」的行下标区间；该行不是用户图片行时返回 `nil`。
    ///
    /// ## 判据：连续的用户 `.image` 行 + **不跨轮**
    ///
    /// - **不跨轮**靠 `isFirstBlockOfTurn`（轮起点，与 `turnRowRange` 同一份定义）：
    ///   一次发送里第一张图为 `true`、其余为 `false`，所以「往两边扩」时一旦撞到
    ///   `isFirstBlockOfTurn == true` 的用户图片行就停 —— 那说明它是**下一次发送**的第一张。
    ///   ⚠️ 只判「连续同类」是不够的：两次「只发图、不发字」的发送在数据层是**紧邻**的
    ///   （中间隔着助手行，但把它剔掉之后判据就看不见那条边界了）⇒ 会把两次发送并成一条。
    /// - ⚠️ 用户侧**没有 kind 分组**（助手侧「图 / 视频不能同条」那条）：用户根本发不了视频
    ///   （`AIChatManager.contextMessages()` 对用户侧 `.video` 直接 `continue`，
    ///   附件面板也只产出 `.image` / `.file`）⇒ 用户媒体组里只有图一种 kind。
    ///
    /// **两个消费方**：Mac 的显示项投影（`ChatTranscriptItem.group`）与 iOS 的
    /// `normalizeMediaGroupHeights()`（组首渲染整条、其余行高归零）。
    /// 单张也返回 1 行的区间（≥1 成组），与助手侧同一条口径：单张与多张共用同一条渲染路径。
    public static func userImageGroupRange(_ rows: [AIChatRow], at index: Int) -> Range<Int>? {
        guard rows.indices.contains(index), Self.isUserImage(rows[index]) else { return nil }
        var first = index
        // ① 后向：先跨过所有「轮内后续」的图（它们 `isFirstBlockOfTurn == false`）
        while first - 1 >= 0,
              Self.isUserImage(rows[first - 1]),
              !rows[first - 1].isFirstBlockOfTurn {
            first -= 1
        }
        // ② 🔴 然后**必须把本轮的轮起点那张也纳入**（2026-10-09 用户实拍换来的修复）。
        //
        //    ①停下时 `rows[first - 1]` 正是「一张 `isFirstBlockOfTurn == true` 的用户图」
        //    —— 也就是**本轮的第一张**。⛔ 别以为 ① 已经吃到了它：**轮起点自己就是 true**，
        //    所以 ① 永远不会越过它。这一张漏掉的后果是**整组裂成两段**：
        //      · index 0 拿到 `0..<N`（正确）
        //      · index 1..N-1 拿到 `1..<N` ⇒ **`isUserImageGroupHead` 对它们也返回 true**
        //        （`range.lowerBound == index` 恰好成立）⇒ 「组首有且只有一个」被破坏。
        //    于是：index 1 因 `count == 1` 不走横排、回退成**原尺寸单图**，
        //    它的行高又因 `count > 1` 不成立被归一逻辑 `continue` 跳过（仍是单图高度）；
        //    而 N ≥ 3 时真正的组尾行「count>1 但不是组首」⇒ **高度归零 = 那张图被吞掉**。
        //    ⇒ 症状是「多图仍显示成单图 + 有一张不见了」，且**不报任何错**。
        //
        //    ⚠️ 为什么这行不会误吃**上一轮**：连续同role 的行里 `isFirstBlockOfTurn`
        //    恰好只有第一张是 true（`appendRow`：`isFirst = rows.isEmpty || last?.role != role`），
        //    所以 ① 停下来的那张一定是**本轮**的起点，不会是上一轮残留的那张。
        if first - 1 >= 0, Self.isUserImage(rows[first - 1]) { first -= 1 }
        var last = index
        while last + 1 < rows.count,
              Self.isUserImage(rows[last + 1]),
              !rows[last + 1].isFirstBlockOfTurn {
            last += 1
        }
        return first..<(last + 1)
    }

    /// 该行所在用户图片组的全部行；该行不是用户图片行时返回 `[自己]`（下越界返回 `[]`）。
    ///
    /// 给 Mac 的 `UserImageStrip` 用 —— 与助手侧的 `groupRows` 同一个用途、同一套形状。
    public static func userImageGroupRows(_ rows: [AIChatRow], at index: Int) -> [AIChatRow] {
        guard let range = userImageGroupRange(rows, at: index) else {
            return rows.indices.contains(index) ? [rows[index]] : []
        }
        return Array(rows[range])
    }

    /// 该行是不是它所在用户图片组的**组首**（= 那条横排挂在哪一行）；不是用户图片行恒 `false`。
    ///
    /// 与 `isGroupHead` 同构，只是判据换成用户侧那把尺（`userImageGroupRange`）。
    /// iOS 侧 2026-10-09 起也用它做「组首渲染整条、其余行高归零」（Mac 走显示项投影，不消费它）。
    public static func isUserImageGroupHead(_ rows: [AIChatRow], at index: Int) -> Bool {
        guard let range = userImageGroupRange(rows, at: index) else { return false }
        return range.lowerBound == index
    }

    /// 该行所在用户图片组的**全部消息 id**（删除时整组一起删，与助手侧 `groupIds` 同一条口径）。
    public static func userImageGroupIds(_ rows: [AIChatRow], including index: Int) -> [UUID] {
        userImageGroupRows(rows, at: index).map { $0.block.id }
    }

    // MARK: - 「勾选了几条消息」（2026-10-09 加，两端报数的**唯一来源**）

    /// 勾中的这些行，在界面上**一共有几条消息**。
    ///
    /// ## 🔴 为什么要有这个函数（用户 2026-10-09 要求：「删除数量改成按消息个数算」）
    ///
    /// 改之前的口径是**按块数**（`AIChatRow` 的行数 / `userImageGroupIds` 的长度）：
    /// 一次发 5 张图 → 勾选 → 报数写「已选择 **5** 条」⇒ 用户看到的是
    /// **「界面上明明只有一条，数字却写着 5」**。
    /// 🔴 那个 5 在**删除时是对的**（确实要删 5 个 block），错的是**报数** ——
    /// 报数要回答的是「我勾了几条」，不是「底层要删几个块」。
    ///
    /// ## 「一条消息」= **界面上占一条的那一行**
    ///
    /// 判据直接复用 `occupiesOwnRow(_:at:)`（那已经是「界面上自己占一行」的判据）：
    /// 组内第 2..N 行**不占行** ⇒ 它们不贡献条数 ⇒ 一条横排图**恒算 1 条**。
    /// 📌 这与**勾选粒度天然一致**（界面上一条 = 一个勾选圈）——
    /// 「勾了几个圈就报几条」是用户唯一能自己验的口径。
    ///
    /// ## 🔴⛔⛔ 只管**报数**，不许碰删除
    ///
    /// 「勾选集合」与「要删的 block 集合」是**两件事**，前者是界面的事、后者是数据的事：
    /// - **报数**读本函数（按条）；- **删除**读 `groupIds` / `userImageGroupIds`（按块，整组删）。
    /// ⛔ 千万别把删除也改成「只删组首」—— 那正是 2026-09-28 用户选定「整组一起删」时要避免的
    /// 「删掉一条消息，可图还剩好几张」。本函数**只**提供数字。
    ///
    /// ## ⚠️ 参数收**行下标**而不是 id（一个刻意的选择）
    ///
    /// 两端拿到的勾选真值形状不同（iOS 是 `indexPathsForSelectedRows` 的**行下标**，
    /// Mac 是 `ChatModel.selectedRowIds` 的**行 id**），而「行 id == `block.id`」只是
    /// **两处造行处的默契**（`AIChatManager` 造行 / `AIChatStore` 恢复处）——
    /// ⚠️ 渲染台的夹具行 id 是独立 `UUID()`，按 id 比必然假红。
    /// ⇒ 收行下标，两端各自负责把自己的真值换成下标（Mac 那边一次 `firstIndex` 换即可）。
    ///
    /// - Returns: 消息条数。⚠️ 下标越界的行**静默跳过**（与本文件其它函数同口径）。
    public static func selectedMessageCount(_ rows: [AIChatRow], rowIndexes: [Int]) -> Int {
        var seen = Set<Int>()
        var count = 0
        for index in rowIndexes.sorted() where rows.indices.contains(index) {
            // 只让「自己占一行」的贡献条数：组内其余行并进它们组首那一条里。
            guard occupiesOwnRow(rows, at: index) else { continue }
            // ⚠️ 这一道去重是**廉价保险**：正常形状下各组互不相交、不会重复；
            //    但万一勾选集合里混进了同组的另一行（判据回退、新增入口），
            //    报数也不会当场虚高 —— 「删除」是不可逆动作，宁可少报不可多报。
            guard seen.insert(index).inserted else { continue }
            count += 1
        }
        return count
    }

    // ☠️ **「一组媒体的文字占位」（`placeholder(forIds:in:)`）2026-09-29 已删除**。
    //
    //    它当时只服务一件事：「引用一组媒体」时引用条上写点什么（AI 纯图回复 ⇒ `[3 张图片]`）。
    //    而**媒体引用本身已被用户要求去掉**（原话「先把图片 和 视频的 引用去掉」，来由与
    //    两条「要加回来」的路记在 `MAC-UI-RULES.md` 与 `AsterMac/ChatModel.swift` 里
    //    那次删除处），没有调用方了 ⇒ 跟着删掉，不留没人用的公开 API。
    //
    //    📌 真要加回来时**别只搬这一份函数**：当时它解决的只是「引用条没字可写」，
    //    而真正的问题是**助手侧的图根本不进请求上下文**（远程 URL、从没落地）——
    //    那件事不解决，引用条上写什么都是摆设。
    //
    //    ⚠️ 它当初的两条口径本身是对的，抄回去时保留：
    //    ① 按**传入顺序**计数（调用方给的就是界面上的顺序）⇒ 图在前视频在后读作
    //       「3 张图片、1 个视频」，与眼睛看到的排列一致，⛔ 别排序；
    //    ② 判据用 `block.kind` 而**不是** `kind(of:)` —— 后者只认助手侧（那是「横滑条」的判据），
    //       而这里要数的是「这组媒体里各是什么」，将来用户侧媒体若也能引用，这条照样对。
}
