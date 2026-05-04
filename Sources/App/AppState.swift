//
//  AppState.swift
//  App
//
//  全局状态管理：账号列表 / 后台任务。
//
//  并发：用 ObservableObject + @Published（兼容 macOS 13）。
//  所有 Account 写操作都过 AccountStore actor 串行；UI 更新用 @MainActor。
//

import Foundation
import SwiftUI
import Core
import WindsurfClient
import External
import Wrapper
import Relay

/// 简短瞬时通知。
public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public let kind: Kind
    public let text: String

    public enum Kind: Equatable { case success, warning, error, info }
}

/// HeaderBar 顶条「当前激活号」展示信息。
public struct ActiveAccountInfo: Equatable, Sendable {
    public enum Source: String, Sendable { case recentRPC, poolBest }
    public let email: String?
    public let accountId: String
    public let score: Int64
    public let weeklyPercent: Int?
    public let dailyPercent: Int?
    public let inFlight: Int
    public let lastRPCStatus: Int?
    public let lastRPCAt: Date?
    public let source: Source

    /// 显示名：email local part；fallback accountId 前 8 位。
    public var displayName: String {
        if let e = email, let at = e.firstIndex(of: "@") {
            return String(e[..<at])
        }
        return email ?? String(accountId.prefix(8))
    }
}

private enum SoftJwtRefreshReason: String, Sendable {
    case startup
    case periodic
    case quota
}

@MainActor
public final class AppState: ObservableObject {
    // MARK: Published state

    @Published public var accounts: [Account] = []
    @Published public var loading: Bool = false
    @Published public var migrationBanner: MigrationResult?
    @Published public var toast: Toast?
    @Published public var refreshingIds: Set<UUID> = []
    @Published public var switchingIds: Set<UUID> = []

    // Relay / wrapper 状态。
    @Published public var relayStatus: RelayManagerStatus = RelayManagerStatus()
    @Published public var wrapperStatuses: [WindsurfApp: WrapperStatus] = [:]
    @Published public var wrapperBusy: Bool = false

    // 调度中心快照。
    @Published public var poolSnapshot: [EntrySnapshot] = []
    @Published public var poolHealth: HealthSummary = HealthSummary(
        drought: false, droughtThreshold: 5, totalAccounts: 0,
        availableAccounts: 0, cooledAccounts: 0, bannedAccounts: 0,
        lowestWeeklyPercent: nil, lowestDailyPercent: nil
    )
    /// 合并 api + inference 两路的实时 RPC stats（5s 一刷，与 pool 同 ticker）。
    @Published public var statsSnapshot: StatsSnapshot = StatsSnapshot(
        total: 0, success: 0, failure: 0, lastMinuteCount: 0, recent: []
    )

    private var poolSyncTask: Task<Void, Never>?

    // 关键守卫：SwiftUI App.init() 会被反复调用（Scene 重建），
    // bootstrap 必须只跑一次。否则多个 ticker 并发写 Pool，产生
    // 0/93/0/93 跳变，UI 看到的是其中一个被清空的瞬间。
    private var bootstrapped = false

    // MARK: Backing services

    private var store: AccountStore?
    private let ottClient = GetOTTClient()
    private let planClient = GetPlanStatusClient()
    private let softJwtRefreshClient = SoftJwtRefreshClient()
    /// 全池循环刷 quota ticker：1min 一轮，全部号都被刷一遍。
    private var quotaTickerTask: Task<Void, Never>?
    /// active 账号高频刷 ticker：15s 一次，只刷当前 active 一个号——
    /// LS 真在烧 quota 的就是它，比全池 60s 一轮密集 4×。
    private var activeQuotaTickerTask: Task<Void, Never>?
    /// 软触发 GetUserJwt：StartCascade 后立即 cancel/delete，默认 2.5min 一次。
    private var softJwtRefreshTask: Task<Void, Never>?
    private var softJwtRefreshInFlight = false
    private var lastSoftJwtRefreshAt: Date?

    /// 批量入号防限流：外部 API 同时入 N 号时，串行化 quota 刷新。
    /// 每槽位间隔 1.5s，与 refreshAllAccounts 串行节奏一致。
    private let externalRefreshGate = RefreshGate(minGapMs: 1500)

    public let relayConfig: RelayConfig
    public let relayManager: RelayManager

    public init() {
        let cfg = RelayConfig.default
        self.relayConfig = cfg
        self.relayManager = RelayManager(config: cfg)
    }

    // MARK: Lifecycle

