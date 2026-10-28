//
//  SPLSQLiteManager.swift
//  SPLMedia
//
//  Created by xuqinqiang on 2025/6/6.
//  Copyright © 2025 SPLMedia. All rights reserved.
//

import SQLite
import Foundation
import AIPlatform
import struct SQLite.Expression

/// SQLiteManager 数据库错误
public enum SQLiteManagerError: Error {
    /// 数据库连接不可用（创建失败或已被释放）
    case connectionUnavailable
    /// 事务嵌套：在 `transaction` 内部又调了一次 `transaction`（含 `batchInsert`）。
    ///
    /// SQLite 的裸 `BEGIN` 在已有事务里会直接报错，而 `transaction` 的容错分支会把任何异常
    /// 当成「事务失败」去 `ROLLBACK` —— 那会把**外层**只写了一半的事务一起回滚掉，比直接报错更糟。
    /// 所以这里显式拦截并抛出，让问题停在调用点。
    case nestedTransaction
}

/// 索引策略开关：业务层用来决定是否在某张表上建立索引
///
/// 索引用「写入变慢 + 额外存储」换取「查询变快」，故应按需开启，而非见业务就加。
public enum IndexPolicy {
    /// 无条件建立（调试或强一致场景）
    case always
    /// 不建立
    case never
    /// 仅当表行数 ≥ threshold 时建立（即「大表才建索引」）
    case auto(threshold: Int)
}

/// 业务声明的索引候选
///
/// Manager 不知道业务的查询模式（不知道你按哪列排序/筛选），因此「建哪些列的索引」由业务声明；
/// 「现在该不该建」由 `IndexPolicy` 决定。
public struct IndexSpec {
    /// 索引名（建议 `idx_<表>_<列>` 命名，便于排查）
    public let name: String
    /// 表名
    public let table: String
    /// 需要索引的列名（数据库中的真实列名，如 `visit_time`）
    public let column: String

    /// 构造索引候选
    /// - Parameters:
    ///   - name: 索引名
    ///   - table: 表名
    ///   - column: 列名（数据库真实列名）
    public init(name: String, table: String, column: String) {
        self.name = name
        self.table = table
        self.column = column
    }
}

/// 元表名：记录每张业务表的 schema 版本，按表独立追踪，避免多业务共用全局 `user_version` 冲突
private let migrationsTableName = "_migrations"

public class SQLiteManager: NSObject {

    public static let shared = SQLiteManager()

