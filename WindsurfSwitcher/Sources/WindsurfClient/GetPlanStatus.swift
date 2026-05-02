//
//  GetPlanStatus.swift
//  WindsurfClient
//
//  调 windsurf web-backend GetPlanStatus（直译 src-tauri/src/windsurf.rs:273-340）。
//
//  请求拓扑：
//    POST https://web-backend.windsurf.com/exa.seat_management_pb.SeatManagementService/GetPlanStatus
//    Content-Type: application/proto
//    connect-protocol-version: 1
//    x-auth-token / x-devin-session-token: "devin-session-token$<JWT>"  (双 header 鉴权)
//    Body: protobuf 单字段 string field 1 = "devin-session-token$<JWT>"
//
//  响应 protobuf 嵌套结构（字段编号来源 chaogei + zhouyoukang/wam 实测整理）：
//    GetPlanStatusResponse {
//      PlanStatus plan_status = 1 {
//        PlanInfo info = 1 {
//          tier=1, plan_name=2, monthly_prompt_credits=12, monthly_flow_credits=13
//        }
//        Timestamp plan_start = 2 { seconds=1 }
//        Timestamp plan_end   = 3 { seconds=1 }
//        avail_flex=4, used_flow=5, used_prompt=6, used_flex=7,
//        avail_prompt=8, avail_flow=9,
//        daily_quota_remaining_percent=14, weekly_quota_remaining_percent=15,
//        daily_quota_reset_at_unix=17, weekly_quota_reset_at_unix=18,
//      }
//    }
//

import Foundation
import Core

public enum GetPlanStatusError: Error, CustomStringConvertible {
    case httpStatus(Int, body: String)
    case parseFailed(String)

    public var description: String {
        switch self {
        case .httpStatus(let code, let body):
            return "GetPlanStatus HTTP \(code) body=\(body.prefix(200))"
        case .parseFailed(let msg):
            return "GetPlanStatus parse failed: \(msg)"
        }
    }
}

public actor GetPlanStatusClient {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let s = session {
            self.session = s
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpAdditionalHeaders = ["User-Agent": WindsurfBackend.userAgent]
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 30
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// 单次重试（5xx / network），与旧版 try_get_plan_status_once 行为一致。
    public func getPlanStatus(token: String) async throws -> PlanStatus {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                return try await tryOnce(token: token)
            } catch {
                let msg = String(describing: error).lowercased()
                let retryable = msg.contains("timed out")
                    || msg.contains("connection")
                    || msg.contains("http 5")
                    || msg.contains("network connection lost")
                if attempt == 1 && retryable {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? GetPlanStatusError.parseFailed("exhausted retries")
    }

    private func tryOnce(token: String) async throws -> PlanStatus {
        let prefixed = JWTDecode.prefixed(token)
        var body = Data()
        ProtoWire.writeStringField(1, prefixed, into: &body)

        let url = URL(string: "\(WindsurfBackend.apiBase)/exa.seat_management_pb.SeatManagementService/GetPlanStatus")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/proto", forHTTPHeaderField: "content-type")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        req.setValue(prefixed, forHTTPHeaderField: "x-auth-token")
        req.setValue(prefixed, forHTTPHeaderField: "x-devin-session-token")
        req.setValue("", forHTTPHeaderField: "x-debug-email")
        req.setValue("", forHTTPHeaderField: "x-debug-team-name")
        req.setValue("https://windsurf.com/", forHTTPHeaderField: "referer")
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GetPlanStatusError.parseFailed("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let preview = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            throw GetPlanStatusError.httpStatus(http.statusCode, body: preview)
        }
        return try Self.parsePlanStatus(data)
    }

    /// 解析 protobuf 响应。失败抛 GetPlanStatusError.parseFailed。
    static func parsePlanStatus(_ buf: Data) throws -> PlanStatus {
        let root: [Field]
        do {
            root = try ProtoWire.parseFields(buf)
        } catch {
            throw GetPlanStatusError.parseFailed("root parse: \(error)")
        }
        guard let psBytes = ProtoWire.firstBytes(root, 1) else {
            throw GetPlanStatusError.parseFailed("plan_status (field 1) missing")
        }
        let ps: [Field]
        do {
            ps = try ProtoWire.parseFields(psBytes)
        } catch {
            throw GetPlanStatusError.parseFailed("plan_status inner parse: \(error)")
        }

        // PlanInfo (field 1, sub-message)
        var planName: String? = nil
        var promptLimit: Int? = nil
        var flowLimit: Int? = nil
        if let infoBytes = ProtoWire.firstBytes(ps, 1) {
            if let pi = try? ProtoWire.parseFields(infoBytes) {
                planName = ProtoWire.firstString(pi, 2)
                promptLimit = ProtoWire.firstVarint(pi, 12).map(Int.init)
                flowLimit = ProtoWire.firstVarint(pi, 13).map(Int.init)
            }
        }

        // Timestamp { seconds = 1 } 嵌套
        let extractTs: (UInt32) -> Date? = { fieldNum in
            guard let b = ProtoWire.firstBytes(ps, fieldNum) else { return nil }
            guard let inner = try? ProtoWire.parseFields(b) else { return nil }
            guard let secs = ProtoWire.firstVarint(inner, 1) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(secs))
        }
        let planStart = extractTs(2)
        let planEnd = extractTs(3)

        // credits 计数
        let availFlex = ProtoWire.firstVarint(ps, 4).map(Int.init)
        let usedFlow = ProtoWire.firstVarint(ps, 5).map(Int.init)
        let usedPrompt = ProtoWire.firstVarint(ps, 6).map(Int.init)
        let usedFlex = ProtoWire.firstVarint(ps, 7).map(Int.init)
        let availPrompt = ProtoWire.firstVarint(ps, 8).map(Int.init)
        let availFlow = ProtoWire.firstVarint(ps, 9).map(Int.init)

        // 重置 unix 必须 > 1700000000（2023-11-14 下界），否则丢弃
        let extractReset: (UInt32) -> Date? = { fieldNum in
            guard let v = ProtoWire.firstVarint(ps, fieldNum) else { return nil }
            guard v > 1_700_000_000 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(v))
        }
        let dailyResetAt = extractReset(17)
        let weeklyResetAt = extractReset(18)

        // 百分比配额：0-100 剩余。proto3 默认值 0 会省略——配合 reset 存在时 percent 缺失就解释为 0。
        let pct: (UInt32, Bool) -> Int? = { fieldNum, hasReset in
            if let v = ProtoWire.firstVarint(ps, fieldNum) {
                if v <= 100 { return Int(v) }
                return nil // 越界值丢弃
            }
            return hasReset ? 0 : nil
        }
        let dailyPercent = pct(14, dailyResetAt != nil)
        let weeklyPercent = pct(15, weeklyResetAt != nil)

        var out = PlanStatus(fetchedAt: Date())
        out.planName = planName
        out.planStart = planStart
        out.planEnd = planEnd
        out.dailyPercent = dailyPercent
        out.weeklyPercent = weeklyPercent
        out.dailyResetAt = dailyResetAt
        out.weeklyResetAt = weeklyResetAt
        out.promptUsed = usedPrompt
        out.promptLimit = promptLimit
        out.promptRemaining = availPrompt
        out.flowUsed = usedFlow
        out.flowLimit = flowLimit
        out.flowRemaining = availFlow
        out.flexUsed = usedFlex
        out.flexRemaining = availFlex
        return out
    }
}
