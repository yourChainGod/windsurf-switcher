//
//  QuotaRewrite.swift
//  Relay
//
//  GetUserStatus / GetPlanStatus / CheckUserMessageRateLimit 响应改写。
//
//  ## 字段编号（源自 windsurf.rs parse_plan_status 注释）
//
//  GetPlanStatusResponse {
//    PlanStatus plan_status = 1 {
//      PlanInfo info = 1 {
//        tier = 1, plan_name = 2,
//        monthly_prompt_credits = 12, monthly_flow_credits = 13
//      }
//      Timestamp plan_start = 2 { seconds = 1 }
//      Timestamp plan_end   = 3 { seconds = 1 }
//      avail_flex_credits = 4, used_flow = 5, used_prompt = 6, used_flex = 7,
//      avail_prompt = 8, avail_flow = 9,
//      daily_percent = 14, weekly_percent = 15,
//      daily_reset = 17, weekly_reset = 18
//    }
//  }
//
//  GetUserStatusResponse 结构相似但外层包了一层：root.f1.f13 = PlanStatus。
//

import Foundation
import Core

public enum QuotaRewriteError: Error, CustomStringConvertible {
    case rootF1Missing
    case planStatusMissing
    case parseFailed(Error)

    public var description: String {
        switch self {
        case .rootF1Missing: return "root.f1 missing"
        case .planStatusMissing: return "root.f1.f13 (PlanStatus) missing"
        case .parseFailed(let e): return "parse failed: \(e)"
        }
    }
}

public enum QuotaRewrite {
    public static let huge: UInt64 = 1_000_000

    /// 构造伪造的 GetPlanStatusResponse protobuf body：
    /// 始终返回 Enterprise / 配额满血 / 永远不到期。
    public static func buildFakePlanStatusBody(now: Int64 = Int64(Date().timeIntervalSince1970)) -> Data {
        let day: UInt64 = 86_400
        let nowU = UInt64(now)

        // PlanInfo（plan_status.info, field 1）
        var planInfo = Data()
        ProtoWire.writeVarintField(1, 4, into: &planInfo)                                  // tier=4 Enterprise
        ProtoWire.writeStringField(2, "Enterprise", into: &planInfo)
        ProtoWire.writeVarintField(12, huge, into: &planInfo)                              // monthly_prompt_credits
        ProtoWire.writeVarintField(13, huge, into: &planInfo)                              // monthly_flow_credits

        // PlanStatus（外层 field 1）
        var planStatus = Data()
        ProtoWire.writeMessageField(1, planInfo, into: &planStatus)                        // info
        ProtoWire.writeMessageField(2, makeTimestamp(nowU - day), into: &planStatus)       // plan_start
        ProtoWire.writeMessageField(3, makeTimestamp(nowU + 365 * day), into: &planStatus) // plan_end
        ProtoWire.writeVarintField(4, huge, into: &planStatus)                             // avail_flex
        ProtoWire.writeVarintField(5, 0, into: &planStatus)                                // used_flow
        ProtoWire.writeVarintField(6, 0, into: &planStatus)                                // used_prompt
        ProtoWire.writeVarintField(7, 0, into: &planStatus)                                // used_flex
        ProtoWire.writeVarintField(8, huge, into: &planStatus)                             // avail_prompt
        ProtoWire.writeVarintField(9, huge, into: &planStatus)                             // avail_flow
        ProtoWire.writeVarintField(14, 100, into: &planStatus)                             // daily_percent
        ProtoWire.writeVarintField(15, 100, into: &planStatus)                             // weekly_percent
        ProtoWire.writeVarintField(17, nowU + day, into: &planStatus)                      // daily_reset
        ProtoWire.writeVarintField(18, nowU + 7 * day, into: &planStatus)                  // weekly_reset

        // GetPlanStatusResponse（root）
        var root = Data()
        ProtoWire.writeMessageField(1, planStatus, into: &root)
        return root
    }

    /// 构造伪造的 CheckUserMessageRateLimitResponse protobuf body。
    ///
    /// 字段定义（来自 windsurf IDE chat-client/index.js 抓取）：
    ///   exa.language_server_pb.CheckUserMessageRateLimitResponse
    ///     field 1: has_capacity (bool)        ← 必须 true，否则 IDE 判定限流
    ///     field 2: message (string)
    ///     field 3: messages_remaining (int32)
    ///     field 4: max_messages (int32)
    ///     field 5: resets_in_seconds (int64)
    public static func buildFakeCheckRateLimitBody() -> Data {
        var body = Data()
        ProtoWire.writeVarintField(1, 1, into: &body)         // has_capacity = true
        ProtoWire.writeVarintField(3, huge, into: &body)      // messages_remaining = 1M
        ProtoWire.writeVarintField(4, huge, into: &body)      // max_messages = 1M
        ProtoWire.writeVarintField(5, 0, into: &body)         // resets_in_seconds = 0
        return body
    }