    private override init() {
        super.init()
        // 🔴🔴 可重入判据的**写侧**（2026-10-23 补）：`onQueue` 靠
        //    `DispatchQueue.getSpecific(key: queueKey)` 判断「当前已经在这条队列上」，
        //    而队列-specific 值**必须由 setSpecific 挂上去**才读得到 —— 这里漏了它，
        //    于是 `getSpecific` 恒为 nil，重入判据恒假：
        //    ☠️ 症状 = **事务闭包内调任何带锁方法**（`delete` / `search` / `insert` /
        //       `update` / `scalar`）都会走进 `dbQueue.sync` —— 而调用方本来就在
        //       `dbQueue` 上（串行队列自己 sync 自己）⇒ **必死锁**，libdispatch 直接
        //       `__DISPATCH_WAIT_FOR_QUEUE__` + SIGTRAP（EXC_BREAKPOINT），
        //       **不抛 Swift 错误、没有 try 能接住**，连崩溃报告都只有一行队列名。
        //     ☠️ 踩中的两条路：`AIChatStore.replaceFileChunks`（RAG 索引进事务）
        //       与 `AIChatStore.deleteProject`（事务内 search + delete）——
        //       后者是**先例**，同样会崩，只是还没被跑到过（项目功能 10-21 上线以来
        //       没人真删过项目）⇒ 别因为「先例这么写过」就认为事务内可以调 delete。
        //    ✅ 有了这一行，`transaction` 的「事务嵌套」守卫也才真正生效
        //       （那个 `getSpecific == nil` 判据此前恒真 = 死代码）。
        //    ⚠️ 顺序无所谓：`dbQueue` 是 let、此时已初始化；队列-specific 值是队列
        //       自带的，与连接/表都无关。
        dbQueue.setSpecific(key: Self.queueKey, value: 1)
        // 内存警告 / 进后台时自动释放连接，缓解低端机内存压力；
        // 下次访问由 getDB() 懒加载自动重连。单例常驻，observer 无需移除。
        //
        // - Note: 原先这里观察的是 `UIApplication.xxxNotification`，并额外套了 `#if canImport(UIKit)` ——
        //   那等于把 iOS 写死进基础设施。现在只认 `AIPlatformNotification` 的统一名字，
        //   谁把它们桥过来的（UIApplication / NSApplication）由接缝层负责。
        AIPlatformNotification.installBridges()
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleMemoryWarning),
                       name: AIPlatformNotification.memoryWarning,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleEnterBackground),
                       name: AIPlatformNotification.didEnterBackground,
                       object: nil)
    }

    private var db: Connection?

    /// 串行队列：所有数据库读写均在此队列执行，保证 `Connection` 的线程安全。
    ///
    /// SQLite.swift 的 `Connection` 并非线程安全，多线程同时操作同一连接会崩溃或数据错乱。
    /// 通过把所有访问收敛到一条串行队列，等价于「串行化访问」，避免并发问题。
    /// 约定：顶层公开方法在此队列上加锁；`getDB` / `transaction` / `executeRaw` / `executeInsert`
    /// 等原语方法不加锁（由调用方保证已在队列上），避免嵌套 `sync` 造成死锁。
    private let dbQueue = DispatchQueue(label: "com.starry.sqlite.storage")

    /// 队列标识键：用来判断「当前执行流是否已经在 `dbQueue` 上」。见 `onQueue`。
    ///
    /// 🔴 2026-10-23 补上**从未接线的那一半**（RAG 首跑真机即崩，见下方 `setSpecific` 注释）：
    ///    光有 `getSpecific` 的读侧没有用 —— 判据恒为「不在队列上」，可重入形同虚设。
    private static let queueKey = DispatchSpecificKey<UInt8>()

    /// 在 `dbQueue` 上串行执行一段操作。
    ///
    /// **可重入**：若当前已经在队列上（典型场景 = 某个事务/加锁方法的闭包内部），
    /// 直接**就地执行** body，而不是再 `dispatch.sync` 一次 —— 后者在**同一条串行队列**上
    /// 必然死锁（不崩、不报错，界面直接冻住，最难查）。
    ///
    /// 就地执行与「可重入锁」语义一致：此时访问的仍是同一个 `Connection`，
    /// 事务内还能读到未提交的中间数据（SQLite 本就是这么设计的）。
    ///
    /// ⚠️ 唯一仍需显式拒绝的嵌套是**事务套事务**（内层 `BEGIN` 会报错，而错误处理会把外层一起回滚）——
    /// 守卫在 `transaction` 里。
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return try body()
        }
        return try dbQueue.sync(execute: body)
    }

    /// 已成功建过索引的索引名集合（进程内缓存）
    ///
    /// `ensureIndexes` 在冷启动时会 `COUNT(*)` 判大表；一旦某索引已建成功即记入此集合，
    /// 后续调用直接跳过该索引，避免大表每次启动都全表扫描。仅在 `dbQueue` 内读写，无并发问题。
    /// 用索引名（而非表名）作键，保证同一表的多个候选索引各自独立判定。
    private var ensuredIndexes: Set<String> = []

    /// 获取数据库连接（懒加载单例）
    ///
    /// 仅在 `dbQueue` 上被访问，确保连接创建与使用始终在同一串行队列。
    /// - Returns: 可用的 `Connection` 实例，创建失败返回 `nil`
    /// - Note: 内部原语，不直接暴露给外部模块；外部请通过其他公开方法访问数据库。
    func getDB() -> Connection? {
        if db == nil {
            // ⚠️ 路径走接缝层：iOS = 沙盒 `Documents`（与拆分前**同一条路径**），
            //    macOS = `Application Support/<bundleID>`（`Documents` 在 Mac 沙盒下拿不到权限）。
            let path = AIPlatformPaths.appDataDirectory.path
            do {
                db = try Connection("\(path)/db.sqlite3")
            } catch {
                debugPrint("数据库初始化失败: \(error)")
            }
            db?.busyTimeout = 5.0
        }
        return db
    }

    /// 关闭数据库连接并释放 `Connection`，供内存警告 / App 进后台时回收资源。
    ///
    /// `db` 置 `nil` 后，`Connection` 随 ARC 释放并自动 `sqlite3_close`；
    /// 下次访问数据库时由 `getDB()` 懒加载自动重新建立连接，无需手动 reopen。
    /// 该方法在串行队列上执行，与所有读写操作串行化，不会与正在进行的事务冲突。
    public func close() {
        onQueue {
            db = nil
        }
    }

    /// 重新打开数据库连接。
    ///
    /// 实际等同于 `close()`：连接释放后，`getDB()` 会在下次访问时自动重连。
    /// 提供此方法仅为语义清晰（「主动触发重连」），日常使用一般无需显式调用。
    public func reopen() {
        close()
    }

    // - Note: 这两个回调原先被 `#if canImport(UIKit)` 包着 —— 因为通知名是 iOS 的。
    //   现在通知名统一成了 `AIPlatformNotification`，两平台都能注册，所以守卫撤掉了。
    @objc private func handleMemoryWarning() {
        close()
    }

    @objc private func handleEnterBackground() {
        close()
    }

    /// 创建（若不存在）或获取一张表
    ///
    /// 使用 `CREATE TABLE IF NOT EXISTS`，表已存在时跳过建表逻辑。
    /// 应在各业务 Manager 的建表闭包中调用，并传入列定义。
    /// - Parameters:
    ///   - name: 表名
    ///   - block: 建表回调，用于声明各列（主键、类型、约束等）
    /// - Returns: 建好的 `Table` 实例，失败返回 `nil`
    /// - Throws: 建表语句执行失败时抛出底层错误
    public func getTable(_ name: String, block: (TableBuilder) -> Void) throws -> Table? {
        try onQueue {
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            let table = Table(name)
            do {
                try db.run(
                    table.create(temporary: false, ifNotExists: true, withoutRowid: false, block: block)
                )
            } catch {
                debugPrint("建表失败 (\(name)): \(error)")
                throw error
            }
            return table
        }
    }

    // 增
    /// 插入一条记录
    ///
    /// 执行单条 `INSERT` 语句；错误向上抛出，由调用方决定如何处理（不再静默吞掉）。
    /// - Parameters:
    ///   - query: 待执行的 `Insert` 语句
    ///   - needLog: 是否打印插入结果日志，默认 `false`
    /// - Throws: 数据库不可用或插入失败时抛出
    public func insert(_ query: Insert, needLog: Bool = false) throws {
        try onQueue {
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            let rowId = try db.run(query)
            if needLog {
                debugPrint("数据库插入成功 \(rowId)")
            }
        }
    }

    /// 插入一条记录并返回自增 rowId
    ///
    /// 适用于需要获取数据库自动生成主键的场景。
    /// - Parameter query: 待执行的 `Insert` 语句
    /// - Returns: 插入成功后的 `rowid`
    /// - Throws: 数据库不可用或插入失败时抛出
    /// - Note: 方法名沿用历史拼写 `Retrun`，调用处请勿误改以免编译失败
    public func insertRetrunRowId(_ query: Insert) throws -> Int64 {
        try onQueue {
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            return try db.run(query)
        }
    }

    /// 批量插入（事务包裹）
    ///
    /// 将一组 `Insert` 语句在同一个事务内执行，全部成功才提交；
    /// 任意一条失败自动回滚，且整体只产生一次磁盘写入。供各业务层批量写入复用。
    /// - Parameter inserts: 待执行的 `Insert` 语句数组
    /// - Throws: 事务内任意一条插入失败时抛出错误
    /// - Note: 内部委托 `transaction`，自身不在 `dbQueue` 上重复加锁（避免嵌套死锁）
    public func batchInsert(_ inserts: [Insert]) throws {
        try transaction {
            guard let connection = getDB() else { return }
            for insert in inserts {
                try connection.run(insert)
            }
        }
    }

    /// 条件查询（不带排序）
    ///
    /// 支持可选的 `filter` 筛选与 `limit`/`offset` 分页，不指定排序。
    /// - Parameters:
    ///   - table: 目标表（为 `nil` 时直接返回空数组）
    ///   - filter: 筛选条件，默认 `nil` 表示查询全表
    ///   - limit: 返回最大条数，默认 `nil` 表示不限制
    ///   - offset: 跳过条数，需配合 `limit` 使用
    /// - Returns: 匹配的原始行数组
    /// - Throws: 数据库不可用时抛出
    public func search(_ table: Table?, filter: Expression<Bool>? = nil, limit: Int? = nil, offset: Int? = nil) throws -> [Row] {
        try onQueue {
            guard let `table` = table else {
                return []
            }
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            var query = table
            if let f = filter {
                query = query.filter(f)
            }
            if let l = limit {
                if let o = offset {
                    query = query.limit(l, offset: o)
                } else {
                    query = query.limit(l)
                }
            }
            return try Array(db.prepare(query))
        }
    }

    // 根据条件删除
    /// 根据条件删除记录
    ///
    /// 支持可选 `filter` 与 `limit`/`offset`；不传 `filter` 时删除整张表数据。
    /// - Parameters:
    ///   - table: 目标表（为 `nil` 时直接返回）
    ///   - filter: 删除条件，默认 `nil` 表示清空整表
    ///   - limit: 最大删除条数，默认 `nil` 表示不限制
    ///   - offset: 跳过条数，需配合 `limit` 使用
    ///   - needLog: 是否打印删除条数日志，默认 `false`
    /// - Throws: 数据库不可用时抛出
    public func delete(_ table: Table?, filter: Expression<Bool>? = nil, limit: Int? = nil, offset: Int? = nil, needLog: Bool = false) throws {
        try onQueue {
            guard let `table` = table else {
                return
            }
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            var query = table
            if let f = filter {
                query = query.filter(f)
            }
            if let l = limit {
                if let o = offset {
                    query = query.limit(l, offset: o)
                } else {
                    query = query.limit(l)
                }
            }
            let count = try db.run(query.delete())
            if needLog {
                debugPrint("数据库删除的条数为：\(count)")
            }
        }
    }

    // 改
    /// 更新记录
    ///
    /// 执行单条 `UPDATE` 语句（通常结合 `table.filter(...).update(...)` 构造）。
    /// - Parameter query: 待执行的 `Update` 语句
    /// - Throws: 数据库不可用或更新失败时抛出
    public func update(_ query: Update) throws {
        try onQueue {
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            try db.run(query)
        }
    }

    // 获取当前数据库中的数据量
    /// 统计表中记录总数
    ///
    /// 等价于 `SELECT COUNT(*) FROM table`。
    /// - Parameter table: 目标表（为 `nil` 时返回 0）
    /// - Returns: 记录总条数
    /// - Throws: 数据库不可用时抛出（异常不再被静默吞掉返回 0）
    public func scalar(_ table: Table?) throws -> Int {
        try onQueue {
            guard let `table` = table else {
                return 0
            }
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            return try db.scalar(table.count)
        }
    }

    // 获取当前数据库中满足条件的条数
    /// 统计满足多个条件的记录条数
    ///
    /// 将 `conditions` 数组按 `AND` 组合后计数，等价于 `SELECT COUNT(*) FROM table WHERE c1 AND c2 ...`。
    /// - Parameters:
    ///   - table: 目标表（为 `nil` 时返回 0）
    ///   - conditions: 条件表达式数组，多个条件以 `AND` 连接
    /// - Returns: 满足条件的记录条数
    /// - Throws: 数据库不可用时抛出
    public func scalar(_ table: Table?, where conditions: [Expression<Bool>]) throws -> Int {
        try onQueue {
            guard let `table` = table else {
                return 0
            }
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            let trueExpression = Expression<Bool>(value: true)
            let combinedCondition = conditions.reduce(trueExpression) { $0 && $1 }
            return try db.scalar(table.filter(combinedCondition).count)
        }
    }
}

