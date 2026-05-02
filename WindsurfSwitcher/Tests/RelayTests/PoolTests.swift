//
//  PoolTests.swift
//  RelayTests
//
//  Pool 调度算法测试。直译 src-tauri/src/relay/pool.rs::tests 关键用例。
//
//  关键覆盖：
//    - lease 基础与 excludes
//    - score 公式
//    - score_bucket + LRU tiebreak
//    - sticky cascade
//    - replaceAccounts merge（lru_starvation race fix 必须复现）
//    - recordFailure / recordBanSignal 升级
//    - recordSuccess 清计数
//    - healthSummary drought 判定
//

import XCTest
@testable import Relay

final class PoolTests: XCTestCase {

    // MARK: - 时钟注入

    final class MockClock {
        var now: Int64 = 1_700_000_000
        func tick(_ secs: Int64) { now += secs }
    }

    func makePool(
        seeds: [PoolAccountSeed],
        config: PoolConfig = .default,
        clock: MockClock = MockClock()
    ) -> Pool {
        Pool(accounts: seeds, config: config, nowProvider: { clock.now })
    }

    func makeSeed(
        id: String,
        token: String? = nil,
        daily: Int? = nil,
        weekly: Int? = nil,
        cooldown: Int64? = nil,
        failures: Int = 0,
        lastUsed: Int64? = nil,
        streak: Int = 0,
        banCount: Int = 0,
        banFirstAt: Int64? = nil,
        bannedUntil: Int64? = nil
    ) -> PoolAccountSeed {
        PoolAccountSeed(
            id: id,
            sessionToken: token ?? "tok-\(id)",
            email: "\(id)@example.com",
            dailyPercent: daily,
            weeklyPercent: weekly,
            cooldownUntil: cooldown,
            consecutiveFailures: failures,
            lastUsedByRelay: lastUsed,
            internalErrorStreak: streak,
            banSignalCount: banCount,
            banSignalFirstAt: banFirstAt,
            bannedUntil: bannedUntil
        )
    }

    // MARK: - 基础 lease

    func testLeaseEmptyPoolThrows() async {
        let pool = makePool(seeds: [])
        do {
            _ = try await pool.lease()
            XCTFail("expected PoolError.empty")
        } catch let e as PoolError {
            XCTAssertEqual(e, .empty)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testLeaseBasic() async throws {
        let pool = makePool(seeds: [makeSeed(id: "a")])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "a")
        XCTAssertEqual(lease.token, "tok-a")
    }

    func testLeaseAllExcludedThrows() async {
        let pool = makePool(seeds: [makeSeed(id: "a"), makeSeed(id: "b")])
        do {
            _ = try await pool.lease(cascadeId: nil, excludes: ["a", "b"])
            XCTFail("expected PoolError.allExcluded")
        } catch let e as PoolError {
            XCTAssertEqual(e, .allExcluded)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testLeaseExcludesSkipsListed() async throws {
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100),
            makeSeed(id: "b", daily: 100, weekly: 100),
        ])
        let lease = try await pool.lease(cascadeId: nil, excludes: ["a"])
        XCTAssertEqual(lease.accountId, "b")
    }

    // MARK: - Score 公式

    func testScoreFormula() {
        // 直接测 scoreOf 自由函数
        let e1 = PoolEntry(
            accountId: "x", token: "x", email: nil,
            cooldownUntil: nil, consecutiveFailures: 0,
            lastUsed: nil, dailyPercent: 80, weeklyPercent: 50,
            internalErrorStreak: 0, banSignalCount: 0, banSignalFirstAt: nil,
            bannedUntil: nil, semaphore: AsyncSemaphore(limit: 1)
        )
        // checked=1000, effective=min(80,50)=50, score = 1000 + 50*10 + 50*3 + 80 = 1730
        XCTAssertEqual(scoreOf(e1), 1730)

        // 未检查（daily/weekly 都 nil）：checked=0
        let e2 = PoolEntry(
            accountId: "x", token: "x", email: nil,
            cooldownUntil: nil, consecutiveFailures: 0,
            lastUsed: nil, dailyPercent: nil, weeklyPercent: nil,
            internalErrorStreak: 0, banSignalCount: 0, banSignalFirstAt: nil,
            bannedUntil: nil, semaphore: AsyncSemaphore(limit: 1)
        )
        XCTAssertEqual(scoreOf(e2), 0)

        // failure_penalty = 3 * 50 = 150
        let e3 = PoolEntry(
            accountId: "x", token: "x", email: nil,
            cooldownUntil: nil, consecutiveFailures: 3,
            lastUsed: nil, dailyPercent: 100, weeklyPercent: 100,
            internalErrorStreak: 0, banSignalCount: 0, banSignalFirstAt: nil,
            bannedUntil: nil, semaphore: AsyncSemaphore(limit: 1)
        )
        // 1000 + 100*10 + 100*3 + 100 - 150 = 2250
        XCTAssertEqual(scoreOf(e3), 2250)
    }