    /// 改写 GetUserStatus 响应：剥到 root.f1.f13 (PlanStatus)，
    /// 替换 quota 字段为满血值，重 encode。
    /// 失败时 throw —— 上层应当用原始 body 透传。
    public static func rewriteUserStatusQuota(_ body: Data, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Data {
        let day: UInt64 = 86_400
        let nowU = UInt64(now)

        // 1. 解 root，找 f1
        let rootFields: [Field]
        do {
            rootFields = try ProtoWire.parseFields(body)
        } catch {
            throw QuotaRewriteError.parseFailed(error)
        }
        var rootF1Bytes: Data? = nil
        for f in rootFields where f.number == 1 {
            if case .lenDelim(let b) = f.value {
                rootF1Bytes = b
                break
            }
        }
        guard let rootF1 = rootF1Bytes else {
            throw QuotaRewriteError.rootF1Missing
        }

        // 2. 解 root.f1，找 f13 (PlanStatus)
        let f1Fields: [Field]
        do {
            f1Fields = try ProtoWire.parseFields(rootF1)
        } catch {
            throw QuotaRewriteError.parseFailed(error)
        }

        var newF1 = Data()
        newF1.reserveCapacity(rootF1.count + 32)
        var foundF13 = false
        for f in f1Fields {
            if f.number == 13 {
                if case .lenDelim(let b) = f.value {
                    let newPlanStatus = try rewritePlanStatus(b, now: nowU, day: day, huge: huge)
                    ProtoWire.writeMessageField(13, newPlanStatus, into: &newF1)
                    foundF13 = true
                    continue
                }
            }
            writePassthroughField(f, into: &newF1)
        }
        if !foundF13 {
            throw QuotaRewriteError.planStatusMissing
        }

        // 3. 重 encode root：f1 替换为新版，其它字段原样
        var newRoot = Data()
        newRoot.reserveCapacity(body.count + 64)
        var wroteF1 = false
        for f in rootFields {
            if f.number == 1 && !wroteF1 {
                ProtoWire.writeMessageField(1, newF1, into: &newRoot)
                wroteF1 = true
                continue
            }
            writePassthroughField(f, into: &newRoot)
        }
        return newRoot
    }

    /// 改写 PlanStatus 子消息：替换 quota 字段，保留其它字段。
    static func rewritePlanStatus(_ body: Data, now: UInt64, day: UInt64, huge: UInt64) throws -> Data {
        let fields: [Field]
        do {
            fields = try ProtoWire.parseFields(body)
        } catch {
            throw QuotaRewriteError.parseFailed(error)
        }

        var out = Data()
        out.reserveCapacity(body.count + 32)
        for f in fields {
            switch f.number {
            // f4 avail_flex_credits / f8 avail_prompt / f9 avail_flow → HUGE
            case 4, 8, 9:
                ProtoWire.writeVarintField(f.number, huge, into: &out)
            // f5 used_flow / f6 used_prompt / f7 used_flex → 0
            case 5, 6, 7:
                ProtoWire.writeVarintField(f.number, 0, into: &out)
            // f14 daily_percent / f15 weekly_percent → 100
            case 14, 15:
                ProtoWire.writeVarintField(f.number, 100, into: &out)
            // f16 (unsigned -99667 实测，看起来某种 used) → 0
            case 16:
                ProtoWire.writeVarintField(16, 0, into: &out)
            // f17 daily_reset → 推到未来 1 天
            case 17:
                ProtoWire.writeVarintField(17, now + day, into: &out)
            // f18 weekly_reset → 推到未来 7 天
            case 18:
                ProtoWire.writeVarintField(18, now + 7 * day, into: &out)
            // 其他字段（f1 PlanInfo / f2 plan_start / f3 plan_end 等）原样
            default:
                writePassthroughField(f, into: &out)
            }
        }
        return out
    }

    /// 把一个解析出的字段原样写回 buffer（用于不需要改写的字段）。
    static func writePassthroughField(_ f: Field, into out: inout Data) {
        switch f.value {
        case .varint(let v):
            ProtoWire.writeVarintField(f.number, v, into: &out)
        case .lenDelim(let b):
            ProtoWire.writeBytesField(f.number, b, into: &out)
        case .fixed32(let b):
            ProtoWire.writeTag(field: f.number, wireType: 5, into: &out)
            out.append(b)
        case .fixed64(let b):
            ProtoWire.writeTag(field: f.number, wireType: 1, into: &out)
            out.append(b)
        }
    }

    /// Timestamp { seconds = 1 } 子消息。
    private static func makeTimestamp(_ secs: UInt64) -> Data {
        var out = Data()
        ProtoWire.writeVarintField(1, secs, into: &out)
        return out
    }
}
