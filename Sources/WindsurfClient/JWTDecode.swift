//
//  JWTDecode.swift
//  WindsurfClient
//
//  不验签 JWT payload 解析。
//  仅用作 UI 展示——上游验签由 windsurf 云端处理。
//
//  Token 形式两种：
//    1. 裸 JWT：`<header>.<payload>.<signature>`
//    2. 完整 cookie 值：`devin-session-token$<JWT>`
//

import Foundation
import Core

public enum JWTDecode {
    /// `devin-session-token$` 前缀；剥离后是裸 JWT。
    public static let cookieValuePrefix = "devin-session-token$"

    /// 取裸 JWT（去掉可能的 cookie value 前缀）。
    public static func jwtOnly(_ token: String) -> String {
        if token.hasPrefix(cookieValuePrefix) {
            return String(token.dropFirst(cookieValuePrefix.count))
        }
        return token
    }

    /// 加上 cookie value 前缀（避免双前缀）。
    public static func prefixed(_ token: String) -> String {
        if token.hasPrefix(cookieValuePrefix) { return token }
        return cookieValuePrefix + token
    }

    /// 不验签，仅 base64url decode payload，提取常见字段。
    /// 解析失败返回 nil，不抛异常。
    public static func decode(_ token: String) -> JWTInfo? {
        let bare = jwtOnly(token)
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let payloadB64 = String(parts[1])
        guard let payloadData = base64urlDecode(payloadB64) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        var info = JWTInfo()
        info.sessionId = json["session_id"] as? String
        info.email = json["email"] as? String
        info.userId = (json["user_id"] as? String) ?? (json["sub"] as? String)
        if let exp = json["exp"] as? Double {
            info.expiresAt = Date(timeIntervalSince1970: exp)
        } else if let exp = json["exp"] as? Int {
            info.expiresAt = Date(timeIntervalSince1970: TimeInterval(exp))
        }
        if let iat = json["iat"] as? Double {
            info.issuedAt = Date(timeIntervalSince1970: iat)
        } else if let iat = json["iat"] as? Int {
            info.issuedAt = Date(timeIntervalSince1970: TimeInterval(iat))
        }
        return info
    }

    /// base64url（无 padding）→ Data。
    public static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        // 补齐 padding 到 4 的倍数
        let pad = (4 - t.count % 4) % 4
        t.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: t)
    }

    /// base64url（无 padding）编码。
    public static func base64urlEncode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
             .replacingOccurrences(of: "/", with: "_")
             .replacingOccurrences(of: "=", with: "")
        return s
    }
}