    /// App 启动钩子：旧版清理 → 数据迁移 → 加载账号 → 启动 relay / 后台刷新。
    /// 幂等——重复调直接返回，避免多个 ticker 并发写 Pool。
    public func bootstrap() async {
        guard !bootstrapped else {
            FileHandle.standardError.write(Data("[wss] bootstrap re-entry skipped (already done)\n".utf8))
            return
        }
        bootstrapped = true

        // 1. 旧 binary 清理（同步操作，快）
        let cleanup = LegacyCleanup.terminateLegacyBinaries()
        if !cleanup.killedPids.isEmpty {
            self.toast = Toast(kind: .info, text: "已停止旧版 binary（PID: \(cleanup.killedPids)）")
        }

        // 2. 数据迁移（仅在新数据为空时跑）
        if DataMigration.needsMigration() {
            do {
                let r = try DataMigration.migrateLegacy()
                if r.importedCount > 0 {
                    self.migrationBanner = r
                    self.toast = Toast(kind: .success, text: "已导入旧版 \(r.importedCount) 个账号")
                }
            } catch {
                self.toast = Toast(kind: .error, text: "数据迁移失败：\(error)")
            }
        }

        // 3. 打开 store + 加载账号 + 给 RelayManager 注入三类 sink
        do {
            let s = try await AccountStore.openDefault()
            self.store = s
            await relayManager.setUpdateSink(StoreUpdateSink(store: s))
            // AccountSink 注入：sink 入库后回调 reload + 触发 quota 刷新
            let weakSelf = self
            await relayManager.setAccountSink(StoreAccountSink(store: s) { [weak weakSelf] id in
                guard let s = weakSelf else { return }
                await s.reload()
                // 批量入号防限流：串行槽位 + 1.5s 间隔，避免 N 号同时打 GetPlanStatus
                await s.externalRefreshGate.waitForSlot()
                await s.refreshQuota(id: id)
                await s.toastOnMain(Toast(kind: .success, text: "外部 API 入号成功"))
            })
            // QuotaRefreshSink 注入：active 切换 / GetChatMessage 完成后触发 quota 拉新；
            // 普通事件 5s 节流，force 事件绕过 fetchedAt 节流。
            await relayManager.setQuotaRefreshSink(StoreQuotaRefreshSink { [weak weakSelf] accountIdStr, force in
                guard let s = weakSelf, let uuid = UUID(uuidString: accountIdStr) else { return }
                if force {
                    await s.refreshQuota(id: uuid)
                    await s.requestSoftJwtRefreshIfActiveQuotaExhausted(accountId: uuid)
                } else {
                    await s.refreshQuotaThrottled(id: uuid, minGapSeconds: 5)
                }
            })
            await reload()
        } catch {
            self.toast = Toast(kind: .error, text: "无法打开数据目录：\(error)")
        }

        // 4. 后台全池 quota 刷新
        startQuotaTicker()
        // 4b. active 账号高频刷新 ticker（15s 一次，刷新当前 active）
        startActiveQuotaTicker()

        // 5. 先把现有账号灌进 Pool —— 必须在 start() 之前，否则端口已开但池为空，
        // LS 在 0~5s 启动窗口里所有 lease 都拿不到号 → 502 Bad Gateway。
        await syncPoolOnce()

        // 6. 启动 relay（stable/next 各自 api + inference 明文端口）
        do {
            try await relayManager.start()
            self.relayStatus = await relayManager.status()
        } catch {
            self.toast = Toast(kind: .error, text: "Relay 启动失败：\(error)")
        }

        // 7. 检测 wrapper 状态
        refreshWrapperStatuses()

        // 8. 启动 Pool 同步 ticker：每 5s 把 store accounts → Pool
        startPoolSyncTicker()
        // 9. 软触发 GetUserJwt：启动后一发，之后每 2.5min 插在 Windsurf 自身 5min 周期中间。
        startSoftJwtRefreshTicker()
    }

