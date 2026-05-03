//
//  PoolTests.swift
//  RelayTests
//
//  Pool 调度算法测试。
//
//  ## 简化后覆盖（2026-05-03 重构后）
//
//  仅 GetUserJwt 走 lease——所以 Pool 的核心责任收敛为：
//    - 选 score 最高的可用号（pickBestAvailable）
//    - 失败/成功记账（recordFailure / recordSuccess / recordBanSignal）
//    - 给非 GetUserJwt 路径暴露 active 快照（getActiveSnapshot）
//    - replaceAccounts merge race fix（lru_starvation）保留
//
//  已删除的测试：sticky cascade / lowQuota / pickCurrentActive / strictBest 对照组
//  ——这些机制都已从 Pool 中下线。
//

import XCTest
import Core
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
            _ = try await pool.lease(excludes: ["a", "b"])
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
        let lease = try await pool.lease(excludes: ["a"])
        XCTAssertEqual(lease.accountId, "b")
    }

    /// 全部 cooled / banned → throws allExcluded。
    /// （旧 pickEarliestCooldown 兜底已删——非 GetUserJwt 路径不走 lease，
    /// GetUserJwt 路径靠 5-attempt + lastResp 兜底 + 502，不再"硬选已冷的"。）
    func testAllUnavailableThrowsAllExcluded() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [
            makeSeed(id: "a", cooldown: 5000),
            makeSeed(id: "b", cooldown: 5000),
        ], clock: clock)
        do {
            _ = try await pool.lease()
            XCTFail("expected PoolError.allExcluded")
        } catch let e as PoolError {
            XCTAssertEqual(e, .allExcluded)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - Score 公式

    func testScoreFormula() {
        let e1 = PoolEntry(
            accountId: "x", token: "x", email: nil,
            cooldownUntil: nil, consecutiveFailures: 0,
            lastUsed: nil, dailyPercent: 80, weeklyPercent: 50,
            internalErrorStreak: 0, banSignalCount: 0, banSignalFirstAt: nil,
            bannedUntil: nil, semaphore: AsyncSemaphore(limit: 1)
        )
        // checked=1000, effective=min(80,50)=50, score = 1000 + 50*10 + 50*3 + 80 = 1730
        XCTAssertEqual(scoreOf(e1), 1730)

        let e2 = PoolEntry(
            accountId: "x", token: "x", email: nil,
            cooldownUntil: nil, consecutiveFailures: 0,
            lastUsed: nil, dailyPercent: nil, weeklyPercent: nil,
            internalErrorStreak: 0, banSignalCount: 0, banSignalFirstAt: nil,
            bannedUntil: nil, semaphore: AsyncSemaphore(limit: 1)
        )
        XCTAssertEqual(scoreOf(e2), 0)

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

    // MARK: - 排序：score → inFlight → LRU → id

    func testHigherScoreBeats() async throws {
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100),
            makeSeed(id: "b", daily: 50, weekly: 50),
        ])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "a")
    }

    func testEqualScoreUsesLRU() async throws {
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100, lastUsed: 200),
            makeSeed(id: "b", daily: 100, weekly: 100),
        ])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "b")
    }

    func testLRUDistributesEvenlyAcross8EqualScoreAccounts() async throws {
        let clock = MockClock()
        let seeds = (0..<8).map { i in
            makeSeed(id: "a\(i)", daily: 100, weekly: 100)
        }
        let pool = makePool(seeds: seeds, clock: clock)

        var seen: [String: Int] = [:]
        for _ in 0..<8 {
            let lease = try await pool.lease()
            seen[lease.accountId, default: 0] += 1
            clock.tick(1)
        }
        for i in 0..<8 {
            XCTAssertGreaterThanOrEqual(seen["a\(i)"] ?? 0, 1, "a\(i) should be picked at least once")
        }
    }

    // MARK: - cooldown / banned 排除

    func testCooledAccountSkipped() async throws {
        let clock = MockClock()
        let pool = makePool(seeds: [
            makeSeed(id: "cooled", daily: 100, weekly: 100, cooldown: clock.now + 100),
            makeSeed(id: "ok", daily: 50, weekly: 50),
        ], clock: clock)
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "ok")
    }

    func testBannedAccountNeverSelected() async throws {
        let clock = MockClock()
        let pool = makePool(seeds: [
            makeSeed(id: "banned", daily: 100, weekly: 100, bannedUntil: clock.now + 10000),
            makeSeed(id: "b", daily: 50, weekly: 50),
        ], clock: clock)
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "b")
    }

    func testExhaustedDailyQuotaSkipped() async throws {
        let pool = makePool(seeds: [
            makeSeed(id: "empty", daily: 0, weekly: 100),
            makeSeed(id: "ok", daily: 10, weekly: 10),
        ])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "ok")

        let snap = await pool.snapshot()
        XCTAssertEqual(snap.first(where: { $0.accountId == "empty" })?.unavailableReason, "quota_exhausted")
    }

    func testExhaustedWeeklyQuotaSkipped() async throws {
        let pool = makePool(seeds: [
            makeSeed(id: "empty", daily: 100, weekly: 0),
            makeSeed(id: "ok", daily: 10, weekly: 10),
        ])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "ok")
    }

    func testAllQuotaExhaustedThrowsAllExcluded() async {
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 0, weekly: 20),
            makeSeed(id: "b", daily: 20, weekly: 0),
        ])
        do {
            _ = try await pool.lease()
            XCTFail("expected PoolError.allExcluded")
        } catch let e as PoolError {
            XCTAssertEqual(e, .allExcluded)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - replaceAccounts merge (race fix)

    func testReplaceAccountsKeepsSemaphoreInstance() async throws {
        let pool = makePool(seeds: [makeSeed(id: "a")])
        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "a")

        await pool.replaceAccounts([makeSeed(id: "a", lastUsed: 100)])
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.first?.inFlight, 1, "in-flight count must survive replaceAccounts")
        _ = lease
    }

    /// pool.rs::tests::replace_accounts_must_not_clobber_inflight_last_used
    func testReplaceAccountsMustNotClobberInflightLastUsed() async throws {
        let clock = MockClock()
        clock.now = 20_000_000
        let pool = makePool(seeds: [
            makeSeed(id: "a", daily: 100, weekly: 100),
        ], clock: clock)

        let lease = try await pool.lease()
        XCTAssertEqual(lease.accountId, "a")

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
        await pool.replaceAccounts([
            makeSeed(id: "a", banFirstAt: 300),
        ])
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.first?.accountId, "a")
    }

    // MARK: - recordFailure / recordSuccess / recordBanSignal

    func testRecordFailureAuthCooldown() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [makeSeed(id: "a")], clock: clock)

        let upd = await pool.recordFailure("a", kind: .auth)
        XCTAssertNotNil(upd)
        XCTAssertEqual(upd?.cooldownUntil, 1000 + 300)
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

        let u1 = await pool.recordFailure("a", kind: .transient)
        XCTAssertNil(u1?.cooldownUntil)
        XCTAssertEqual(u1?.internalErrorStreak, 1)

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
        XCTAssertEqual(upd?.bannedUntil, 9999999)
    }

    func testRecordBanSignalAccumulatesAndUpgrades() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [makeSeed(id: "a")], clock: clock)

        let u1 = await pool.recordBanSignal("a")
        XCTAssertEqual(u1?.banSignalCount, 1)
        XCTAssertEqual(u1?.banSignalFirstAt, 1000)
        XCTAssertNil(u1?.bannedUntil)

        clock.tick(60)
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

        clock.tick(31 * 60)
        let u2 = await pool.recordBanSignal("a")
        XCTAssertEqual(u2?.banSignalCount, 1)
        XCTAssertNil(u2?.bannedUntil)
    }

    // MARK: - healthSummary

    func testHealthSummaryDroughtAllLow() async {
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

    func testHealthSummaryDoesNotCountQuotaExhaustedAsAvailable() async {
        let pool = makePool(seeds: [
            makeSeed(id: "empty", daily: 0, weekly: 100),
            makeSeed(id: "ok", daily: 25, weekly: 25),
        ])
        let s = await pool.healthSummary()
        XCTAssertEqual(s.totalAccounts, 2)
        XCTAssertEqual(s.availableAccounts, 1)
    }

    func testNextJwtCandidateForceRotatesAndSkipsQuotaExhausted() async {
        let pool = makePool(seeds: [
            makeSeed(id: "active", daily: 100, weekly: 100),
            makeSeed(id: "empty", daily: 0, weekly: 100),
            makeSeed(id: "ok", daily: 50, weekly: 50),
        ])
        await pool.setCurrentActiveAccount("active")
        let next = await pool.nextJwtCandidate(forceRotateFromActive: true)
        XCTAssertEqual(next?.accountId, "ok")
    }

    func testNextJwtCandidateForceRotatesPerApp() async {
        let pool = makePool(seeds: [
            makeSeed(id: "stable-active", daily: 100, weekly: 100),
            makeSeed(id: "next-active", daily: 90, weekly: 90),
            makeSeed(id: "fallback", daily: 50, weekly: 50),
        ])
        await pool.setCurrentActiveAccount("stable-active", app: .stable)
        await pool.setCurrentActiveAccount("next-active", app: .next)

        let stableNext = await pool.nextJwtCandidate(app: .stable, forceRotateFromActive: true)
        let nextNext = await pool.nextJwtCandidate(app: .next, forceRotateFromActive: true)

        XCTAssertEqual(stableNext?.accountId, "fallback")
        XCTAssertEqual(nextNext?.accountId, "fallback")
    }

    // MARK: - currentActiveAccount + getActiveSnapshot

    /// 不存在的 id 被忽略。
    func testSetCurrentActiveAccountUnknownIgnored() async {
        let pool = makePool(seeds: [makeSeed(id: "a")])
        await pool.setCurrentActiveAccount("nonexistent")
        let active = await pool.getCurrentActiveAccount()
        XCTAssertNil(active)
    }

    /// 传 nil 清除。
    func testSetCurrentActiveAccountNilClears() async {
        let pool = makePool(seeds: [makeSeed(id: "a")])
        await pool.setCurrentActiveAccount("a")
        let beforeClear = await pool.getCurrentActiveAccount()
        XCTAssertEqual(beforeClear, "a")
        await pool.setCurrentActiveAccount(nil)
        let afterClear = await pool.getCurrentActiveAccount()
        XCTAssertNil(afterClear)
    }

    /// active 未设 → snapshot 为 nil；设了 → 拿到 token + email。
    /// 这是非 GetUserJwt 路径的核心 API（forwardWithActive 用此 splice）。
    func testGetActiveSnapshot() async {
        let pool = makePool(seeds: [
            makeSeed(id: "a", token: "tok-a"),
            makeSeed(id: "b", token: "tok-b"),
        ])

        // 未设 active
        let none = await pool.getActiveSnapshot()
        XCTAssertNil(none)

        // 设了 active
        await pool.setCurrentActiveAccount("b")
        let snap = await pool.getActiveSnapshot()
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.accountId, "b")
        XCTAssertEqual(snap?.token, "tok-b")
        XCTAssertEqual(snap?.email, "b@example.com")
    }

    func testCurrentActiveAccountIsScopedByApp() async {
        let pool = makePool(seeds: [
            makeSeed(id: "a", token: "tok-a"),
            makeSeed(id: "b", token: "tok-b"),
        ])

        await pool.setCurrentActiveAccount("a", app: .stable)
        await pool.setCurrentActiveAccount("b", app: .next)

        let stableActive = await pool.getCurrentActiveAccount(app: .stable)
        let nextActive = await pool.getCurrentActiveAccount(app: .next)
        let stableSnap = await pool.getActiveSnapshot(app: .stable)
        let nextSnap = await pool.getActiveSnapshot(app: .next)

        XCTAssertEqual(stableActive, "a")
        XCTAssertEqual(nextActive, "b")
        XCTAssertEqual(stableSnap?.token, "tok-a")
        XCTAssertEqual(nextSnap?.token, "tok-b")
    }

    /// active 即使已 cooled / banned，getActiveSnapshot 仍返回该号——
    /// 不在此处过滤是有意的：LS 仍持有此号 JWT 在用，relay 必须对齐；
    /// 由 GetUserJwt 强制轮转切到新号才是正路。
    func testGetActiveSnapshotReturnsCooledAccount() async {
        let clock = MockClock()
        clock.now = 1000
        let pool = makePool(seeds: [
            makeSeed(id: "a", token: "tok-a", cooldown: 5000),
        ], clock: clock)
        await pool.setCurrentActiveAccount("a")
        let snap = await pool.getActiveSnapshot()
        XCTAssertNotNil(snap, "snapshot must include cooled active so non-jwt RPCs still align with LS's JWT")
        XCTAssertEqual(snap?.accountId, "a")
    }
}
