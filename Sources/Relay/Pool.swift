//
//  Pool.swift
//  Relay
//
//  调度中心：1:1 移植 src-tauri/src/relay/pool.rs。
//
//  ## 核心算法
//
//  1. **3-pass lease**：
//      - Pass 1（actor 内）：选号 + 拷 semaphore 引用
//      - Pass 2（actor 外）：await semaphore.acquire（避免持锁等待）
//      - Pass 3（actor 内）：++inFlight[id] + 更新 last_used
//
//  2. **score 公式**：
//      ```
//      checked = (daily_pct.is_some || weekly_pct.is_some) ? 1000 : 0
//      effective = min(daily, weekly)  // 未检查默认 0
//      failure_penalty = consecutive_failures * 50
//      score = checked + effective*10 + weekly*3 + daily - failure_penalty
//      ```
//
//  3. **排序键**：score 降序 → inFlight 升序 → lastUsed 升序 → id 升序。
//
//  4. **replace_accounts merge**：lru_starvation race fix。in-memory > store。
//      cooldown / last_used / banned / streak / ban_count 用 max；
//      ban_signal_first_at 用 min（窗口起点保留较早的）。
//      semaphore 实例**保留 in-memory**（不能换，否则 in-flight 计数丢）。
//
//  5. **冷却档位**（PoolConfig 默认）：
//      - Auth: 300s
//      - RateLimit: 300s（"Resets in:" 优先）
//      - Transient: 单次不冷；连续 ≥2 → 300s 后清零
//      - Ban signal: 30min 窗内 ≥2 → banned_until = now + 10年
//
//  6. **healthSummary drought**：所有 known weekly% < threshold(5%) → drought=true。
//

import Foundation
import Core

// MARK: - PoolEntry (内部状态)

struct PoolEntry: Sendable {
    let accountId: String
    var token: String
    var email: String?
    var cooldownUntil: Int64?
    var consecutiveFailures: Int
    var lastUsed: Int64?
    var dailyPercent: Int?
    var weeklyPercent: Int?
    var internalErrorStreak: Int
    var banSignalCount: Int
    var banSignalFirstAt: Int64?
    var bannedUntil: Int64?

    /// 同一账号的并发栅；replace_accounts 必须保留同一实例（race fix）。
    let semaphore: AsyncSemaphore

    func isLocked(now: Int64) -> Bool {
        if let bu = bannedUntil, bu > now { return true }
        if let cu = cooldownUntil, cu > now { return true }
        return false
    }
}

// MARK: - Pool actor