    /// 5s ticker：把 store 当前账号集合同步到 Pool（race-safe merge）。
    /// 第一次同步立即触发。幂等——已存在 ticker 直接返回。
    private func startPoolSyncTicker() {
        if poolSyncTask != nil {
            FileHandle.standardError.write(Data("[wss] startPoolSyncTicker skip (already running)\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("[wss] startPoolSyncTicker called\n".utf8))
        poolSyncTask = Task { @MainActor in
            FileHandle.standardError.write(Data("[wss] poolSyncTask body started\n".utf8))
            await self.syncPoolOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await self.syncPoolOnce()
            }
        }
    }

    public func syncPoolOnce() async {
        let seeds = accounts.map { acc -> PoolAccountSeed in
            PoolAccountSeed(
                id: acc.id.uuidString,
                sessionToken: acc.sessionToken,
                email: acc.jwtInfo?.email,
                dailyPercent: acc.planStatus?.dailyPercent,
                weeklyPercent: acc.planStatus?.weeklyPercent,
                cooldownUntil: acc.cooldownUntil.map { Int64($0.timeIntervalSince1970) },
                consecutiveFailures: acc.consecutiveFailures,
                lastUsedByRelay: acc.lastUsedByRelay.map { Int64($0.timeIntervalSince1970) },
                internalErrorStreak: acc.internalErrorStreak,
                banSignalCount: acc.banSignalCount,
                banSignalFirstAt: acc.banSignalFirstAt.map { Int64($0.timeIntervalSince1970) },
                bannedUntil: acc.bannedUntil.map { Int64($0.timeIntervalSince1970) }
            )
        }
        FileHandle.standardError.write(Data("[wss] syncPoolOnce: feeding \(seeds.count) seeds to Pool\n".utf8))
        await relayManager.syncPool(seeds)
        let snap = await relayManager.poolSnapshot()
        let health = await relayManager.poolHealth()
        let stats = await relayManager.combinedStatsSnapshot()
        FileHandle.standardError.write(Data("[wss] syncPoolOnce: pool=\(snap.count) total=\(health.totalAccounts) rpc.total=\(stats.total) rpc.lastmin=\(stats.lastMinuteCount)\n".utf8))
        self.poolSnapshot = snap
        self.poolHealth = health
        self.statsSnapshot = stats
    }

    /// 重新扫描 stable + next 的 wrapper 状态。
    public func refreshWrapperStatuses() {
        var map: [WindsurfApp: WrapperStatus] = [:]
        for app in WindsurfApp.allCases {
            let w = Wrapper(
                app: app,
                relayPort: relayConfig.apiBindPort(for: app),
                inferencePort: relayConfig.inferenceBindPort(for: app)
            )
            map[app] = w.status()
        }
        self.wrapperStatuses = map
    }

    /// 一次性给两个 app 装 wrapper（osascript 弹一次密码框）。
    public func installAllWrappers() async {
        wrapperBusy = true
        defer { wrapperBusy = false }
        do {
            _ = try await Task.detached { [config = relayConfig] in
                try Wrapper.installBoth(
                    stableRelayPort: config.apiBindPort(for: .stable),
                    stableInferencePort: config.inferenceBindPort(for: .stable),
                    nextRelayPort: config.apiBindPort(for: .next),
                    nextInferencePort: config.inferenceBindPort(for: .next)
                )
            }.value
            refreshWrapperStatuses()
            self.toast = Toast(kind: .success, text: "已安装 wrapper")
        } catch {
            refreshWrapperStatuses()
            self.toast = Toast(kind: .error, text: "安装失败：\(error)")
        }
    }

    /// 卸载指定 app 的 wrapper（恢复原 LS binary）。
    public func uninstallWrapper(_ app: WindsurfApp) async {
        wrapperBusy = true
        defer { wrapperBusy = false }
        do {
            let w = Wrapper(
                app: app,
                relayPort: relayConfig.apiBindPort(for: app),
                inferencePort: relayConfig.inferenceBindPort(for: app)
            )
            _ = try await Task.detached { [w] in
                try w.uninstall()
            }.value
            refreshWrapperStatuses()
            self.toast = Toast(kind: .success, text: "已卸载 \(app.displayName) wrapper")
        } catch {
            refreshWrapperStatuses()
            self.toast = Toast(kind: .error, text: "卸载失败：\(error)")
        }
    }

    public func refreshRelayStatus() async {
        self.relayStatus = await relayManager.status()
    }

    /// 从 store 重新加载账号列表。排序优先级：
    ///   1. 状态：可用 > 冷却 > 封禁（让用户先看到能用的号）
    ///   2. 剩余量分数 desc：min(weeklyPercent, dailyPercent) 或月度 credits 占比；nil 沉底
    ///   3. lastSwitchedAt / addedAt desc（同分时新近用过的更靠前）
    public func reload() async {
        guard let store = store else { return }
        let list = await store.list()
        self.accounts = list.sorted { lhs, rhs in
            // 1. 状态分桶：0=可用, 1=冷却, 2=封禁（数值小的优先）
            func bucket(_ a: Account) -> Int {
                if a.isBanned { return 2 }
                if a.isCoolingDown { return 1 }
                return 0
            }
            let lb = bucket(lhs), rb = bucket(rhs)
            if lb != rb { return lb < rb }

            // 2. 剩余量分数 desc，nil 沉底
            let ls = lhs.remainingScore
            let rs = rhs.remainingScore
            switch (ls, rs) {
            case let (l?, r?):
                if l != r { return l > r }
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): break
            }

            // 3. tie-break：最近用过 / 最近添加 desc
            let lt = lhs.lastSwitchedAt ?? lhs.addedAt
            let rt = rhs.lastSwitchedAt ?? rhs.addedAt
            return lt > rt
        }
    }

    /// 顶部统计：未冷却数 / 冷却中 / 长封禁。
    public var summary: (active: Int, cooled: Int, banned: Int) {
        var a = 0, c = 0, b = 0
        for acc in accounts {
            if acc.isBanned { b += 1 }
            else if acc.isCoolingDown { c += 1 }
            else { a += 1 }
        }
        return (a, c, b)
    }

    /// 当前"激活号"——给 HeaderBar 顶条显示用。
    /// 规则（优先级从高到低）：
    ///   1. statsSnapshot.recent.first 的 accountId（最近一次 RPC 实际落到的号）
    ///   2. poolSnapshot 第一个 unavailableReason==nil 的号（下一次 lease 最可能落到的）
    ///   3. nil（号池为空/全冷却）
    public var activeAccount: ActiveAccountInfo? {
        let now = Int64(Date().timeIntervalSince1970)

        // 1. 最近 GetUserJwt 命中的号（1h 锚点）—— IDE cascade chat 真正在用的号。
        // LS 拿 JWT 后会缓存，下次重 GetUserJwt 之前 IDE 都用同一号；用这个号做 active
        // 才能保证 HeaderBar 显示的是 IDE 真正消耗 quota 的号。
        if let rpc = statsSnapshot.recent.first(where: { $0.path.contains("/GetUserJwt") }),
           let id = rpc.accountId,
           now - Int64(rpc.timestamp.timeIntervalSince1970) <= 3600 {
            return makeActiveInfo(rpc: rpc, accountId: id, source: .recentRPC)
        }

        // 2. 最近任意 RPC（5min 窗口）
        if let rpc = statsSnapshot.recent.first,
           let id = rpc.accountId,
           now - Int64(rpc.timestamp.timeIntervalSince1970) <= 300 {
            return makeActiveInfo(rpc: rpc, accountId: id, source: .recentRPC)
        }

        // 3. 池里 score 最高的可用号（snapshot 已按 score 降序排）
        if let best = poolSnapshot.first(where: { $0.unavailableReason == nil }) {
            return ActiveAccountInfo(
                email: best.email,
                accountId: best.accountId,
                score: best.score,
                weeklyPercent: best.weeklyPercent,
                dailyPercent: best.dailyPercent,
                inFlight: best.inFlight,
                lastRPCStatus: nil,
                lastRPCAt: nil,
                source: .poolBest
            )
        }
        return nil
    }

    /// 用 RecentRPC + 池快照拼成 ActiveAccountInfo。优先取池快照里的实时 quota。
    private func makeActiveInfo(rpc: RecentRPC, accountId id: String,
                                 source: ActiveAccountInfo.Source) -> ActiveAccountInfo {
        if let snap = poolSnapshot.first(where: { $0.accountId == id }) {
            return ActiveAccountInfo(
                email: snap.email ?? rpc.email,
                accountId: id,
                score: snap.score,
                weeklyPercent: snap.weeklyPercent,
                dailyPercent: snap.dailyPercent,
                inFlight: snap.inFlight,
                lastRPCStatus: rpc.status,
                lastRPCAt: rpc.timestamp,
                source: source
            )
        }
        return ActiveAccountInfo(
            email: rpc.email, accountId: id,
            score: 0, weeklyPercent: nil, dailyPercent: nil, inFlight: 0,
            lastRPCStatus: rpc.status, lastRPCAt: rpc.timestamp,
            source: source
        )
    }

    // MARK: Account ops

    public func addToken(_ token: String, label: String) async {
        guard let store = store else { return }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.toast = Toast(kind: .warning, text: "token 为空")
            return
        }
        var account = Account(label: label, sessionToken: trimmed)
        account.jwtInfo = JWTDecode.decode(trimmed)
        do {
            let saved = try await store.upsert(account)
            await reload()
            self.toast = Toast(kind: .success, text: "已添加：\(saved.displayName)")
            // 异步拉 quota；失败不阻塞
            await refreshQuota(id: saved.id)
        } catch {
            self.toast = Toast(kind: .error, text: "保存失败：\(error)")
        }
    }

