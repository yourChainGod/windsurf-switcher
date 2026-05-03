//
//  ProtoRewrite.swift
//  Relay
//
//  把 Windsurf LS 出口请求 protobuf body 里的 metadata.api_key 字段
//  （外层 field 1 → 内层 field 3, wire-type 2）原地替换为池子挑出的新 token。
//
//  关键事实：
//    - sessionToken 永远是 `devin-session-token$<JWT>`，固定 189 字节。
//    - 因此 delta == 0 → 不需要重算任何 length，纯 memcpy。
//    - 体内字段顺序 / 后续字段一字节不动。
import Foundation
import Core

public enum ProtoRewriteError: Error, CustomStringConvertible, Equatable {
    /// body 为空或第一个字节不是 0x0a（外层 field 1 wire-type 2）。上层应当透传。
    case notMetadataFirst
    /// varint 截断。
    case truncatedVarint(offset: Int)
    /// 内层 message 声明的长度超出 body 实际长度。
    case truncatedInner(claimed: Int, actual: Int)
    /// 字段值截断。
    case truncatedField(field: UInt32, offset: Int)
    /// metadata 不含 field 3 (api_key)。某些初始化期 RPC 可能这样，应当透传。
    case noApiKeyField
    /// 新 token 长度跟 protobuf 里的 string 长度不匹配。生产里恒 189 字节。
    case tokenLengthMismatch(expected: Int, got: Int)
    /// 未知 wire type（protobuf 规范只有 0/1/2/5）。
    case unknownWireType(UInt32, offset: Int)

    public var description: String {
        switch self {
        case .notMetadataFirst:
            return "body does not start with metadata field (expected 0x0a)"
        case .truncatedVarint(let off):
            return "truncated varint at offset \(off)"
        case .truncatedInner(let claimed, let actual):
            return "inner message extends past body (claimed end \(claimed), body len \(actual))"
        case .truncatedField(let f, let off):
            return "truncated field \(f) value at offset \(off)"
        case .noApiKeyField:
            return "api_key field (3) not found in metadata"
        case .tokenLengthMismatch(let exp, let got):
            return "token length mismatch: protobuf field is \(exp) bytes, new_token is \(got) bytes"
        case .unknownWireType(let wt, let off):
            return "unknown wire type \(wt) at offset \(off)"
        }
    }
}

public enum ProtoRewrite {
    /// 在 `body` 内原地把 `metadata.api_key`（外层 field 1 → 内层 field 3）
    /// 替换为 `newToken`。失败时 `body` 不被修改。
    /// `newToken` 长度必须等于现有 api_key 字段长度（生产恒 189）。
    public static func rewriteApiKey(_ body: inout [UInt8], newToken: [UInt8]) throws {
        let (valOff, valLen) = try locateApiKey(body)
        if valLen != newToken.count {
            throw ProtoRewriteError.tokenLengthMismatch(expected: valLen, got: newToken.count)
        }
        body.replaceSubrange(valOff..<(valOff + valLen), with: newToken)
    }

    /// 仅定位 metadata.api_key 字段在 body 内的字节区间，不修改。
    /// 单元测试 + 上层"先看再改"流程都用得上。
    public static func locateApiKey(_ body: [UInt8]) throws -> (offset: Int, length: Int) {
        guard let first = body.first, first == 0x0a else {
            throw ProtoRewriteError.notMetadataFirst
        }

        // 跳过外层 tag (0x0a)，读外层长度
        var cursor = 1
        let bodyData = Data(body)
        let (outerLen, n) = try decodeVarintLocal(bodyData, offset: cursor)
        cursor += n

        let innerEnd = cursor + Int(outerLen)
        if innerEnd > body.count {
            throw ProtoRewriteError.truncatedInner(claimed: innerEnd, actual: body.count)
        }

        // 走 inner，找 tag == 0x1a (field 3, wire-type 2)
        while cursor < innerEnd {
            let tagOff = cursor
            let (tag, tn) = try decodeVarintLocal(bodyData, offset: cursor)
            cursor += tn

            let field = UInt32(tag >> 3)
            let wireType = UInt32(tag & 0x7)

            switch wireType {
            case 0:
                // varint：读完 skip
                let (_, vn) = try decodeVarintLocal(bodyData, offset: cursor)
                cursor += vn
            case 2:
                // length-delimited：可能就是要找的 api_key
                let (len, ln) = try decodeVarintLocal(bodyData, offset: cursor)
                cursor += ln
                let lenInt = Int(len)
                if cursor + lenInt > innerEnd {
                    throw ProtoRewriteError.truncatedField(field: field, offset: tagOff)
                }
                if field == 3 {
                    return (cursor, lenInt)
                }
                cursor += lenInt
            case 1:
                // fixed64：跳过
                if cursor + 8 > innerEnd {
                    throw ProtoRewriteError.truncatedField(field: field, offset: tagOff)
                }
                cursor += 8
            case 5:
                // fixed32：跳过
                if cursor + 4 > innerEnd {
                    throw ProtoRewriteError.truncatedField(field: field, offset: tagOff)
                }
                cursor += 4
            default:
                throw ProtoRewriteError.unknownWireType(wireType, offset: tagOff)
            }
        }

        throw ProtoRewriteError.noApiKeyField
    }

    /// 内部 varint 解码——把 ProtoWireError.truncatedVarint 翻译成本模块的错误，
    /// 保持返回签名稳定。
    private static func decodeVarintLocal(_ buf: Data, offset: Int) throws -> (UInt64, Int) {
        do {
            return try ProtoWire.decodeVarint(buf, offset: offset)
        } catch ProtoWireError.truncatedVarint(let off) {
            throw ProtoRewriteError.truncatedVarint(offset: off)
        } catch {
            throw error
        }
    }
}
