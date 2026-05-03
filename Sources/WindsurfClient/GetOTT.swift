//
//  GetOTT.swift
//  WindsurfClient
//
//  调 Windsurf 后端 GetOneTimeAuthToken。
//
//  请求拓扑：
//    POST https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetOneTimeAuthToken
//    Content-Type: application/proto
//    Cookie: devin-session-token=<裸 JWT>
//    Body: protobuf 单字段 string field 1 = "devin-session-token$<JWT>"
//
//  响应：protobuf 单字段 string field 1 = "/ott$<48字节随机串>"，可能带尾换行 + 5 字节 grpc-web frame header。
//

import Foundation
import Core

public enum GetOTTError: Error, CustomStringConvertible {
    case httpStatus(Int, body: String)
    case responseTooShort(Int)
    case parseFailed(String)
    case ottEmpty

    public var description: String {
        switch self {
        case .httpStatus(let code, let body):
            return "GetOneTimeAuthToken HTTP \(code) body=\(body.prefix(200))"
        case .responseTooShort(let n):
            return "GetOneTimeAuthToken response too short (\(n) bytes)"
        case .parseFailed(let msg):
            return "GetOneTimeAuthToken parse failed: \(msg)"
        case .ottEmpty:
            return "GetOneTimeAuthToken returned empty OTT"
        }
    }
}

public enum WindsurfBackend {
    /// `windsurf.com/_backend` 反代（GetOTT 走此入口）。
    public static let webBase = "https://windsurf.com/_backend"

    /// `web-backend.windsurf.com` 直连（GetPlanStatus 走此入口）。
    public static let apiBase = "https://web-backend.windsurf.com"

    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
}

public actor GetOTTClient {
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

    /// `token` 既可以是裸 JWT，也可以是完整 `devin-session-token$<JWT>`。
    /// 返回 OTT 字符串（已 trim 尾换行）。
    public func getOneTimeAuthToken(token: String) async throws -> String {
        let body = Self.buildRequestBody(token: token)
        let cookieValue = JWTDecode.jwtOnly(token)

        let url = URL(string: "\(WindsurfBackend.webBase)/exa.seat_management_pb.SeatManagementService/GetOneTimeAuthToken")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/proto", forHTTPHeaderField: "content-type")
        req.setValue("application/proto", forHTTPHeaderField: "accept")
        req.setValue("devin-session-token=\(cookieValue)", forHTTPHeaderField: "cookie")
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GetOTTError.parseFailed("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let preview = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            throw GetOTTError.httpStatus(http.statusCode, body: preview)
        }
        return try Self.parseResponse(data)
    }

    /// 构造请求 body：单字段 string field 1 = "devin-session-token$<JWT>"。
    static func buildRequestBody(token: String) -> Data {
        let payload = JWTDecode.prefixed(token)
        var buf = Data()
        ProtoWire.writeStringField(1, payload, into: &buf)
        return buf
    }

    /// 解析响应 body。先尝试整 buf 解 protobuf；失败再剥前 5 字节 grpc-web frame 重试。
    static func parseResponse(_ data: Data) throws -> String {
        // 主路径
        if let s = try? extractField1String(from: data) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw GetOTTError.ottEmpty }
            return trimmed
        }
        // 兼容 grpc-web frame：5 字节 0x00 + len32 前缀
        if data.count > 5 {
            let trimmed = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
            if let s = try? extractField1String(from: trimmed) {
                let final = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if final.isEmpty { throw GetOTTError.ottEmpty }
                return final
            }
        }
        if data.count <= 2 {
            throw GetOTTError.responseTooShort(data.count)
        }
        throw GetOTTError.parseFailed("could not parse field 1 string from \(data.count) bytes")
    }

    private static func extractField1String(from data: Data) throws -> String {
        let fields = try ProtoWire.parseFields(data)
        guard let s = ProtoWire.firstString(fields, 1) else {
            throw GetOTTError.parseFailed("field 1 missing in response")
        }
        return s
    }
}