extension SQLiteManager {

    // 查
    /// 条件查询（带排序）
    ///
    /// 在 `search` 基础上增加 `orderBy` 排序支持；同样支持 `filter` 与 `limit`/`offset` 分页。
    /// - Note: 内部委托带排序的 `search`，自身不在 `dbQueue` 上重复加锁
    /// - Parameters:
    ///   - table: 目标表（为 `nil` 时直接返回空数组）
    ///   - filter: 筛选条件，默认 `nil` 表示查询全表
    ///   - orderBy: 排序表达式（可变参数，如 `column.desc`）
    ///   - limit: 返回最大条数，默认 `nil` 表示不限制
    ///   - offset: 跳过条数，需配合 `limit` 使用
    /// - Returns: 匹配并排序后的原始行数组
    /// - Throws: 数据库不可用时抛出
    public func search(_ table: Table?, filter: Expression<Bool>? = nil, orderBy: Expressible..., limit: Int? = nil, offset: Int? = nil) throws -> [Row] {
        try onQueue {
            guard let `table` = table else {
                return []
            }
            guard let db = getDB() else {
                throw SQLiteManagerError.connectionUnavailable
            }
            var query = table
            if let f = filter {
                query = query.filter(f)
            }
            query = query.order(orderBy)
            if let l = limit {
                if let o = offset {
                    query = query.limit(l, offset: o)
                } else {
                    query = query.limit(l)
                }
            }
            return try Array(db.prepare(query))
        }
    }