    /// 批量添加 token：先去重（输入内 + 与已有 sessionToken 比对），再逐个 upsert，
    /// 最后只 reload 一次 + 异步刷 quota。toast 给出 added/dup/failed 汇总。
    /// - Parameters:
    ///   - tokens: 已经从用户输入解析出的 token 字符串列表（裸 JWT 或完整 cookie 值均可）
    ///   - label: 备注，所有新增账号共用；空字符串视为无备注
    public func addTokens(_ tokens: [String], label: String) async {
        guard let store = store else { return }

        // 1. 内部去重 + 与现有 sessionToken 去重
        var seen = Set<String>()
        var unique: [String] = []
        let existing = Set(accounts.map { $0.sessionToken })
        var skippedDup = 0
        for raw in tokens {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if seen.contains(t) { skippedDup += 1; continue }
            seen.insert(t)
            if existing.contains(t) { skippedDup += 1; continue }
            unique.append(t)
        }

        guard !unique.isEmpty else {
            if skippedDup > 0 {
                self.toast = Toast(kind: .warning, text: "全部 \(skippedDup) 个 token 已存在或重复")
            } else {
                self.toast = Toast(kind: .warning, text: "未识别到 token")
            }
            return
        }

        // 2. 逐个 upsert（save 一次写盘略费，但量级小可接受；保持一致性）
        var addedIds: [UUID] = []
        var failed = 0
        for t in unique {
            var account = Account(label: label, sessionToken: t)
            account.jwtInfo = JWTDecode.decode(t)
            do {
                let saved = try await store.upsert(account)
                addedIds.append(saved.id)
            } catch {
                failed += 1
            }
        }

        // 3. 一次性 reload + 汇总 toast
        await reload()
        var parts: [String] = []
        parts.append("新增 \(addedIds.count)")
        if skippedDup > 0 { parts.append("去重 \(skippedDup)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        let kind: Toast.Kind = failed > 0 ? .warning : .success
        self.toast = Toast(kind: kind, text: parts.joined(separator: " · "))

        // 4. 异步刷 quota（不阻塞 UI）
        for id in addedIds {
            Task { await self.refreshQuota(id: id) }
        }
    }

    public func deleteAccount(_ id: UUID) async {
        guard let store = store else { return }
        do {
            try await store.delete(id: id)
            await reload()
        } catch {
            self.toast = Toast(kind: .error, text: "删除失败：\(error)")
        }
    }

    public func renameAccount(_ id: UUID, label: String) async {
        guard let store = store else { return }
        do {
            try await store.update(id: id) { $0.label = label }
            await reload()
        } catch {
            self.toast = Toast(kind: .error, text: "重命名失败：\(error)")
        }
    }

    /// 节流版 refreshQuota：若该号 fetchedAt 距今 < minGap → 跳过。
    /// 给 active fast-ticker / GetChatMessage sink 用，防止短时高频重复刷。
    public func refreshQuotaThrottled(id: UUID, minGapSeconds: TimeInterval) async {
        if refreshingIds.contains(id) { return }
        if let acc = accounts.first(where: { $0.id == id }),
           let fetched = acc.planStatus?.fetchedAt,
           Date().timeIntervalSince(fetched) < minGapSeconds {
            return
        }
        await refreshQuota(id: id)
    }

    /// 刷新单号 plan status；返回成功时无 toast，失败 toast warning。
    ///
    /// 重试策略（refresh_retry，借自 cockpit-tools）：
    ///   - 最多尝试 3 次（初始 + 2 重试）
    ///   - 指数退避：500ms → 1000ms
    ///   - **遇 401/403/forbidden/unauthorized 立即放弃**（号本身的问题，重试无意义）
    ///   - 其它错误（429/5xx/网络抖动）值得重试
    @discardableResult
    public func refreshQuota(id: UUID) async -> Bool {
        guard let store = store else { return false }
        guard let account = await store.get(id: id) else { return false }
        refreshingIds.insert(id)
        defer { refreshingIds.remove(id) }

        var lastErr: Error?
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            do {
                let plan = try await planClient.getPlanStatus(token: account.sessionToken)
                try await store.update(id: id) {
                    $0.planStatus = plan
                    $0.lastError = nil
                    $0.jwtInfo = JWTDecode.decode($0.sessionToken)
                }
                await reload()
                return true // success
            } catch {
                lastErr = error
                if attempt == maxAttempts - 1 { break }
                // auth 错误不重试
                let s = "\(error)".lowercased()
                if s.contains("401") || s.contains("403")
                    || s.contains("unauthorized") || s.contains("forbidden") {
                    break
                }
                // 指数退避：500ms, 1000ms
                let delayMs = UInt64(500) << attempt
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }
        if let err = lastErr {
            _ = try? await store.update(id: id) { $0.lastError = "\(err)" }
            await reload()
            self.toast = Toast(kind: .warning, text: "刷新失败：\(account.displayName)")
        }
        return false
    }

    /// 刷新所有账号；串行，避免上游限流。
    public func refreshAllAccounts() async {
        let ids = accounts.map { $0.id }
        guard !ids.isEmpty else { return }
        loading = true
        defer { loading = false }
        var ok = 0, fail = 0
        for id in ids {
            let before = accounts.first(where: { $0.id == id })?.lastError
            await refreshQuota(id: id)
            let after = accounts.first(where: { $0.id == id })?.lastError
            if (before == nil && after == nil) || (before != nil && after == nil) {
                ok += 1
            } else if after != nil {
                fail += 1
            }
            // 单轮间隔 1.5s 防限流
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if fail == 0 {
            self.toast = Toast(kind: .success, text: "已刷新 \(ok) 个账号")
        } else {
            self.toast = Toast(kind: .warning, text: "刷新完成：成功 \(ok)，失败 \(fail)")
        }
    }

    /// 触发切号到指定 app。
    public func switchAccount(_ id: UUID, to app: WindsurfApp) async {
        guard let store = store else { return }
        guard let account = await store.get(id: id) else { return }
        switchingIds.insert(id)
        defer { switchingIds.remove(id) }
        do {
            let ott = try await ottClient.getOneTimeAuthToken(token: account.sessionToken)
            guard let url = app.switchURL(ott: ott) else {
                self.toast = Toast(kind: .error, text: "构造 deep link 失败")
                return
            }
            // NSWorkspace.open；不引入 AppKit 依赖到 Core/WindsurfClient，App target 直接用
            #if canImport(AppKit)
            _ = NSWorkspace.shared.open(url)
            #endif
            try await store.update(id: id) {
                $0.lastSwitchedAt = Date()
                $0.lastUsedApp = app
            }
            await reload()
            let preview = String(ott.prefix(12))
            self.toast = Toast(kind: .success, text: "切号成功 → \(app.displayName)（OTT \(preview)…）")
        } catch {
            self.toast = Toast(kind: .error, text: "切号失败：\(error)")
        }
    }

    /// MainActor 隔离的 toast 辅助——给 sink 回调用，避免它直接 set @Published。
    public func toastOnMain(_ t: Toast) async {
        self.toast = t
    }

    public func quit() {
        quotaTickerTask?.cancel()
        activeQuotaTickerTask?.cancel()
        softJwtRefreshTask?.cancel()
        poolSyncTask?.cancel()
        Task {
            await relayManager.stop()
            #if canImport(AppKit)
            await MainActor.run { NSApplication.shared.terminate(nil) }
            #else
            exit(0)
            #endif
        }
    }

    // MARK: Quota ticker

    /// 单 ticker：1min 一轮，全池所有号都被刷一遍。
    ///
    /// 历史复杂方案（active/hot/stale 三层 ticker + 多种"识别热号"启发式）废除。
    /// 现在简化为全池 1min 强制覆盖：
    ///   - 不判断哪个号 hot，全部刷
    ///   - 1min 节奏 ≪ GetUserJwt TTL（5-15min）→ 任何号在烧时都被刷 5+ 次
    ///   - 4 号并发 + 150ms 批间隔；150 号约 30s 跑完一轮 → ticker 60s 有 buffer
    private func startQuotaTicker() {
        quotaTickerTask?.cancel()
        quotaTickerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s 后第一轮
            while !Task.isCancelled {
                await self?.refreshAllAccountsRound()
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            }
        }
    }

    /// active 账号高频刷新 ticker：15s 一次，刷新 stable/next 各自当前 active。
    /// 与全池 60s ticker 并行，互不干扰；refreshQuotaThrottled 防重叠。
    private func startActiveQuotaTicker() {
        activeQuotaTickerTask?.cancel()
        activeQuotaTickerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s 后第一轮
            while !Task.isCancelled {
                await self?.refreshActiveAccountQuota()
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
            }
        }
    }

    /// 拉 active accountId → refreshQuota（10s 节流，防与 chat 触发重叠）。
    private func refreshActiveAccountQuota() async {
        let activeIds = await relayManager.currentActiveAccountIds()
        for activeIdStr in activeIds {
            guard let uuid = UUID(uuidString: activeIdStr) else { continue }
            await refreshQuotaThrottled(id: uuid, minGapSeconds: 10)
            await requestSoftJwtRefreshIfActiveQuotaExhausted(accountId: uuid)
        }
    }

    private func startSoftJwtRefreshTicker() {
        softJwtRefreshTask?.cancel()
        softJwtRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            await self?.performSoftJwtRefresh(reason: .startup, minGapSeconds: 0)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000_000)
                if Task.isCancelled { break }
                await self?.performSoftJwtRefresh(reason: .periodic, minGapSeconds: 120)
            }
        }
    }

    private func requestSoftJwtRefreshIfActiveQuotaExhausted(accountId: UUID) async {
        let activeIds = await relayManager.currentActiveAccountIds()
        guard activeIds.contains(accountId.uuidString) else { return }
        guard let account = accounts.first(where: { $0.id == accountId }),
              accountQuotaIsExhausted(account) else { return }
        await performSoftJwtRefresh(reason: .quota, minGapSeconds: 30)
    }

    private func performSoftJwtRefresh(reason: SoftJwtRefreshReason, minGapSeconds: TimeInterval) async {
        if softJwtRefreshInFlight { return }
        if let last = lastSoftJwtRefreshAt,
           Date().timeIntervalSince(last) < minGapSeconds {
            return
        }

        softJwtRefreshInFlight = true
        defer { softJwtRefreshInFlight = false }
        lastSoftJwtRefreshAt = Date()

        var totalReports = 0
        for app in WindsurfApp.allCases {
            guard let candidate = await prepareSoftJwtCandidate(app: app) else {
                FileHandle.standardError.write(Data("[wss] soft-jwt \(reason.rawValue) \(app.rawValue) skipped: no refreshed account with quota\n".utf8))
                continue
            }

            do {
                let reports = try await softJwtRefreshClient.triggerAll(
                    apiPort: relayConfig.apiBindPort(for: app),
                    apiKey: candidate.token
                )
                totalReports += reports.count
                if reports.isEmpty {
                    FileHandle.standardError.write(Data("[wss] soft-jwt \(reason.rawValue) \(app.rawValue) skipped: no matching LS process\n".utf8))
                } else {
                    let targets = reports.map { "\($0.pid):\($0.serverPort)" }.joined(separator: ",")
                    FileHandle.standardError.write(Data("[wss] soft-jwt \(reason.rawValue) \(app.rawValue) triggered GetUserJwt via StartCascade acct=\(String(candidate.accountId.prefix(8))) targets=\(targets)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("[wss] soft-jwt \(reason.rawValue) \(app.rawValue) failed: \(error)\n".utf8))
            }
        }
        if totalReports == 0 {
            FileHandle.standardError.write(Data("[wss] soft-jwt \(reason.rawValue) finished without targets\n".utf8))
        }
    }

    private func prepareSoftJwtCandidate(app: WindsurfApp) async -> NextJwtCandidate? {
        let maxProbeCount = min(max(accounts.count, 1), 8)
        var refreshedIds = Set<String>()

        for _ in 0..<maxProbeCount {
            await syncPoolOnce()
            guard let candidate = await relayManager.nextJwtCandidate(app: app, forceRotateFromActive: true),
                  let uuid = UUID(uuidString: candidate.accountId) else {
                return nil
            }

            if !refreshedIds.contains(candidate.accountId) {
                refreshedIds.insert(candidate.accountId)
                let refreshed = await refreshQuota(id: uuid)
                await syncPoolOnce()
                if !refreshed { continue }
            }

            guard let latest = await relayManager.nextJwtCandidate(app: app, forceRotateFromActive: true),
                  let latestUUID = UUID(uuidString: latest.accountId) else {
                return nil
            }
            if latest.accountId == candidate.accountId,
               accountHasUsableQuota(id: latestUUID) {
                return latest
            }
        }
        return nil
    }

    private func accountHasUsableQuota(id: UUID) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }),
              let plan = account.planStatus else {
            return false
        }
        let known = [plan.dailyPercent, plan.weeklyPercent].compactMap { $0 }
        guard !known.isEmpty else { return false }
        return known.allSatisfy { $0 > 0 }
    }

    private func accountQuotaIsExhausted(_ account: Account) -> Bool {
        account.planStatus?.dailyPercent == 0 || account.planStatus?.weeklyPercent == 0
    }

    /// 全池循环刷一轮：按 fetchedAt 升序（最旧先刷）批 4 号并发。
    /// - 单号节流：30s 内已刷过的跳过（避免上一轮没跑完下一轮重复刷）
    /// - 批间 150ms：防上游短时连接突发
    private func refreshAllAccountsRound() async {
        let snapshot = accounts
        if snapshot.isEmpty { return }
        let now = Date()
        let perAccountSkipWindow: TimeInterval = 30

        // 按 fetchedAt 升序（无 planStatus 视为最旧 → 优先刷）
        let ordered = snapshot.sorted { l, r in
            let lf = l.planStatus?.fetchedAt.timeIntervalSince1970 ?? 0
            let rf = r.planStatus?.fetchedAt.timeIntervalSince1970 ?? 0
            return lf < rf
        }

        let toRefresh: [UUID] = ordered.compactMap { (acc: Account) -> UUID? in
            if let ps = acc.planStatus,
               now.timeIntervalSince(ps.fetchedAt) < perAccountSkipWindow {
                return nil
            }
            return acc.id
        }
        if toRefresh.isEmpty { return }

        FileHandle.standardError.write(Data("[wss] refreshAllAccountsRound: \(toRefresh.count)/\(snapshot.count) accounts to refresh\n".utf8))
        let started = Date()
        let batchSize = 4
        var idx = 0
        while idx < toRefresh.count, !Task.isCancelled {
            let end = min(idx + batchSize, toRefresh.count)
            let batch = Array(toRefresh[idx..<end])
            await withTaskGroup(of: Void.self) { group in
                for id in batch {
                    group.addTask { [weak self] in
                        await self?.refreshQuota(id: id)
                    }
                }
            }
            idx = end
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms 批间隔
        }
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data("[wss] refreshAllAccountsRound: done in \(String(format: "%.1f", elapsed))s\n".utf8))
    }

}

