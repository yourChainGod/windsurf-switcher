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
//  3. **排序键**（升序优先）：
//      `(in_flight asc, -score_bucket(100), last_used asc, id asc)`
//
//  4. **sticky cascade**：cascade_id ↔ accountId，TTL 5min。
//
//  5. **replace_accounts merge**：lru_starvation race fix。in-memory > store。
//      cooldown / last_used / banned / streak / ban_count 用 max；
//      ban_signal_first_at 用 min（窗口起点保留较早的）。
//      semaphore 实例**保留 in-memory**（不能换，否则 in-flight 计数丢）。
//
//  6. **冷却档位**（PoolConfig 默认）：
//      - Auth: 300s
//      - RateLimit: 300s（"Resets in:" 优先）
//      - Transient: 单次不冷；连续 ≥2 → 300s 后清零
//      - Ban signal: 30min 窗内 ≥2 → banned_until = now + 10年
//
//  7. **healthSummary drought**：所有 known weekly% < threshold(5%) → drought=true。
//

import Foundation

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

struct StickyBinding: Sendable {
    let accountId: String
    let boundAt: Int64    // unix 秒
}

// MARK: - Pool actor

public actor Pool {
    public nonisolated let config: PoolConfig

    /// 时钟注入：测试时给固定时间
    private let nowProvider: @Sendable () -> Int64

    private var entries: [String: PoolEntry] = [:]
    private var sticky: [String: StickyBinding] = [:]
    /// 当前正在使用某账号的 lease 数（active leases not yet released）。
    /// pickBestAvailable 同步读取此 map 排序，无需 await semaphore。
    private var inFlight: [String: Int] = [:]

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
        try await lease(cascadeId: nil, excludes: [])
    }

    /// 3-pass lease：参考 pool.rs::lease_with_excludes。
    public func lease(
        cascadeId: String?,
        excludes: [String]
    ) async throws -> Lease {
        let now = nowProvider()
        gcSticky(now: now)

        if entries.isEmpty {
            throw PoolError.empty
        }

        // Pass 1：actor 内选号
        let chosen: PoolEntry? =
            pickWithSticky(cascadeId: cascadeId, now: now, excludes: excludes)
            ?? pickBestAvailable(now: now, excludes: excludes)
            ?? pickEarliestCooldown(now: now, excludes: excludes)

        guard let entry = chosen else {
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

    /// Lease deinit 时通过 LeaseReleaseHook 调用此方法。
    fileprivate func _releaseLease(accountId: String) async {
        if let n = inFlight[accountId], n > 0 {
            inFlight[accountId] = n - 1
        }
        if let entry = entries[accountId] {
            await entry.semaphore.release()
        }
    }

    public func bindCascade(_ cascadeId: String, accountId: String) {
        guard entries[accountId] != nil else { return }
        sticky[cascadeId] = StickyBinding(accountId: accountId, boundAt: nowProvider())
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

        sticky = sticky.filter { _, b in nextEntries[b.accountId] != nil }
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

    private func pickWithSticky(
        cascadeId: String?,
        now: Int64,
        excludes: [String]
    ) -> PoolEntry? {
        guard let cid = cascadeId else { return nil }
        guard let bind = sticky[cid] else { return nil }
        if excludes.contains(bind.accountId) { return nil }
        guard let entry = entries[bind.accountId] else { return nil }
        if entry.isLocked(now: now) { return nil }
        return entry
    }

    private func pickBestAvailable(
        now: Int64,
        excludes: [String]
    ) -> PoolEntry? {
        let bucket = max(1, config.scoreBucketSize)
        let candidates = entries.values
            .filter { !$0.isLocked(now: now) }
            .filter { !excludes.contains($0.accountId) }

        // 各排序键都升序优先（min_by 拿"最小"）
        return candidates.min(by: { a, b in
            let ai = inFlight[a.accountId] ?? 0
            let bi = inFlight[b.accountId] ?? 0
            if ai != bi { return ai < bi }

            let abk = scoreOf(a) / bucket
            let bbk = scoreOf(b) / bucket
            if abk != bbk { return abk > bbk }   // 高桶优先（反序让"高"=更优）

            let alu = a.lastUsed ?? Int64.min
            let blu = b.lastUsed ?? Int64.min
            if alu != blu { return alu < blu }   // LRU

            return a.accountId < b.accountId
        })
    }

    private func pickEarliestCooldown(
        now: Int64,
        excludes: [String]
    ) -> PoolEntry? {
        entries.values
            .filter { !excludes.contains($0.accountId) }
            .filter { ($0.bannedUntil ?? 0) <= now }
            .min(by: { ($0.cooldownUntil ?? Int64.max) < ($1.cooldownUntil ?? Int64.max) })
    }

    // MARK: - Internal helpers

    private func gcSticky(now: Int64) {
        let ttl = Int64(config.stickyTTL)
        sticky = sticky.filter { _, b in now - b.boundAt <= ttl }
    }

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
    return nil
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