    /// 分页查询，返回原始行（业务层负责映射为模型）
    ///
    /// 内部委托给带排序的 `search`，仅将 `page/pageSize` 转换为 `limit/offset`，
    /// 避免各业务层重复编写分页逻辑。支持传入 `filter` 条件，实现「带筛选的分页」。
    /// - Note: 内部委托 `search`，自身不在 `dbQueue` 上重复加锁（避免嵌套死锁）
    /// - Parameters:
    ///   - table: 目标表
    ///   - filter: 筛选条件（可选，默认 `nil` 表示不过滤）
    ///   - orderBy: 排序表达式（单列，如 `column.desc`）
    ///   - page: 页码，从 0 开始
    ///   - pageSize: 每页条数
    /// - Returns: 当前页的原始行数组
    /// - Throws: 数据库不可用时抛出
    public func fetchPage(_ table: Table, filter: Expression<Bool>? = nil, orderBy: Expressible, page: Int, pageSize: Int) throws -> [Row] {
        try search(table, filter: filter, orderBy: orderBy, limit: pageSize, offset: page * pageSize)
    }
}

// MARK: - 数据库迁移支持
extension SQLiteManager {

    // MARK: - 按表版本追踪（替代全局 PRAGMA user_version，支持多业务独立迁移）

    /// 读取指定表的 schema 版本号（从 `_migrations` 元表读取）
    ///
    /// 多业务共用同一数据库文件时，全局 `user_version` 只有一个数、无法区分各表版本，
    /// 故改为在 `_migrations(name PRIMARY KEY, version)` 元表里按表各自记录。
    /// - Parameter name: 表名
    /// - Returns: 该表当前版本号；元表中无记录时返回 0（视为全新或待初始化）
    /// - Throws: 数据库不可用时抛出
    public func currentVersion(forTable name: String) throws -> Int {
        try onQueue {
            try ensureMigrationsTable()
            guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
            let table = Table(migrationsTableName)
            let nameCol = Expression<String>("name")
            let versionCol = Expression<Int>("version")
            guard let row = try db.pluck(table.filter(nameCol == name)) else { return 0 }
            return row[versionCol]
        }
    }