public actor Pool {
    public nonisolated let config: PoolConfig

    /// 时钟注入：测试时给固定时间
    private let nowProvider: @Sendable () -> Int64

    private var entries: [String: PoolEntry] = [:]
    /// 当前正在使用某账号的 lease 数（active leases not yet released）。
    /// pickBestAvailable 同步读取此 map 排序，无需 await semaphore。
    private var inFlight: [String: Int] = [:]
    /// 每个 app 最近一次 GetUserJwt 成功命中的账号 ID（也即对应 LS 当前持有 JWT 的号）。
    /// 所有非 GetUserJwt RPC（telemetry / GetUserStatus / Record* 等）都应直接 splice
    /// 本 app 的 token——relay 视角才能与 LS 实际使用的账号严格对齐，不再"乱飘"。
    /// 真正切换"哪个号被烧"必须靠 GetUserJwt 重新选号 + 强制轮转。
    private var currentActiveAccounts: [WindsurfApp: String] = [:]

    // MARK: Init

    public init(
        config: PoolConfig = .default,
        nowProvider: @Sendable @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.config = config
        self.nowProvider = nowProvider
    }

    public init(
        accounts: [PoolAccountSeed],
        config: PoolConfig = .default,
        nowProvider: @Sendable @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.config = config
        self.nowProvider = nowProvider
        for seed in accounts {
            entries[seed.id] = Self.makeEntryStatic(from: seed, config: config)
            inFlight[seed.id] = 0
        }
    }

    // MARK: - Public API

    public func size() -> Int { entries.count }

    public func lease() async throws -> Lease {
        try await lease(excludes: [])
    }

    /// 选号唯一入口——只供 GetUserJwt 路径用。
    /// 永远 strict-best：score 最高（!cooled !banned !quota_exhausted !excludes）→ inFlight → LRU → id。
    /// 非 GetUserJwt RPC 不调此方法，直接用 `getActiveSnapshot()` 的 token splice。
    public func lease(excludes: [String]) async throws -> Lease {
        let now = nowProvider()

        if entries.isEmpty {
            throw PoolError.empty
        }

        guard let entry = pickBestAvailable(now: now, excludes: excludes) else {
            throw PoolError.allExcluded
        }

        let accountId = entry.accountId
        let token = entry.token
        let email = entry.email
        let semaphore = entry.semaphore

        // Pass 2：actor 重入 await（让出 actor 锁，等价于"锁外"）
        await semaphore.acquire()

        // Pass 3：actor 内更新 inFlight + last_used
        if var e = entries[accountId] {
            e.lastUsed = now
            entries[accountId] = e
        }
        inFlight[accountId, default: 0] += 1

        // Lease release 回调：进入 actor 释放 inFlight + sem
        let release = LeaseReleaseHook(pool: self, accountId: accountId)
        return Lease(
            accountId: accountId,
            token: token,
            email: email,
            release: release
        )
    }

    /// 预览下一次 GetUserJwt 会拿到的账号，不占用 lease。
    /// App 侧用它先强制刷新 quota，再用同一 token 发 StartCascade，让 LS 的
    /// GetUserJwt 请求进入 relay 后仍按 Pool 的真实规则选择有额度账号。
    public func nextJwtCandidate(
        app: WindsurfApp = .stable,
        forceRotateFromActive: Bool = true
    ) -> NextJwtCandidate? {
        let now = nowProvider()
        let excludes = forceRotateFromActive ? rotationExcludes(app: app, now: now) : []
        guard let entry = pickBestAvailable(now: now, excludes: excludes) else { return nil }
        return NextJwtCandidate(accountId: entry.accountId, token: entry.token, email: entry.email)
    }

    /// 强制轮转时应排除哪些 active。
    /// 可用号足够时避开所有 app 当前 active，避免 stable/next 同烧一个号；
    /// 可用号不够时至少避开本 app active，保留单号/少号场景可用性。
    public func rotationExcludes(app: WindsurfApp) -> [String] {
        rotationExcludes(app: app, now: nowProvider())
    }

    /// Lease deinit 时通过 LeaseReleaseHook 调用此方法。
    fileprivate func _releaseLease(accountId: String) async {
        if let n = inFlight[accountId], n > 0 {
            inFlight[accountId] = n - 1
        }
        if let entry = entries[accountId] {
            await entry.semaphore.release()
        }
    }

    /// 标记某 app 的"当前活跃号"——GetUserJwt 成功路径调用，记录刚返给 LS 的号。
    /// 后续所有非 GetUserJwt RPC 都直接 splice 此号的 token（见 getActiveSnapshot）。
    /// 传 nil 清除。
    public func setCurrentActiveAccount(_ accountId: String?, app: WindsurfApp = .stable) {
        if let id = accountId, entries[id] == nil {
            return // 不存在的号忽略
        }
        if let accountId {
            currentActiveAccounts[app] = accountId
        } else {
            currentActiveAccounts.removeValue(forKey: app)
        }
    }

    /// 给观测 / 测试 / `/__relay/pool` JSON 暴露用。
    public func getCurrentActiveAccount(app: WindsurfApp = .stable) -> String? {
        currentActiveAccounts[app]
    }

    /// 全部 app 当前活跃号。用于 UI/调试展示和 active quota 刷新。
    public func getCurrentActiveAccounts() -> [WindsurfApp: String] {
        currentActiveAccounts
    }

    /// 非 GetUserJwt 路径取活跃号 splice 用。
    /// active 为 nil 或对应 entry 已不在池里 → 返回 nil（调用方走 passthrough）。
    /// **不**校验 cooldown / banned——LS 仍持有该号的 JWT 在用，relay 视角必须对齐；
    /// 由 GetUserJwt 强制轮转切到新号才是正路。
    public func getActiveSnapshot(app: WindsurfApp = .stable) -> ActiveSnapshot? {
        guard let id = currentActiveAccounts[app], let e = entries[id] else { return nil }
        return ActiveSnapshot(accountId: id, token: e.token, email: e.email)
    }

    // MARK: - Failure / success records

    @discardableResult
    public func recordFailure(_ accountId: String, kind: FailureKind) -> AccountUpdate? {
        recordFailureWithCooldown(accountId, kind: kind, cooldownOverride: nil)
    }

    @discardableResult
    public func recordFailureWithCooldown(
        _ accountId: String,
        kind: FailureKind,
        cooldownOverride: TimeInterval?
    ) -> AccountUpdate? {
        let now = nowProvider()
        guard var entry = entries[accountId] else { return nil }
        entry.consecutiveFailures = entry.consecutiveFailures &+ 1

        var effective: TimeInterval? = cooldownOverride ?? kind.cooldown(config)

        if kind == .transient && cooldownOverride == nil {
            entry.internalErrorStreak = entry.internalErrorStreak &+ 1
            if entry.internalErrorStreak >= config.internalErrorStreakThreshold {
                effective = config.cooldownOnInternalErrorStreak
                entry.internalErrorStreak = 0
            }
        }

        if let d = effective {
            entry.cooldownUntil = now + Int64(d)
        }
        entries[accountId] = entry
        return makeUpdate(entry)
    }

    @discardableResult
    public func recordBanSignal(_ accountId: String) -> AccountUpdate? {
        let now = nowProvider()
        guard var entry = entries[accountId] else { return nil }

        if let firstAt = entry.banSignalFirstAt {
            if now - firstAt > Int64(config.banSignalWindow) {
                entry.banSignalCount = 0
                entry.banSignalFirstAt = nil
            }
        }
        if entry.banSignalFirstAt == nil {
            entry.banSignalFirstAt = now
        }
        entry.banSignalCount = entry.banSignalCount &+ 1

        if entry.banSignalCount >= config.banSignalThreshold {
            entry.bannedUntil = now + Int64(config.bannedLockout)
        }
        entries[accountId] = entry
        return makeUpdate(entry)
    }

    @discardableResult
    public func recordSuccess(_ accountId: String) -> AccountUpdate? {
        guard var entry = entries[accountId] else { return nil }
        entry.cooldownUntil = nil
        entry.consecutiveFailures = 0
        entry.internalErrorStreak = 0
        entry.banSignalCount = 0
        entry.banSignalFirstAt = nil
        entries[accountId] = entry
        return makeUpdate(entry)
    }

    // MARK: - replace_accounts (race-safe merge)

    public func replaceAccounts(_ seeds: [PoolAccountSeed]) {
        var nextEntries: [String: PoolEntry] = [:]
        var nextInFlight: [String: Int] = [:]
        nextEntries.reserveCapacity(seeds.count)

        for seed in seeds {
            if let old = entries.removeValue(forKey: seed.id) {
                let merged = PoolEntry(
                    accountId: old.accountId,
                    token: seed.sessionToken,
                    email: seed.email,
                    cooldownUntil: maxOpt(seed.cooldownUntil, old.cooldownUntil),
                    consecutiveFailures: max(seed.consecutiveFailures, old.consecutiveFailures),
                    lastUsed: maxOpt(seed.lastUsedByRelay, old.lastUsed),
                    dailyPercent: seed.dailyPercent,
                    weeklyPercent: seed.weeklyPercent,
                    internalErrorStreak: max(seed.internalErrorStreak, old.internalErrorStreak),
                    banSignalCount: max(seed.banSignalCount, old.banSignalCount),
                    banSignalFirstAt: minOpt(seed.banSignalFirstAt, old.banSignalFirstAt),
                    bannedUntil: maxOpt(seed.bannedUntil, old.bannedUntil),
                    semaphore: old.semaphore   // race fix: 保留 in-memory 实例
                )
                nextEntries[seed.id] = merged
                nextInFlight[seed.id] = inFlight[seed.id] ?? 0
            } else {
                nextEntries[seed.id] = makeEntry(from: seed, config: config)
                nextInFlight[seed.id] = 0
            }
        }

        entries = nextEntries
        inFlight = nextInFlight
    }

    // MARK: - Health / snapshot

    public func snapshot() -> [EntrySnapshot] {
        let now = nowProvider()
        let cap = config.perTokenConcurrency
        var out: [EntrySnapshot] = []
        out.reserveCapacity(entries.count)
        for entry in entries.values {
            out.append(EntrySnapshot(
                accountId: entry.accountId,
                email: entry.email,
                tokenPrefix: String(entry.token.prefix(32)),
                cooldownUntil: entry.cooldownUntil,
                consecutiveFailures: entry.consecutiveFailures,
                dailyPercent: entry.dailyPercent,
                weeklyPercent: entry.weeklyPercent,
                lastUsedAt: entry.lastUsed,
                inFlight: min(inFlight[entry.accountId] ?? 0, cap),
                unavailableReason: unavailableReason(entry, now: now),
                bannedUntil: entry.bannedUntil,
                internalErrorStreak: entry.internalErrorStreak,
                score: scoreOf(entry)
            ))
        }
        out.sort { $0.score > $1.score }
        return out
    }

    public func healthSummary() -> HealthSummary {
        let now = nowProvider()
        let droughtThreshold = 5
        var available = 0, cooled = 0, banned = 0
        var knownWeekly = 0, droughtWeekly = 0
        var lowestWeekly: Int? = nil
        var lowestDaily: Int? = nil

        for e in entries.values {
            if let bu = e.bannedUntil, bu > now {
                banned += 1
            } else if let cu = e.cooldownUntil, cu > now {
                cooled += 1
            } else if hasKnownExhaustedQuota(e) {
                // quota_exhausted 不另设 HealthSummary 字段，但不能算 available；
                // 否则 force-rotate 可能把 active 排除后落到 0% 账号。
            } else {
                available += 1
            }
            if let w = e.weeklyPercent {
                knownWeekly += 1
                lowestWeekly = lowestWeekly.map { min($0, w) } ?? w
                if w < droughtThreshold {
                    droughtWeekly += 1
                }
            }
            if let d = e.dailyPercent {
                lowestDaily = lowestDaily.map { min($0, d) } ?? d
            }
        }
        return HealthSummary(
            drought: knownWeekly > 0 && droughtWeekly == knownWeekly,
            droughtThreshold: droughtThreshold,
            totalAccounts: entries.count,
            availableAccounts: available,
            cooledAccounts: cooled,
            bannedAccounts: banned,
            lowestWeeklyPercent: lowestWeekly,
            lowestDailyPercent: lowestDaily
        )
    }

    // MARK: - Internal: pick

    /// 选号唯一实现：strict-best。
    /// 排序：score 降序 → inFlight 升序 → lastUsed 升序（LRU）→ id 升序。
    /// 不分桶（bucket=1）——score 决定优先级，配合调用方传入的 excludes 实现轮转。
    private func pickBestAvailable(
        now: Int64,
        excludes: [String]
    ) -> PoolEntry? {
        let candidates = entries.values
            .filter { isUsableForJwt($0, now: now) }
            .filter { !excludes.contains($0.accountId) }

        // 排序优先级：score 降序（最强号优先）→ inFlight 升序（让最闲号先选）→
        //              lastUsed 升序（LRU）→ id 升序（确定性 tiebreak）。
        return candidates.min(by: { a, b in
            let asc = scoreOf(a)
            let bsc = scoreOf(b)
            if asc != bsc { return asc > bsc }

            let ai = inFlight[a.accountId] ?? 0
            let bi = inFlight[b.accountId] ?? 0
            if ai != bi { return ai < bi }

            let alu = a.lastUsed ?? Int64.min
            let blu = b.lastUsed ?? Int64.min
            if alu != blu { return alu < blu }

            return a.accountId < b.accountId
        })
    }

    private func usableEntryCount(now: Int64) -> Int {
        entries.values.reduce(0) { count, entry in
            count + (isUsableForJwt(entry, now: now) ? 1 : 0)
        }
    }

    private func rotationExcludes(app: WindsurfApp, now: Int64) -> [String] {
        let activeIds = Array(Set(currentActiveAccounts.values))
        let usable = usableEntryCount(now: now)
        if usable > activeIds.count {
            return activeIds
        }
        if usable >= 2, let active = currentActiveAccounts[app] {
            return [active]
        }
        return []
    }

    private func isUsableForJwt(_ entry: PoolEntry, now: Int64) -> Bool {
        !entry.isLocked(now: now) && !hasKnownExhaustedQuota(entry)
    }

    // MARK: - Internal helpers

    private func makeEntry(from seed: PoolAccountSeed, config: PoolConfig) -> PoolEntry {
        Self.makeEntryStatic(from: seed, config: config)
    }

    /// nonisolated static 版：可在 actor convenience init 中调用。
    static func makeEntryStatic(from seed: PoolAccountSeed, config: PoolConfig) -> PoolEntry {
        PoolEntry(
            accountId: seed.id,
            token: seed.sessionToken,
            email: seed.email,
            cooldownUntil: seed.cooldownUntil,
            consecutiveFailures: seed.consecutiveFailures,
            lastUsed: seed.lastUsedByRelay,
            dailyPercent: seed.dailyPercent,
            weeklyPercent: seed.weeklyPercent,
            internalErrorStreak: seed.internalErrorStreak,
            banSignalCount: seed.banSignalCount,
            banSignalFirstAt: seed.banSignalFirstAt,
            bannedUntil: seed.bannedUntil,
            semaphore: AsyncSemaphore(limit: config.perTokenConcurrency)
        )
    }

    private func makeUpdate(_ e: PoolEntry) -> AccountUpdate {
        AccountUpdate(
            accountId: e.accountId,
            cooldownUntil: e.cooldownUntil,
            consecutiveFailures: e.consecutiveFailures,
            lastUsedByRelay: e.lastUsed,
            internalErrorStreak: e.internalErrorStreak,
            banSignalCount: e.banSignalCount,
            banSignalFirstAt: e.banSignalFirstAt,
            bannedUntil: e.bannedUntil
        )
    }
}

