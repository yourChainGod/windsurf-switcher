//
//  ConnectError.swift
//  Relay
//
//  Connect-RPC / gRPC 应用层错误检测 + "Resets in" 解析。
//  Connect-RPC 错误帧识别。
//
//  背景：上游 cascade RPC 经常用 HTTP 200 + body 内 Connect 错误帧 来报错
//  （rate-limit、permission denied 等）。原 server 只看 HTTP status，
//  这种"伪成功"响应被当成 OK 透传给 LS，号被烧光也不换。
//
//  本模块识别这些应用层错误，让 server 触发 record_failure + 换号重试。
//
//  覆盖三种承载：
//    1. HTTP 头 grpc-status != 0
//    2. body Connect end-stream 帧（flags & 0x02）含 JSON {"error":{...}}
//    3. unary JSON error envelope
//

import Foundation
import NIOHTTP1
import zlib

/// 上游应用层错误描述。
public struct AppError: Equatable, Sendable {
    /// 用户可读的错误文本。
    public let message: String
    /// 错误码（"grpc:7" / "permission_denied" / "resource_exhausted" / ...）
    public let code: String?
    /// 从 message 里 parse 出的 "Resets in: ..."；命中可作精确 cooldown。
    public let resetIn: TimeInterval?

    public init(message: String, code: String? = nil, resetIn: TimeInterval? = nil) {
        self.message = message
        self.code = code
        self.resetIn = resetIn
    }
}

public enum ConnectError {
    private static let maxFrameSize = 16 * 1024 * 1024
    private static let maxDecodedEndStreamSize = 1024 * 1024

    /// 检测响应里的应用层错误。
    /// 返回 nil 表示正常；非 nil 表示有错。
    /// `contentType` 来自响应头 content-type。
    public static func detect(headers: HTTPHeaders, body: [UInt8], contentType: String) -> AppError? {
        // (1) gRPC trailer-style 头（status 非 0）
        if let status = headers.first(name: "grpc-status"), status != "0" {
            let rawMsg = headers.first(name: "grpc-message") ?? ""
            let message: String
            if rawMsg.isEmpty {
                message = "gRPC status \(status)"
            } else {
                message = percentDecode(rawMsg)
            }
            return AppError(
                message: message,
                code: "grpc:\(status)",
                resetIn: parseResetIn(message)
            )
        }

        // (2) Connect-RPC streaming end-stream 帧（cascade 主路径）
        if contentType.contains("connect") || contentType.contains("grpc") {
            if let err = scanConnectFrames(body) {
                return err
            }
        }

        // (3) JSON error envelope（HTTP 200 + json content-type）
        if contentType.contains("json") {
            if let err = parseJsonError(body) {
                return err
            }
        }

        return nil
    }

    /// 是否为 rate-limit 类错误（触发换号 + 重试）。
    public static func isRateLimit(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("rate limit")
            || lower.contains("rate_limit")
            || lower.contains("too many requests")
            || lower.contains("quota")
            || lower.contains("reached message")
            || lower.contains("permission denied")
            || lower.contains("resource_exhausted")
            || lower.contains("resource exhausted")
    }

    /// "Resets in: 2h59m58s" / "resets in 60s" / "Resets in: 10m35s (trace ID: ...)" → 秒。
    public static func parseResetIn(_ text: String) -> TimeInterval? {
        let lower = text.lowercased()
        guard let idx = lower.range(of: "resets in") else { return nil }
        var rest = lower[idx.upperBound...]
        // 跳前导 ":" / 空白
        while let first = rest.first, first == ":" || first.isWhitespace {
            rest = rest.dropFirst()
        }

        var totalSecs: UInt64 = 0
        var currentNum: UInt64? = nil
        var gotUnit = false

        for c in rest {
            if let d = c.asciiDecimal {
                currentNum = (currentNum ?? 0) * 10 + d
            } else if let n = currentNum {
                switch c {
                case "h":
                    totalSecs &+= n &* 3600
                    currentNum = nil
                    gotUnit = true
                case "m":
                    totalSecs &+= n &* 60
                    currentNum = nil
                    gotUnit = true
                case "s":
                    totalSecs &+= n
                    currentNum = nil
                    gotUnit = true
                case " ", ",":
                    continue // 保留 currentNum 给下一个单位
                default:
                    break // (trace ID...) 等结束符
                }
                if !gotUnit && currentNum == nil { break }
            } else if !c.isWhitespace {
                break
            }
        }

        if gotUnit && totalSecs > 0 {
            return TimeInterval(totalSecs)
        }
        return nil
    }