    /// 设置指定表的 schema 版本号（写入 `_migrations` 元表）
    ///
    /// 若该表已有版本记录则更新，否则插入新行。
    /// - Parameters:
    ///   - version: 目标版本号
    ///   - name: 表名
    /// - Throws: 数据库不可用时抛出
    public func setVersion(_ version: Int, forTable name: String) throws {
        try onQueue {
            try ensureMigrationsTable()
            guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
            let table = Table(migrationsTableName)
            let nameCol = Expression<String>("name")
            let versionCol = Expression<Int>("version")
            let row = table.filter(nameCol == name)
            if try db.run(row.update(versionCol <- version)) == 0 {
                try db.run(table.insert(nameCol <- name, versionCol <- version))
            }
        }
    }

    /// 确保 `_migrations` 元表存在（不加锁原语，由上面的版本方法在 `dbQueue` 内调用，避免嵌套死锁）
    private func ensureMigrationsTable() throws {
        guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
        let sql = "CREATE TABLE IF NOT EXISTS \(migrationsTableName) (name TEXT PRIMARY KEY, version INTEGER NOT NULL DEFAULT 0)"
        let stmt = try db.prepare(sql)
        try stmt.run()
    }

    /// 执行原始 SQL（用于 ALTER TABLE / BEGIN TRANSACTION 等 SQLite.swift 高层 API 不支持的语句）
    /// - Note: 作为事务内部原语使用，自身不在 `dbQueue` 上加锁（由 `transaction` 统一调度）
    /// - Throws: SQL 执行失败时抛出
    public func executeRaw(_ sql: String) throws {
        guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
        let stmt = try db.prepare(sql)
        try stmt.run()
    }

