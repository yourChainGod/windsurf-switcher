//
//  QuotaRewriteTests.swift
//  RelayTests
//
//  验 build_fake_plan_status_body + rewrite_user_status_quota 字节正确性。
//

import XCTest
import Core
@testable import Relay

final class QuotaRewriteTests: XCTestCase {

    // MARK: build_fake_plan_status_body

    func testFakeBodyIsParseable() throws {
        let body = QuotaRewrite.buildFakePlanStatusBody(now: 1714530000)
        let root = try ProtoWire.parseFields(body)
        XCTAssertEqual(root.count, 1)
        XCTAssertEqual(root[0].number, 1)
        guard case .lenDelim(let planStatusBytes) = root[0].value else {
            XCTFail("root.f1 should be lenDelim")
            return
        }

        let planStatus = try ProtoWire.parseFields(planStatusBytes)
        // 必含字段：1=PlanInfo, 2=plan_start, 3=plan_end, 4=avail_flex,
        // 5,6,7=used_*, 8=avail_prompt, 9=avail_flow,
        // 14=daily_pct, 15=weekly_pct, 17,18=resets
        var fieldNumbers = Set<UInt32>()
        for f in planStatus { fieldNumbers.insert(f.number) }
        for n: UInt32 in [1, 2, 3, 4, 5, 6, 7, 8, 9, 14, 15, 17, 18] {
            XCTAssertTrue(fieldNumbers.contains(n), "missing field \(n)")
        }

        XCTAssertEqual(ProtoWire.firstVarint(planStatus, 4), QuotaRewrite.huge, "avail_flex")
        XCTAssertEqual(ProtoWire.firstVarint(planStatus, 5), 0, "used_flow")
        XCTAssertEqual(ProtoWire.firstVarint(planStatus, 8), QuotaRewrite.huge, "avail_prompt")
        XCTAssertEqual(ProtoWire.firstVarint(planStatus, 9), QuotaRewrite.huge, "avail_flow")
        XCTAssertEqual(ProtoWire.firstVarint(planStatus, 14), 100, "daily_pct")
        XCTAssertEqual(ProtoWire.firstVarint(planStatus, 15), 100, "weekly_pct")
    }

    func testFakeBodyPlanInfoEnterprise() throws {
        let body = QuotaRewrite.buildFakePlanStatusBody(now: 1714530000)
        let root = try ProtoWire.parseFields(body)
        guard case .lenDelim(let psBytes) = root[0].value else { XCTFail(); return }
        let ps = try ProtoWire.parseFields(psBytes)
        guard let info = ProtoWire.firstBytes(ps, 1) else { XCTFail(); return }
        let infoFields = try ProtoWire.parseFields(info)
        XCTAssertEqual(ProtoWire.firstVarint(infoFields, 1), 4, "tier=4 Enterprise")
        XCTAssertEqual(ProtoWire.firstString(infoFields, 2), "Enterprise")
        XCTAssertEqual(ProtoWire.firstVarint(infoFields, 12), QuotaRewrite.huge)
        XCTAssertEqual(ProtoWire.firstVarint(infoFields, 13), QuotaRewrite.huge)
    }

    // MARK: rewrite_user_status_quota

    /// 构造一个最小可用的 GetUserStatus 响应：root.f1.f13 = PlanStatus 子消息。
    private func buildMinimalGetUserStatus(planStatusFields: [(UInt32, UInt64)]) -> Data {
        var planStatus = Data()
        for (n, v) in planStatusFields {
            ProtoWire.writeVarintField(n, v, into: &planStatus)
        }
        var f1 = Data()
        ProtoWire.writeMessageField(13, planStatus, into: &f1)
        var root = Data()
        ProtoWire.writeMessageField(1, f1, into: &root)
        return root
    }

