//
//  ProtoWire.swift
//  Core
//
//  极简 protobuf wire-format 编解码。
//
//  仅实现本工具用到的字段类型：
//    - varint（wire type 0）
//    - length-delimited（wire type 2）：string / bytes / embedded message
//    - fixed64（wire type 1）/ fixed32（wire type 5）：仅 skip，不解析
//
//  不依赖 swift-protobuf / SwiftProtobuf；纯 Foundation。给 GetOTT / GetPlanStatus /
//  proto_rewrite / jwt_rewrite 这些手算 wire-format 的场景用。
//

import Foundation

public enum ProtoWireError: Error, CustomStringConvertible, Equatable {
    case varintOverflow
    case truncatedVarint(offset: Int)
    case truncatedLenDelim(field: UInt32, offset: Int)
    case truncatedFixed(width: Int, offset: Int)
    case unknownWireType(wireType: UInt32, offset: Int)
    case invalidUTF8

    public var description: String {
        switch self {
        case .varintOverflow:
            return "varint overflow (>64 bits)"
        case .truncatedVarint(let off):
            return "truncated varint at offset \(off)"
        case .truncatedLenDelim(let field, let off):
            return "truncated length-delimited field \(field) at offset \(off)"
        case .truncatedFixed(let width, let off):
            return "truncated fixed\(width * 8) at offset \(off)"
        case .unknownWireType(let wt, let off):
            return "unknown wire type \(wt) at offset \(off)"
        case .invalidUTF8:
            return "field bytes are not valid UTF-8"
        }
    }
}

/// 字段值。`bytes` slice 视图依赖外部 `Data`，调用方需保证生命周期。
public enum FieldValue: Equatable {
    case varint(UInt64)
    case lenDelim(Data)
    case fixed64(Data)
    case fixed32(Data)
}

public struct Field: Equatable {
    public let number: UInt32
    public let wireType: UInt32
    public let value: FieldValue

    public init(number: UInt32, wireType: UInt32, value: FieldValue) {
        self.number = number
        self.wireType = wireType
        self.value = value
    }
}

public enum ProtoWire {
    // MARK: - Encode

    /// 编码 varint（最大 64-bit）。
    public static func encodeVarint(_ value: UInt64, into out: inout Data) {
        var v = value
        while true {
            let byte = UInt8(v & 0x7f)
            v >>= 7
            if v == 0 {
                out.append(byte)
                return
            }
            out.append(byte | 0x80)
        }
    }

    /// 写入 tag = `(field << 3) | wireType`。
    public static func writeTag(field: UInt32, wireType: UInt32, into out: inout Data) {
        encodeVarint(UInt64((field << 3) | (wireType & 0x7)), into: &out)
    }

    /// 写一个 string 字段（wire type 2）。
    public static func writeStringField(_ field: UInt32, _ value: String, into out: inout Data) {
        let bytes = Data(value.utf8)
        writeTag(field: field, wireType: 2, into: &out)
        encodeVarint(UInt64(bytes.count), into: &out)
        out.append(bytes)
    }

    /// 写一个 bytes 字段（wire type 2）。
    public static func writeBytesField(_ field: UInt32, _ value: Data, into out: inout Data) {
        writeTag(field: field, wireType: 2, into: &out)
        encodeVarint(UInt64(value.count), into: &out)
        out.append(value)
    }

    /// 写一个 embedded message 字段（wire type 2）。
    public static func writeMessageField(_ field: UInt32, _ msg: Data, into out: inout Data) {
        writeTag(field: field, wireType: 2, into: &out)
        encodeVarint(UInt64(msg.count), into: &out)
        out.append(msg)
    }

    /// 写一个 varint 字段（wire type 0）。
    public static func writeVarintField(_ field: UInt32, _ value: UInt64, into out: inout Data) {
        writeTag(field: field, wireType: 0, into: &out)
        encodeVarint(value, into: &out)
    }

    // MARK: - Decode

    /// 解码 varint，返回 (值, 字节数)。
    public static func decodeVarint(_ buf: Data, offset: Int) throws -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt32 = 0
        var pos = offset
        let end = buf.endIndex
        // Data 的 startIndex 不一定是 0（slice 视图）；我们用绝对索引，要求调用方传入相对 startIndex 的 offset
        let base = buf.startIndex
        while base + pos < end {
            let byte = buf[base + pos]
            pos += 1
            result |= UInt64(byte & 0x7f) << shift
            if (byte & 0x80) == 0 {
                return (result, pos - offset)
            }
            shift += 7
            if shift >= 64 {
                throw ProtoWireError.varintOverflow
            }
        }
        throw ProtoWireError.truncatedVarint(offset: offset)
    }

    /// 把整个 buffer 拆成字段列表。
    public static func parseFields(_ buf: Data) throws -> [Field] {
        var fields: [Field] = []
        var pos = 0
        while pos < buf.count {
            let (tag, n) = try decodeVarint(buf, offset: pos)
            pos += n
            let fieldNum = UInt32(tag >> 3)
            let wireType = UInt32(tag & 0x7)

            let value: FieldValue
            switch wireType {
            case 0:
                let (v, vn) = try decodeVarint(buf, offset: pos)
                pos += vn
                value = .varint(v)
            case 2:
                let (len, ln) = try decodeVarint(buf, offset: pos)
                pos += ln
                let lenInt = Int(len)
                if pos + lenInt > buf.count {
                    throw ProtoWireError.truncatedLenDelim(field: fieldNum, offset: pos)
                }
                let slice = buf.subdata(in: (buf.startIndex + pos)..<(buf.startIndex + pos + lenInt))
                pos += lenInt
                value = .lenDelim(slice)
            case 1:
                if pos + 8 > buf.count {
                    throw ProtoWireError.truncatedFixed(width: 8, offset: pos)
                }
                let slice = buf.subdata(in: (buf.startIndex + pos)..<(buf.startIndex + pos + 8))
                pos += 8
                value = .fixed64(slice)
            case 5:
                if pos + 4 > buf.count {
                    throw ProtoWireError.truncatedFixed(width: 4, offset: pos)
                }
                let slice = buf.subdata(in: (buf.startIndex + pos)..<(buf.startIndex + pos + 4))
                pos += 4
                value = .fixed32(slice)
            default:
                throw ProtoWireError.unknownWireType(wireType: wireType, offset: pos)
            }

            fields.append(Field(number: fieldNum, wireType: wireType, value: value))
        }
        return fields
    }

    // MARK: - Field accessors

    /// 取出第一个匹配编号的 string 字段（UTF-8 解析失败返回 nil）。
    public static func firstString(_ fields: [Field], _ number: UInt32) -> String? {
        for f in fields where f.number == number {
            if case .lenDelim(let data) = f.value {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// 取出第一个匹配编号的 bytes 字段。
    public static func firstBytes(_ fields: [Field], _ number: UInt32) -> Data? {
        for f in fields where f.number == number {
            if case .lenDelim(let data) = f.value {
                return data
            }
        }
        return nil
    }

    /// 取出第一个匹配编号的 varint 字段。
    public static func firstVarint(_ fields: [Field], _ number: UInt32) -> UInt64? {
        for f in fields where f.number == number {
            if case .varint(let v) = f.value {
                return v
            }
        }
        return nil
    }
}