// MARK: - Lease release plumbing

/// 闭包式 release hook：Lease deinit 触发 → Task 进 actor 释放并发槽。
final class LeaseReleaseHook: @unchecked Sendable {
    private weak var pool: Pool?
    private let accountId: String
    private var consumed: Bool = false

    init(pool: Pool, accountId: String) {
        self.pool = pool
        self.accountId = accountId
    }

    func fire() {
        guard !consumed else { return }
        consumed = true
        if let pool = pool {
            let id = accountId
            Task { await pool._releaseLease(accountId: id) }
        }
    }
}

// MARK: - Free helpers

func scoreOf(_ e: PoolEntry) -> Int64 {
    let checked: Int64 = (e.dailyPercent != nil || e.weeklyPercent != nil) ? 1000 : 0
    let daily = Int64(e.dailyPercent ?? 0)
    let weekly = Int64(e.weeklyPercent ?? 0)
    let effective = min(daily, weekly)
    let failurePenalty = Int64(min(e.consecutiveFailures, Int(Int64.max / 50))) * 50
    return checked + effective * 10 + weekly * 3 + daily - failurePenalty
}

func unavailableReason(_ e: PoolEntry, now: Int64) -> String? {
    if let bu = e.bannedUntil, bu > now { return "banned" }
    if let cu = e.cooldownUntil, cu > now { return "cooled" }
    if hasKnownExhaustedQuota(e) { return "quota_exhausted" }
    return nil
}