    func testRewriteReplacesQuotaFields() throws {
        // 模拟上游真实响应：avail_prompt=100, daily_pct=5, weekly_pct=3
        let original = buildMinimalGetUserStatus(planStatusFields: [
            (8, 100),    // avail_prompt
            (9, 50),     // avail_flow
            (14, 5),     // daily_pct
            (15, 3),     // weekly_pct
        ])

        let rewritten = try QuotaRewrite.rewriteUserStatusQuota(original, now: 1714530000)
        let root = try ProtoWire.parseFields(rewritten)
        guard case .lenDelim(let f1Bytes) = root[0].value else { XCTFail(); return }
        let f1 = try ProtoWire.parseFields(f1Bytes)
        guard let psBytes = ProtoWire.firstBytes(f1, 13) else { XCTFail(); return }
        let ps = try ProtoWire.parseFields(psBytes)

        XCTAssertEqual(ProtoWire.firstVarint(ps, 8), QuotaRewrite.huge, "avail_prompt 100→huge")
        XCTAssertEqual(ProtoWire.firstVarint(ps, 9), QuotaRewrite.huge, "avail_flow 50→huge")
        XCTAssertEqual(ProtoWire.firstVarint(ps, 14), 100, "daily_pct 5→100")
        XCTAssertEqual(ProtoWire.firstVarint(ps, 15), 100, "weekly_pct 3→100")
    }

    func testRewritePreservesUnrelatedFields() throws {
        var planStatus = Data()
        ProtoWire.writeVarintField(8, 100, into: &planStatus)        // 会被改
        ProtoWire.writeVarintField(20, 999, into: &planStatus)       // 应保留（未知字段 passthrough）
        var f1 = Data()
        ProtoWire.writeMessageField(13, planStatus, into: &f1)
        var root = Data()
        ProtoWire.writeMessageField(1, f1, into: &root)

        let rewritten = try QuotaRewrite.rewriteUserStatusQuota(root, now: 1714530000)
        let rt = try ProtoWire.parseFields(rewritten)
        guard case .lenDelim(let f1Bytes) = rt[0].value else { XCTFail(); return }
        let f1f = try ProtoWire.parseFields(f1Bytes)
        guard let psBytes = ProtoWire.firstBytes(f1f, 13) else { XCTFail(); return }
        let ps = try ProtoWire.parseFields(psBytes)
        XCTAssertEqual(ProtoWire.firstVarint(ps, 20), 999, "unknown field passthrough")
        XCTAssertEqual(ProtoWire.firstVarint(ps, 8), QuotaRewrite.huge, "f8 rewritten")
    }

    func testRewriteThrowsOnMissingF1() {
        let bad = Data([0x10, 0x05]) // root.f2=varint 5（无 f1）
        XCTAssertThrowsError(try QuotaRewrite.rewriteUserStatusQuota(bad)) { e in
            guard case QuotaRewriteError.rootF1Missing = e else {
                XCTFail("expected rootF1Missing, got \(e)")
                return
            }
        }
    }

    func testRewriteThrowsOnMissingPlanStatus() {
        // root.f1 存在，但里面没有 f13
        var f1 = Data()
        ProtoWire.writeVarintField(2, 0, into: &f1)
        var root = Data()
        ProtoWire.writeMessageField(1, f1, into: &root)

        XCTAssertThrowsError(try QuotaRewrite.rewriteUserStatusQuota(root)) { e in
            guard case QuotaRewriteError.planStatusMissing = e else {
                XCTFail("expected planStatusMissing, got \(e)")
                return
            }
        }
    }

    func testRewriteResetTimesPushedFuture() throws {
        let original = buildMinimalGetUserStatus(planStatusFields: [
            (17, 100),    // 早已过期
            (18, 100),
        ])
        let now: Int64 = 1714530000
        let rewritten = try QuotaRewrite.rewriteUserStatusQuota(original, now: now)
        let root = try ProtoWire.parseFields(rewritten)
        guard case .lenDelim(let f1Bytes) = root[0].value else { XCTFail(); return }
        let f1 = try ProtoWire.parseFields(f1Bytes)
        guard let psBytes = ProtoWire.firstBytes(f1, 13) else { XCTFail(); return }
        let ps = try ProtoWire.parseFields(psBytes)
        let day: UInt64 = 86_400
        XCTAssertEqual(ProtoWire.firstVarint(ps, 17), UInt64(now) + day, "daily_reset = now + 1d")
        XCTAssertEqual(ProtoWire.firstVarint(ps, 18), UInt64(now) + 7 * day, "weekly_reset = now + 7d")
    }
}
