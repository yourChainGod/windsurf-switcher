//
//  JWTRewrite.swift
//  Relay
//
//  改写 GetUserJwt 响应中的 JWT exp claim。
//  直译 src-tauri/src/relay/jwt_rewrite.rs。
//
//  ## ⚠️ SAFETY: plan A 已实战否决（2026-05-02）
//
//  实战 (`WSS_JWT_TTL_SEC=600`) 发现：
//    - ✓ LS 不验签（接受改写 JWT 并照常使用）
//    - ✓ 上游 server.codeium.com 严格验签 → 401
//    - ✗ LS 收到 401 后不会自动重 auth — 直接卡死
//    - ✗ 卡死的 LS 必须用户手动重启编辑器才能恢复
//
//  此模块保留作为工具：未来配合 plan B（patch LS binary 把 cascade 域改劫持）
//  或别的方案，可能需要改写 JWT 其它字段（如 api_key、auth_uid）。
//
//  使用前提：必须保证 LS 拿到的 JWT 在上游能被验签通过。
//  单纯改 payload 而不重签，仅适用于"上游不消费此 token"的旁路 RPC。
//
//  gating：env WSS_JWT_TTL_SEC 未设 → 完全 passthrough。
//

import Foundation
import Core

public enum JWTRewriteError: Error, CustomStringConvertible {
    case protoParse(String)
    case noJwtField
    case jwtFormat
    case payloadBase64(String)
    case payloadJson(String)
    case payloadNotObject

    public var description: String {
        switch self {
        case .protoParse(let m): return "outer protobuf parse failed: \(m)"
        case .noJwtField: return "outer protobuf has no field 1 (JWT string)"
        case .jwtFormat: return "JWT string has wrong segment count (expected 3 dot-separated parts)"
        case .payloadBase64(let m): return "base64 decode of payload failed: \(m)"
        case .payloadJson(let m): return "payload is not valid JSON: \(m)"
        case .payloadNotObject: return "payload root is not a JSON object"
        }
    }
}

public enum JWTRewrite {
    /// 改写 GetUserJwt 响应 body，把 JWT.exp 改为 `newExpUnixSec`。
    /// 成功 → 新 body；失败 → throw（调用方应当透传原 body）。
    public static func rewriteJwtExp(_ body: Data, newExpUnixSec: Int64) throws -> Data {
        // 1. parse outer protobuf
        let fields: [Field]
        do {
            fields = try ProtoWire.parseFields(body)
        } catch {
            throw JWTRewriteError.protoParse("\(error)")
        }
        guard let jwt = ProtoWire.firstString(fields, 1) else {
            throw JWTRewriteError.noJwtField
        }

        // 2. split + decode payload
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw JWTRewriteError.jwtFormat
        }
        let headerB64 = parts[0]
        let payloadB64 = parts[1]
        let signatureB64 = parts[2]

        guard let payloadBytes = base64UrlDecode(payloadB64) else {
            throw JWTRewriteError.payloadBase64("invalid base64url")
        }

        // 3. parse JSON, modify exp
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: payloadBytes, options: [.mutableContainers])
        } catch {
            throw JWTRewriteError.payloadJson("\(error)")
        }
        guard var dict = any as? [String: Any] else {
            throw JWTRewriteError.payloadNotObject
        }
        dict["exp"] = NSNumber(value: newExpUnixSec)

        // 4. re-encode payload（用 sortedKeys 保证 byte-stable，便于 diff）
        let newPayloadBytes: Data
        do {
            newPayloadBytes = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        } catch {
            throw JWTRewriteError.payloadJson("encode: \(error)")
        }
        let newPayloadB64 = base64UrlEncode(newPayloadBytes)

        // 5. reassemble JWT
        let newJwt = "\(headerB64).\(newPayloadB64).\(signatureB64)"

        // 6. re-wrap field 1 + 附加原 body 后续字节（如果有别的字段）
        var out = Data()
        ProtoWire.writeStringField(1, newJwt, into: &out)

        // 算原 field 1 占的字节数：tag(1) + len varint + utf8 data
        // 实测 LS GetUserJwt 响应只有 field 1。但安全起见——
        var origField1Bytes = 0
        if let first = fields.first, first.number == 1, first.wireType == 2,
           case .lenDelim(let s) = first.value {
            // 用同样方式重新编码原值算长度
            var tmp = Data()
            ProtoWire.writeBytesField(1, s, into: &tmp)
            origField1Bytes = tmp.count
        }
        if origField1Bytes < body.count {
            out.append(body.subdata(in: (body.startIndex + origField1Bytes)..<body.endIndex))
        }

        return out
    }

    // MARK: - base64url helpers（不带 padding，匹配 RFC 7515）

    /// base64url-decode（无 padding）→ Data；非法返回 nil。
    public static func base64UrlDecode(_ s: String) -> Data? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 补 padding
        let mod = b64.count % 4
        if mod == 2 { b64 += "==" }
        else if mod == 3 { b64 += "=" }
        else if mod == 1 { return nil } // 非法长度
        return Data(base64Encoded: b64)
    }

    /// base64url-encode（无 padding）。
    public static func base64UrlEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