    /// 执行原始 SQL，失败时抛出异常（用于事务内部，确保失败可被捕获）
    /// - Note: 作为事务内部原语使用，自身不在 `dbQueue` 上加锁（由 `transaction` 统一调度）
    /// - Throws: SQL 执行失败时抛出
    public func executeRawThrows(_ sql: String) throws {
        guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
        let stmt = try db.prepare(sql)
        try stmt.run()
    }

    /// 探测某张表是否已有某列（`PRAGMA table_info`）。
    ///
    /// **补列迁移的结构探测原语**。`getTable` 是 `CREATE TABLE IF NOT EXISTS` ——
    /// 已存在的表不会补列，而 `_migrations` 的版本号又与真实结构可能不一致
    /// （本工程踩过：补列被跳过 → 读列时 Fatal）。所以补列前必须先探测，
    /// ⛔ 不能只靠版本号分支。
    ///
    /// - Parameters:
    ///   - table: 表名（代码内的常量，不涉外部输入）
    ///   - column: 列名
    /// - Returns: 该列已存在（或表不存在，视为「无此列」）时 true/false
    /// - Throws: 数据库不可用时抛出
    public func tableHasColumn(table: String, column: String) throws -> Bool {
        try onQueue {
            guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
            // PRAGMA 不支持参数绑定，表名/列名都是调用方代码里的常量 ⇒ 无注入面
            let stmt = try db.prepare("PRAGMA table_info(\"\(table)\")")
            for row in stmt {
                // table_info 的列序：cid | name | type | notnull | dflt_value | pk ⇒ name 在下标 1
                if (row[1] as? String) == column { return true }
            }
            return false
        }
    }

    /// 在事务内执行一条 `Insert`（**不加锁原语**，由 `transaction` 统一调度）
    ///
    /// 与 `executeRawThrows` 完全对称，但保留了 SQLite.swift 的**参数绑定** —— 这是它存在的理由：
    /// 合并事务时业务要写的是**自由文本**（消息正文、会话标题），手拼 SQL 得自己转义引号，
    /// 正是本项目最不想要的写法。有了它，事务里可以照常用 `table.insert(...)` 构造，一行 SQL 都不用拼。
    ///
    /// ⛔ 只能事务内调用。事务外请用 `insert(_:)` —— 那个方法自带 `dbQueue` 串行化；
    /// 直接调本方法没有外层的顺序保证，也没有事务保护。
    /// - Throws: 数据库不可用或执行失败时抛出
    public func executeInsert(_ query: Insert) throws {
        guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
        try db.run(query)
    }