// 仅 macOS：把 NSWorkspace 暴露给 AppState
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Store-backed UpdateSink

/// Pool 产出的 AccountUpdate → AccountStore 持久化桥。
/// 在 Relay 任务路径异步调用：lease/失败/成功后由 HTTPProxyHandler 触发。
/// 通过 actor (AccountStore) 串行写入，race 安全。
public struct StoreUpdateSink: UpdateSink {
    public let store: AccountStore

    public init(store: AccountStore) {
        self.store = store
    }

    public func apply(_ update: AccountUpdate) async {
        guard let uuid = UUID(uuidString: update.accountId) else { return }
        do {
            _ = try await store.update(id: uuid) { acc in
                acc.cooldownUntil = update.cooldownUntil.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                acc.consecutiveFailures = update.consecutiveFailures
                if let lu = update.lastUsedByRelay {
                    acc.lastUsedByRelay = Date(timeIntervalSince1970: TimeInterval(lu))
                }
                acc.internalErrorStreak = update.internalErrorStreak
                acc.banSignalCount = update.banSignalCount
                acc.banSignalFirstAt = update.banSignalFirstAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                acc.bannedUntil = update.bannedUntil.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
        } catch {
            // best-effort：写失败下次 ticker sync 还有机会修正
        }
    }
}

/// POST /__relay/accounts → AccountStore 入库桥。
/// 收到 token 后：JWT decode 立即做（拿 email 当 fallback label）→ store.upsert →
/// 异步通知 AppState reload + 触发一次 quota 刷新（不阻塞 sink 返回，避免 HTTP 端 hang）。
public struct StoreAccountSink: AccountSink {
    public let store: AccountStore
    public let onAdded: @Sendable (UUID) async -> Void   // AppState 注入：reload + quota 刷新