func hasKnownExhaustedQuota(_ e: PoolEntry) -> Bool {
    e.dailyPercent == 0 || e.weeklyPercent == 0
}

func maxOpt<T: Comparable>(_ a: T?, _ b: T?) -> T? {
    switch (a, b) {
    case let (x?, y?): return Swift.max(x, y)
    case let (x?, nil): return x
    case let (nil, y?): return y
    case (nil, nil): return nil
    }
}

func minOpt<T: Comparable>(_ a: T?, _ b: T?) -> T? {
    switch (a, b) {
    case let (x?, y?): return Swift.min(x, y)
    case let (x?, nil): return x
    case let (nil, y?): return y
    case (nil, nil): return nil
    }
}

// MARK: - ActiveSnapshot

/// 当前活跃账号的最小快照——非 GetUserJwt 路径取此 splice。
/// 只携带 splice 必需的三字段；不暴露 cooldown / inFlight 等内部状态。
public struct ActiveSnapshot: Sendable, Equatable {
    public let accountId: String
    public let token: String
    public let email: String?

    public init(accountId: String, token: String, email: String?) {
        self.accountId = accountId
        self.token = token
        self.email = email
    }
}

// MARK: - PoolAccountSeed

/// 把 `Core.Account` 灌进 Pool 的中间结构（让 Relay lib 不依赖 Core）。
public struct PoolAccountSeed: Sendable, Equatable {
    public let id: String
    public let sessionToken: String
    public let email: String?
    public let dailyPercent: Int?
    public let weeklyPercent: Int?
    public let cooldownUntil: Int64?
    public let consecutiveFailures: Int
    public let lastUsedByRelay: Int64?
    public let internalErrorStreak: Int
    public let banSignalCount: Int
    public let banSignalFirstAt: Int64?
    public let bannedUntil: Int64?

    public init(
        id: String,
        sessionToken: String,
        email: String? = nil,
        dailyPercent: Int? = nil,
        weeklyPercent: Int? = nil,
        cooldownUntil: Int64? = nil,
        consecutiveFailures: Int = 0,
        lastUsedByRelay: Int64? = nil,
        internalErrorStreak: Int = 0,
        banSignalCount: Int = 0,
        banSignalFirstAt: Int64? = nil,
        bannedUntil: Int64? = nil
    ) {
        self.id = id
        self.sessionToken = sessionToken
        self.email = email
        self.dailyPercent = dailyPercent
        self.weeklyPercent = weeklyPercent
        self.cooldownUntil = cooldownUntil
        self.consecutiveFailures = consecutiveFailures
        self.lastUsedByRelay = lastUsedByRelay
        self.internalErrorStreak = internalErrorStreak
        self.banSignalCount = banSignalCount
        self.banSignalFirstAt = banSignalFirstAt
        self.bannedUntil = bannedUntil
    }
}