    /// 在事务内执行一条 `Update`（**不加锁原语**，由 `transaction` 统一调度）
    ///
    /// 语义与限制同 `executeInsert`：事务内专用、保留参数绑定、不自己加锁。
    /// - Throws: 数据库不可用或执行失败时抛出
    public func executeUpdate(_ query: Update) throws {
        guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
        try db.run(query)
    }

    /// 在事务内执行一条 `Delete`（**不加锁原语**，由 `transaction` 统一调度）
    ///
    /// 语义与限制同 `executeInsert`：事务内专用、保留参数绑定、不自己加锁。
    /// 存在的理由与另两个原语不同 —— `delete(_:filter:)` 是**带锁**方法，事务闭包里
    /// 调它靠的是 `onQueue` 的可重入（就地执行）；可重入判据（`getSpecific`）一旦被
    /// 谁"优化"掉，症状是**死锁 + SIGTRAP**而不是编译错（2026-10-23 真踩过，见 init 里
    /// `setSpecific` 那段）。⇒ 事务里的删除**只走本原语**，⛔ 别在事务里调 `delete`。
    /// - Throws: 数据库不可用或执行失败时抛出
    public func executeDelete(_ query: Delete) throws {
        guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
        try db.run(query)
    }

    /// 在事务中执行一组操作，任意一步失败则自动回滚并重新抛出异常
    ///
    /// 所有操作在 `dbQueue` 上串行执行，保证线程安全。
    /// ```swift
    /// do {
    ///     try SQLiteManager.shared.transaction {
    ///         try SQLiteManager.shared.executeInsert(messageInsert)   // 绑定版：自由文本安全
    ///         try SQLiteManager.shared.executeUpdate(conversationUpdate)
    ///         try SQLiteManager.shared.executeRawThrows("DROP TABLE ...")
    ///     }
    /// } catch {
    ///     // 事务已自动回滚，数据库恢复到操作前状态
    /// }
    /// ```
    ///
    /// - Note: 闭包内**可以**调用带锁方法（`search` / `insert` …）—— `onQueue` 是可重入的，
    ///         会就地执行而不是二次 `sync`。写操作仍推荐用 `executeInsert` / `executeUpdate` /
    ///         `executeRawThrows` 原语：语义更明确，且不会被误认为「开了一个新事务」。
    /// - Note: ⛔ 不支持嵌套（闭包内再调 `transaction` / `batchInsert` 会抛 `nestedTransaction`）。
    ///         真需要嵌套语义请改用 `SAVEPOINT`。
    /// - Throws: 事务内任意操作失败时抛出（已自动 ROLLBACK）
    public func transaction(_ block: () throws -> Void) throws {
        // ⛔ 事务不支持嵌套。`onQueue` 现在是可重入的，所以这里必须**显式**拦：
        // 若放行，内层的裸 `BEGIN` 会报 "cannot start a transaction within a transaction"，
        // 而下面的 catch 会把它当成「事务失败」去 `ROLLBACK` —— 把**外层**写了一半的事务
        // 一起回滚掉。那是静默丢数据，比直接抛错危险得多。
        // 真需要嵌套语义请改用 SAVEPOINT（当前没有这个需求）。
        guard DispatchQueue.getSpecific(key: Self.queueKey) == nil else {
            assertionFailure("[SQLiteManager] 事务嵌套：transaction 闭包内又调用了 transaction / batchInsert")
            throw SQLiteManagerError.nestedTransaction
        }
        try onQueue {
            guard let db = getDB() else { throw SQLiteManagerError.connectionUnavailable }
            let begin = try db.prepare("BEGIN TRANSACTION")
            try begin.run()
            do {
                try block()
                let commit = try db.prepare("COMMIT")
                try commit.run()
            } catch {
                debugPrint("事务失败，自动回滚: \(error)")
                let rollback = try? db.prepare("ROLLBACK")
                _ = try? rollback?.run()   // 回滚失败也只能听天由命（原错误优先抛出）
                throw error
            }
        }
    }
}