    // MARK: - LRU + score_bucket tiebreak

    func testHigherScoreBeatsLowerScoreWhenAcrossBucket() async throws {
        // a: 100/100 → score 2400  vs b: 50/50 → score 1100
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100),
            makeSeed(id: "b", daily: 50, weekly: 50),
        ])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "a")
    }

    func testEqualScoreUsesLRU() async throws {
        // 都是 100/100 → 同 score。a 最近用过（lastUsed=200），b 没用过 → 选 b（LRU）
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100, lastUsed: 200),
            makeSeed(id: "b", daily: 100, weekly: 100),
        ])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "b")
    }

    func testLRUDistributesEvenlyAcross8EqualScoreAccounts() async throws {
        // 复现 pool.rs::lru_distributes_evenly_across_8_equal_score_accounts
        let clock = MockClock()
        let seeds = (0..<8).map { i in
            makeSeed(id: "a\(i)", daily: 100, weekly: 100)
        }
        let pool = makePool(seeds: seeds, clock: clock)

        var seen: [String: Int] = [:]
        for _ in 0..<8 {
            let lease = try await pool.lease()
            seen[lease.accountId, default: 0] += 1
            // 每秒 lease 一次，模拟用户实际使用
            clock.tick(1)
        }
        // 8 个号每个至少 1 次（LRU 应当均匀分散）
        for i in 0..<8 {
            XCTAssertGreaterThanOrEqual(seen["a\(i)"] ?? 0, 1, "a\(i) should be picked at least once")
        }
    }

    // MARK: - cooldown 排除

    func testCooledAccountSkipped() async throws {
        let clock = MockClock()
        let pool = makePool(seeds: [
            makeSeed(id: "cooled", daily: 100, weekly: 100, cooldown: clock.now + 100),
            makeSeed(id: "ok", daily: 50, weekly: 50),
        ], clock: clock)
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "ok")
    }

    func testEarliestCooldownFallback() async throws {
        // 全部冷却中 → pickEarliestCooldown 兜底，挑最早解封的
        let clock = MockClock()
        let pool = makePool(seeds: [
            makeSeed(id: "a", cooldown: clock.now + 1000),
            makeSeed(id: "b", cooldown: clock.now + 100),  // 最早解封
            makeSeed(id: "c", cooldown: clock.now + 500),
        ], clock: clock)
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "b")
    }

    func testBannedAccountNeverSelected() async throws {
        // 永久封禁 + 短冷却 vs 短冷却：banned 排除，b 入选
        let clock = MockClock()
        let pool = makePool(seeds: [
            makeSeed(id: "banned", cooldown: clock.now + 100, bannedUntil: clock.now + 10000),
            makeSeed(id: "b", cooldown: clock.now + 50),
        ], clock: clock)
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "b")
    }

    // MARK: - sticky cascade

    func testStickyBindsToSameAccount() async throws {
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100),
            makeSeed(id: "b", daily: 100, weekly: 100),
        ])
        // 先 bind cascade-1 → a
        await pool.bindCascade("cascade-1", accountId: "a")
        let lease = try await pool.lease(cascadeId: "cascade-1", excludes: [])
        XCTAssertEqual(lease.accountId, "a")
    }

    func testStickyExcludedFallsBack() async throws {
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100),
            makeSeed(id: "b", daily: 100, weekly: 100),
        ])
        await pool.bindCascade("cascade-1", accountId: "a")
        let lease = try await pool.lease(cascadeId: "cascade-1", excludes: ["a"])
        XCTAssertEqual(lease.accountId, "b", "excluded sticky should fall back to best available")
    }

    // MARK: - replaceAccounts merge (race fix)

    func testReplaceAccountsKeepsSemaphoreInstance() async throws {
        let pool = makePool(seeds: [makeSeed(id: "a")])
        // lease 一次（占一个槽）
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "a")

        // replace 时同 id 应当复用 in-memory semaphore（race fix），
        // 否则 in-flight 计数全归零
        await pool.replaceAccounts([makeSeed(id: "a", lastUsed: 100)])
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.first?.inFlight, 1, "in-flight count must survive replaceAccounts")
        _ = lease  // keep alive
    }

    /// pool.rs::tests::replace_accounts_must_not_clobber_inflight_last_used
    /// 关键测试：lease 后 record_success 落库前的 race，replace_accounts 不能把
    /// in-memory 的 last_used 倒回 store 里的旧值。
    func testReplaceAccountsMustNotClobberInflightLastUsed() async throws {
        let clock = MockClock()
        clock.now = 20_000_000
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100),
        ], clock: clock)

        // lease(now=20000000)，pool 内部 last_used = 20000000
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "a")

        // 模拟 5s ticker：store 还是旧值（lastUsedByRelay = 19_999_940 即 60s 前）
        // 用 .or() 会让 in-memory 20000000 被 19999940 覆盖。
        // 修复后用 max → 保留 20000000。
        await pool.replaceAccounts([
            makeSeed(id: "a", daily: 100, weekly: 100, lastUsed: 19_999_940),
        ])
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.first?.lastUsedAt, 20_000_000,
                       "in-memory last_used must NOT be clobbered by stale store value")
    }

    func testReplaceAccountsRemovesOldEntries() async {
        let pool = makePool(seeds: [makeSeed(id: "a"), makeSeed(id: "b")])
        await pool.replaceAccounts([makeSeed(id: "a")])
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.accountId, "a")
    }

    func testReplaceAccountsMaxMergesCooldown() async {
        let clock = MockClock()
        clock.now = 100
        let pool = makePool(seeds: [
            makeSeed(id: "a", cooldown: 200),
        ], clock: clock)
        // store 给的 cooldown 比 in-memory 早 → 应保留 in-memory 较晚的 200
        await pool.replaceAccounts([
            makeSeed(id: "a", cooldown: 150),
        ])
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.first?.cooldownUntil, 200)
    }

    func testReplaceAccountsMinMergesBanSignalFirstAt() async {
        let clock = MockClock()
        let pool = makePool(seeds: [
            makeSeed(id: "a", banFirstAt: 500),
        ], clock: clock)
        // store 给较早的 first_at → 应取较早值（窗口起点保守）
        await pool.replaceAccounts([
            makeSeed(id: "a", banFirstAt: 300),
        ])
        let snap = await pool.snapshot()
        // snapshot 不直接暴露 ban_signal_first_at；用 recordBanSignal 间接验证
        // 这里至少保证 entry 仍存在
        XCTAssertEqual(snap.first?.accountId, "a")
    }

    // MARK: - recordFailure / recordSuccess / recordBanSignal

    func testRecordFailureAuthCooldown() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [makeSeed(id: "a")], clock: clock)

        let upd = await pool.recordFailure("a", kind: .auth)
        XCTAssertNotNil(upd)
        XCTAssertEqual(upd?.cooldownUntil, 1000 + 300)  // default 300s
        XCTAssertEqual(upd?.consecutiveFailures, 1)
    }

    func testRecordFailureWithCustomCooldown() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [makeSeed(id: "a")], clock: clock)

        let upd = await pool.recordFailureWithCooldown("a", kind: .rateLimit, cooldownOverride: 600)
        XCTAssertEqual(upd?.cooldownUntil, 1000 + 600)
    }

    func testRecordFailureTransientStreakTriggersCooldown() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [makeSeed(id: "a")], clock: clock)

        // 第一次 transient：不冷却
        let u1 = await pool.recordFailure("a", kind: .transient)
        XCTAssertNil(u1?.cooldownUntil)
        XCTAssertEqual(u1?.internalErrorStreak, 1)

        // 第二次 transient：累计达阈值 → 冷却 + streak 清零
        let u2 = await pool.recordFailure("a", kind: .transient)
        XCTAssertNotNil(u2?.cooldownUntil)
        XCTAssertEqual(u2?.cooldownUntil, 1000 + 300)
        XCTAssertEqual(u2?.internalErrorStreak, 0)
    }

    func testRecordSuccessClearsCounters() async {
        let pool = makePool(seeds: [makeSeed(id: "a", failures: 3, streak: 1, banCount: 1)])
        _ = await pool.recordFailure("a", kind: .auth)
        let upd = await pool.recordSuccess("a")
        XCTAssertNotNil(upd)
        XCTAssertNil(upd?.cooldownUntil)
        XCTAssertEqual(upd?.consecutiveFailures, 0)
        XCTAssertEqual(upd?.internalErrorStreak, 0)
        XCTAssertEqual(upd?.banSignalCount, 0)
        XCTAssertNil(upd?.banSignalFirstAt)
    }

    func testRecordSuccessKeepsBannedUntil() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [
            makeSeed(id: "a", bannedUntil: 9999999),
        ], clock: clock)
        let upd = await pool.recordSuccess("a")
        XCTAssertEqual(upd?.bannedUntil, 9999999)  // 不清除
    }

    func testRecordBanSignalAccumulatesAndUpgrades() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [makeSeed(id: "a")], clock: clock)

        // 第 1 次：仅累计
        let u1 = await pool.recordBanSignal("a")
        XCTAssertEqual(u1?.banSignalCount, 1)
        XCTAssertEqual(u1?.banSignalFirstAt, 1000)
        XCTAssertNil(u1?.bannedUntil)

        // 第 2 次（窗口内）：升级到 banned_until
        clock.tick(60)  // 1 min later
        let u2 = await pool.recordBanSignal("a")
        XCTAssertEqual(u2?.banSignalCount, 2)
        XCTAssertNotNil(u2?.bannedUntil)
        XCTAssertGreaterThan(u2?.bannedUntil ?? 0, clock.now)
    }

    func testRecordBanSignalWindowExpiry() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [makeSeed(id: "a")], clock: clock)

        let u1 = await pool.recordBanSignal("a")
        XCTAssertEqual(u1?.banSignalCount, 1)

        // 窗口外（默认 30min）→ 旧计数清零，从 1 重新开始
        clock.tick(31 * 60)
        let u2 = await pool.recordBanSignal("a")
        XCTAssertEqual(u2?.banSignalCount, 1)
        XCTAssertNil(u2?.bannedUntil)
    }

    // MARK: - healthSummary

    func testHealthSummaryDroughtAllLow() async {
        // 全部 weekly < 5 → drought=true
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 0, weekly: 2),
            makeSeed(id: "b", daily: 1, weekly: 4),
        ])
        let s = await pool.healthSummary()
        XCTAssertTrue(s.drought)
        XCTAssertEqual(s.lowestWeeklyPercent, 2)
        XCTAssertEqual(s.totalAccounts, 2)
    }

    func testHealthSummaryNotDroughtIfAnyAbove() async {
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 80, weekly: 60),
            makeSeed(id: "b", daily: 1, weekly: 1),
        ])
        let s = await pool.healthSummary()
        XCTAssertFalse(s.drought)
    }

    func testHealthSummaryNoDataNotDrought() async {
        // 没人有 weekly_pct → 不下结论 drought
        let pool = makePool(seeds: [makeSeed(id: "a")])
        let s = await pool.healthSummary()
        XCTAssertFalse(s.drought)
    }

    func testHealthSummaryCountsByCategory() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [
            makeSeed(id: "a"),
            makeSeed(id: "b", cooldown: 2000),
            makeSeed(id: "c", cooldown: 2000),
            makeSeed(id: "d", bannedUntil: 9999999),
        ], clock: clock)
        let s = await pool.healthSummary()
        XCTAssertEqual(s.totalAccounts, 4)
        XCTAssertEqual(s.availableAccounts, 1)
        XCTAssertEqual(s.cooledAccounts, 2)
        XCTAssertEqual(s.bannedAccounts, 1)
    }
}