    public init(
        store: AccountStore,
        onAdded: @escaping @Sendable (UUID) async -> Void
    ) {
        self.store = store
        self.onAdded = onAdded
    }

    public func add(token: String, label: String?) async -> Result<(String, Bool), AccountSinkError> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(AccountSinkError("token empty"))
        }

        // 检查是否已存在（同 sessionToken 视为同号）
        let existing = await store.list().first(where: { $0.sessionToken == trimmed })
        let wasNew = existing == nil

        // JWT decode 立即做：失败也不阻塞入库。
        // label 解析顺序（RESTful PATCH 语义：缺字段 = 保留）：
        //   1. 传了非空 label → 用它（覆盖）
        //   2. 否则若已有账号 → 保留 existing.label（不被 JWT email 覆盖）
        //   3. 否则用 JWT email（首次入号的 fallback）
        //   4. 否则空串（用户后续可在 UI 重命名）
        let jwt = JWTDecode.decode(trimmed)
        let resolvedLabel: String = {
            if let l = label, !l.isEmpty { return l }
            if let ex = existing { return ex.label }
            if let e = jwt?.email, !e.isEmpty { return e }
            return ""
        }()

        var account = existing ?? Account(label: resolvedLabel, sessionToken: trimmed)
        account.sessionToken = trimmed
        account.label = resolvedLabel
        account.jwtInfo = jwt