// MARK: - 索引支持
extension SQLiteManager {

    /// 按策略为指定表建立索引
    ///
    /// - 业务在 `tableReady` 建表后调用，声明「想给哪些列建索引」与「采用哪种策略」。
    /// - `.auto` 模式由 Manager 自己 `COUNT(*)` 判断是否为大表，仅大表才真正建索引，
    ///   避免小表浪费写入与存储。
    /// - 使用 `CREATE INDEX IF NOT EXISTS`，重复调用安全；表从少到多增长后，下次启动会自动补建。
    /// - 标识符（表名/列名/索引名）仅接受 `[A-Za-z0-9_]`，防止拼接 SQL 时被注入。
    /// - Note: 顶层方法已在 `dbQueue` 上加锁；内部使用不加锁原语（`rowCount` / `executeRawThrows`）
    ///         避免嵌套 `sync` 死锁。建索引为尽力而为，失败仅记录日志，不影响建表主流程。
    /// - Parameters:
    ///   - specs: 索引候选列表
    ///   - policy: 索引策略，默认 `.auto(threshold: 5000)`
    public func ensureIndexes(_ specs: [IndexSpec], policy: IndexPolicy = .auto(threshold: 5000)) {
        onQueue { [weak self] in
            guard let self else { return }
            for spec in specs {
                // 已建过索引的直接跳过，避免大表每次冷启动都 COUNT(*) 全表扫描
                guard !self.ensuredIndexes.contains(spec.name) else { continue }
                guard isValidIdentifier(spec.name),
                      isValidIdentifier(spec.table),
                      isValidIdentifier(spec.column) else {
                    debugPrint("索引声明含非法标识符，已跳过: \(spec)")
                    continue
                }
                let shouldCreate: Bool
                switch policy {
                case .always:
                    shouldCreate = true
                case .never:
                    shouldCreate = false
                case .auto(let threshold):
                    // 让 Manager 自行判断「是否为大表」
                    let count = self.rowCount(of: spec.table)
                    shouldCreate = count >= threshold
                }
                if shouldCreate {
                    let sql = "CREATE INDEX IF NOT EXISTS \(spec.name) ON \(spec.table)(\(spec.column))"
                    do {
                        try self.executeRawThrows(sql)
                        // 建成功才标记：auto 模式下未达阈值的索引不标记，待表增长后下次启动再判定
                        self.ensuredIndexes.insert(spec.name)
                    } catch {
                        debugPrint("建立索引失败 \(spec.name): \(error)")
                    }
                }
            }
        }
    }

    /// 统计指定表的行数（不加锁原语，供 `ensureIndexes` 在队列内调用，避免嵌套死锁）
    ///
    /// 等价于 `SELECT COUNT(*) FROM table`。表不存在或查询失败时返回 0。
    /// - Parameter table: 表名
    /// - Returns: 行数
    public func rowCount(of table: String) -> Int {
        guard let db = getDB() else { return 0 }
        do {
            // Connection.scalar(String) 返回 Any?，COUNT(*) 实际为 Int64，需显式转换
            let raw = try db.scalar("SELECT COUNT(*) FROM \(table)")
            if let int64 = raw as? Int64 {
                return Int(int64)
            }
            if let int = raw as? Int {
                return int
            }
            return 0
        } catch {
            return 0
        }
    }

    /// 校验 SQL 标识符合法性（仅允许字母、数字、下划线，且非空）
    ///
    /// `ensureIndexes` 会把这些标识符直接拼进 SQL，故需拦截空格/分号等危险字符，防止注入。
    private func isValidIdentifier(_ s: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return !s.isEmpty && s.rangeOfCharacter(from: allowed.inverted) == nil
    }
}