    // MARK: - 内部

    /// 扫 body 里的 Connect-RPC 帧，找 end-stream 帧（flags & 0x02）里的 error。
    /// 帧格式: [1B flags][4B BE length][N bytes payload]
    static func scanConnectFrames(_ body: [UInt8]) -> AppError? {
        var offset = 0
        while offset + 5 <= body.count {
            let flags = body[offset]
            let len =
                (Int(body[offset + 1]) << 24) |
                (Int(body[offset + 2]) << 16) |
                (Int(body[offset + 3]) << 8) |
                Int(body[offset + 4])
            if len > maxFrameSize {
                return nil
            }
            if offset + 5 + len > body.count {
                break
            }

            let payloadStart = offset + 5
            let payloadEnd = payloadStart + len

            if (flags & 0x02) != 0 {
                let payload = Array(body[payloadStart..<payloadEnd])
                let jsonBytes: [UInt8]
                if (flags & 0x01) != 0 {
                    // Connect compressed end-stream: Windsurf 上游实测用 gzip 包 JSON error。
                    guard let decoded = inflateGzipOrZlib(payload) else {
                        offset += 5 + len
                        continue
                    }
                    jsonBytes = decoded
                } else {
                    jsonBytes = payload
                }
                if let err = parseJsonError(jsonBytes) {
                    return err
                }
            }

            offset += 5 + len
        }
        return nil
    }

    /// 解析 JSON 错误：`{"error":{"code":"...","message":"..."}}` 或扁平 `{"code","message"}`
    static func parseJsonError(_ jsonBytes: [UInt8]) -> AppError? {
        guard let any = try? JSONSerialization.jsonObject(with: Data(jsonBytes), options: []) else {
            return nil
        }
        guard let obj = any as? [String: Any] else { return nil }
        let errNode: [String: Any]
        if let nested = obj["error"] as? [String: Any] {
            errNode = nested
        } else {
            errNode = obj
        }
        guard let message = errNode["message"] as? String else { return nil }
        let code = errNode["code"] as? String
        return AppError(
            message: message,
            code: code,
            resetIn: parseResetIn(message)
        )
    }

    /// 简易 percent-decoding（gRPC trailer message 是 url-encoded）。
    static func percentDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25 /* % */ && i + 2 < bytes.count {
                if let h = hexDigit(bytes[i + 1]), let l = hexDigit(bytes[i + 2]) {
                    out.append((h << 4) | l)
                    i += 3
                    continue
                }
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return nil
        }
    }

    private static func inflateGzipOrZlib(_ compressed: [UInt8]) -> [UInt8]? {
        inflate(compressed, windowBits: 16 + MAX_WBITS) ?? inflate(compressed, windowBits: MAX_WBITS)
    }

    private static func inflate(_ compressed: [UInt8], windowBits: Int32) -> [UInt8]? {
        if compressed.isEmpty { return [] }

        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        let chunkSize = 4096
        var status: Int32 = Z_OK

        return compressed.withUnsafeBufferPointer { input -> [UInt8]? in
            guard let inputBase = input.baseAddress else { return [] }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(compressed.count)

            while status == Z_OK {
                if output.count >= maxDecodedEndStreamSize {
                    return nil
                }

                let capacity = min(chunkSize, maxDecodedEndStreamSize - output.count)
                let start = output.count
                output.append(contentsOf: repeatElement(0, count: capacity))

                output.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress!.advanced(by: start)
                    stream.avail_out = uInt(capacity)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                }

                let produced = capacity - Int(stream.avail_out)
                if produced < capacity {
                    output.removeLast(capacity - produced)
                }

                if status == Z_STREAM_END {
                    return output
                }
                if status != Z_OK || (produced == 0 && stream.avail_in == 0) {
                    return nil
                }
            }

            return nil
        }
    }
}

private extension Character {
    /// '0'-'9' → 0..9；其它返回 nil。
    var asciiDecimal: UInt64? {
        guard let scalar = unicodeScalars.first?.value, (0x30...0x39).contains(scalar) else {
            return nil
        }
        return UInt64(scalar - 0x30)
    }
}
