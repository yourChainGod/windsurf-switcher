//
//  GetPlanStatusTests.swift
//  WindsurfClientTests
//
//  本地构造一段 protobuf 响应，验证解析路径覆盖到所有字段编号。
//

import XCTest
@testable import WindsurfClient
@testable import Core

final class GetPlanStatusTests: XCTestCase {

    /// 构造一个完整的 GetPlanStatus 响应 body。
    private func makeResponse(
        planName: String = "Pro",
        promptCredits: UInt64 = 50000,
        flowCredits: UInt64 = 1000,
        planStartUnix: UInt64 = 1700000000,
        planEndUnix: UInt64 = 1800000000,
        usedPrompt: UInt64 = 100,
        usedFlow: UInt64 = 50,
        usedFlex: UInt64 = 0,
        availPrompt: UInt64 = 49900,
        availFlow: UInt64 = 950,
        availFlex: UInt64 = 1000,
        dailyPercent: UInt64? = 87,
        weeklyPercent: UInt64? = 65,
        dailyResetUnix: UInt64? = 1_777_722_000,
        weeklyResetUnix: UInt64? = 1_778_122_000
    ) -> Data {
        // PlanInfo (field 1 inner)
        var info = Data()
        ProtoWire.writeVarintField(1, 1, into: &info)             // tier
        ProtoWire.writeStringField(2, planName, into: &info)
        ProtoWire.writeVarintField(12, promptCredits, into: &info)
        ProtoWire.writeVarintField(13, flowCredits, into: &info)

        // Timestamp { seconds = 1 } 嵌套
        func ts(_ unix: UInt64) -> Data {
            var b = Data()
            ProtoWire.writeVarintField(1, unix, into: &b)
            return b
        }

        // PlanStatus inner
        var ps = Data()
        ProtoWire.writeMessageField(1, info, into: &ps)
        ProtoWire.writeMessageField(2, ts(planStartUnix), into: &ps)
        ProtoWire.writeMessageField(3, ts(planEndUnix), into: &ps)
        ProtoWire.writeVarintField(4, availFlex, into: &ps)
        ProtoWire.writeVarintField(5, usedFlow, into: &ps)
        ProtoWire.writeVarintField(6, usedPrompt, into: &ps)
        ProtoWire.writeVarintField(7, usedFlex, into: &ps)
        ProtoWire.writeVarintField(8, availPrompt, into: &ps)
        ProtoWire.writeVarintField(9, availFlow, into: &ps)
        if let dp = dailyPercent {
            ProtoWire.writeVarintField(14, dp, into: &ps)
        }
        if let wp = weeklyPercent {
            ProtoWire.writeVarintField(15, wp, into: &ps)
        }
        if let dr = dailyResetUnix {
            ProtoWire.writeVarintField(17, dr, into: &ps)
        }
        if let wr = weeklyResetUnix {
            ProtoWire.writeVarintField(18, wr, into: &ps)
        }

        // 外层 GetPlanStatusResponse
        var root = Data()
        ProtoWire.writeMessageField(1, ps, into: &root)
        return root
    }

    func testFullResponseParse() throws {
        let body = makeResponse()
        let plan = try GetPlanStatusClient.parsePlanStatus(body)

        XCTAssertEqual(plan.planName, "Pro")
        XCTAssertEqual(plan.dailyPercent, 87)
        XCTAssertEqual(plan.weeklyPercent, 65)
        XCTAssertEqual(plan.promptUsed, 100)
        XCTAssertEqual(plan.promptLimit, 50000)
        XCTAssertEqual(plan.promptRemaining, 49900)
        XCTAssertEqual(plan.flowUsed, 50)
        XCTAssertEqual(plan.flowLimit, 1000)
        XCTAssertEqual(plan.flowRemaining, 950)
        XCTAssertEqual(plan.flexRemaining, 1000)
        XCTAssertEqual(plan.planStart?.timeIntervalSince1970, 1700000000)
        XCTAssertEqual(plan.planEnd?.timeIntervalSince1970, 1800000000)
        XCTAssertEqual(plan.dailyResetAt?.timeIntervalSince1970, 1_777_722_000)
        XCTAssertEqual(plan.weeklyResetAt?.timeIntervalSince1970, 1_778_122_000)
    }

    /// proto3 默认值 0 在 wire 上会被省略 → 配合 reset 存在时 percent 缺失应解释为 0。
    func testZeroPercentInferredWhenResetPresent() throws {
        let body = makeResponse(dailyPercent: nil, weeklyPercent: nil)
        let plan = try GetPlanStatusClient.parsePlanStatus(body)
        XCTAssertEqual(plan.dailyPercent, 0)
        XCTAssertEqual(plan.weeklyPercent, 0)
    }

    /// 无 reset 也无 percent → nil（未启用该度量）。
    func testMissingPercentWithoutResetIsNil() throws {
        let body = makeResponse(
            dailyPercent: nil, weeklyPercent: nil,
            dailyResetUnix: nil, weeklyResetUnix: nil
        )
        let plan = try GetPlanStatusClient.parsePlanStatus(body)
        XCTAssertNil(plan.dailyPercent)
        XCTAssertNil(plan.weeklyPercent)
    }

    /// 越界 percent（>100）应丢弃为 nil（不允许 relay/wrapper 误读）。
    func testOutOfRangePercentDiscarded() throws {
        let body = makeResponse(dailyPercent: 150, weeklyPercent: 200)
        let plan = try GetPlanStatusClient.parsePlanStatus(body)
        XCTAssertNil(plan.dailyPercent)
        XCTAssertNil(plan.weeklyPercent)
    }

    /// reset 时间戳 < 2023-11-14 下界 → 视为无效丢弃。
    func testTooOldResetUnixDiscarded() throws {
        let body = makeResponse(
            dailyResetUnix: 1_000_000, weeklyResetUnix: 1_000_000
        )
        let plan = try GetPlanStatusClient.parsePlanStatus(body)
        XCTAssertNil(plan.dailyResetAt)
        XCTAssertNil(plan.weeklyResetAt)
    }
}