        do {
            let saved = try await store.upsert(account)
            // 异步触发 reload + quota 刷新——sink 不等
            let id = saved.id
            Task { await onAdded(id) }
            return .success((saved.id.uuidString, wasNew))
        } catch {
            return .failure(AccountSinkError("store upsert failed: \(error)"))
        }
    }
}

// MARK: - Store-backed QuotaRefreshSink

/// QuotaRefreshSink 的 closure 实现：把 accountId 字符串桥到 AppState
/// 的 refreshQuota / refreshQuotaThrottled（MainActor 隔离）。
/// 节流由 AppState 侧控制（refreshQuotaThrottled 检查 fetchedAt）。
public struct StoreQuotaRefreshSink: QuotaRefreshSink {
    public let onRefresh: @Sendable (String, Bool) async -> Void

    public init(onRefresh: @escaping @Sendable (String, Bool) async -> Void) {
        self.onRefresh = onRefresh
    }

    public func requestRefresh(accountId: String, force: Bool) async {
        await onRefresh(accountId, force)
    }
}

// MARK: - RefreshGate

/// 串行化 + 节流限速器。
///
/// 用途：批量入号时（如 43 号同时 POST /__relay/accounts），各自 onAdded 回调
/// 会并发触发 GetPlanStatus，43 个并发上游请求极易触发限流。本 actor 用
/// `reserveSlot()` 模式给每个调用分配一个递增时间槽位，调用方 sleep 到该槽位再
/// 发起上游请求。
///
/// 算法（基于 actor 同步保证）：
///   - 每次 reserveSlot()：返回 `max(now, nextSlotAt)` 作为该调用应等待至的时刻
///   - 然后 nextSlotAt 推进 minGap 秒
///   - 因 actor 串行执行，所有 reserveSlot 调用拿到的 slot 严格递增、间距 ≥ minGap
///
/// 与"sleep 后重读"模式对比：本模式无 reentrancy 风险——sleep 在 actor 外面进行。
public actor RefreshGate {
    private var nextSlotAt: Date = .distantPast
    private let minGapNs: UInt64

    public init(minGapMs: UInt64) {
        self.minGapNs = minGapMs * 1_000_000
    }

    /// 预约下一个槽位。返回该调用应睡到的目标时刻（已过则不睡）。
    public func reserveSlot() -> Date {
        let now = Date()
        let slot = max(now, nextSlotAt)
        nextSlotAt = slot.addingTimeInterval(Double(minGapNs) / 1_000_000_000)
        return slot
    }
}

extension RefreshGate {
    /// 同步等待槽位。`nonisolated` 让 sleep 发生在 actor 外，
    /// 不阻塞其他 reserveSlot 调用——这是关键正确性属性。
    public nonisolated func waitForSlot() async {
        let slot = await self.reserveSlot()
        let toSleep = slot.timeIntervalSinceNow
        if toSleep > 0 {
            try? await Task.sleep(nanoseconds: UInt64(toSleep * 1_000_000_000))
        }
    }
}
