//
//  ProtoRewriteTests.swift
//  RelayTests
//
//  ProtoRewrite 的 protobuf body 改写回归测试。
//

import XCTest
import Core
@testable import Relay

final class ProtoRewriteTests: XCTestCase {

    // MARK: helpers

    /// 构造贴近 HANDOFF.md §4.2 的真实 metadata：外层 field 1 包内层 message，
    /// 里面 field 1=client_name, 2=client_version, 3=api_key, 4=locale, 5=os,
    /// 6=ide_version, 8=arch, 9=timestamp, 10=request_uuid, 12=app marker。
    /// 返回 (full_body, api_key_offset_in_body)。
    private func buildRealWorldBody(apiKey: String) -> (body: [UInt8], apiKeyOffset: Int) {
        var inner = Data()
        ProtoWire.writeStringField(1, "windsurf", into: &inner)
        ProtoWire.writeStringField(2, "2.0.67", into: &inner)
        let apiKeyFieldStart = inner.count
        ProtoWire.writeStringField(3, apiKey, into: &inner)
        ProtoWire.writeStringField(4, "en", into: &inner)
        ProtoWire.writeStringField(5, "linux", into: &inner)
        ProtoWire.writeStringField(6, "2.0.67", into: &inner)
        ProtoWire.writeStringField(8, "x86_64", into: &inner)
        ProtoWire.writeVarintField(9, 1714530000, into: &inner)
        ProtoWire.writeStringField(10, "1d84f5ae-be6f-4b44-aaaa-123456789012", into: &inner)
        ProtoWire.writeStringField(12, "windsurf", into: &inner)

        var body = Data()
        body.append(0x0a)
        ProtoWire.encodeVarint(UInt64(inner.count), into: &body)
        let innerOffset = body.count

        let apiKeyValueOffInInner = apiKeyFieldStart + 1 // skip 0x1a
            + varintSize(UInt64(apiKey.utf8.count)) // skip length varint
        let apiKeyValueOffInBody = innerOffset + apiKeyValueOffInInner

        body.append(inner)
        return (Array(body), apiKeyValueOffInBody)
    }

    private func varintSize(_ v: UInt64) -> Int {
        var x = v
        var n = 0
        repeat {
            n += 1
            x >>= 7
        } while x > 0
        return n
    }

    /// 标准 189 字节 sessionToken 样本（HANDOFF.md §4.2 的实际长度）。
    private func token189(_ suffix: Character) -> String {
        var s = "devin-session-token$"
        s.append(String(repeating: "A", count: 189 - s.count - 1))
        s.append(suffix)
        precondition(s.count == 189)
        return s
    }

    // MARK: tests

    func testRewriteRealWorldBodyProducesByteCorrectSwap() throws {
        let original = token189("X")
        let (bodyArr, keyOff) = buildRealWorldBody(apiKey: original)
        var body = bodyArr
        XCTAssertEqual(body[0], 0x0a)
        XCTAssertGreaterThan(body.count, 200)

        let newToken = token189("Y")
        try ProtoRewrite.rewriteApiKey(&body, newToken: Array(newToken.utf8))

        // 关键字段被改
        XCTAssertEqual(Array(body[keyOff..<(keyOff + 189)]), Array(newToken.utf8))

        // 字段前后字节不动
        XCTAssertEqual(body[0], 0x0a)
        XCTAssertTrue(containsSubsequence(body, [UInt8]("windsurf".utf8)))
        XCTAssertTrue(containsSubsequence(body, [UInt8]("2.0.67".utf8)))
        XCTAssertTrue(containsSubsequence(body, [UInt8]("en".utf8)))
        XCTAssertTrue(containsSubsequence(body, [UInt8]("linux".utf8)))
    }

    func testLocateFindsCorrectOffsetAndLength() throws {
        let original = token189("Z")
        let (body, keyOff) = buildRealWorldBody(apiKey: original)
        let (off, len) = try ProtoRewrite.locateApiKey(body)
        XCTAssertEqual(off, keyOff)
        XCTAssertEqual(len, 189)
    }

    func testHandoffOuterLengthVarintIsTwoBytes() {
        // HANDOFF.md §4.2: 真实样本是 0a a5 02（外层 length=293, 多字节 varint）。
        let original = token189("Q")
        let (body, _) = buildRealWorldBody(apiKey: original)
        XCTAssertEqual(body[0], 0x0a)
        XCTAssertNotEqual(body[1] & 0x80, 0, "outer length should be multi-byte varint")
    }

    func testEmptyBodyReturnsNotMetadataFirst() {
        var body: [UInt8] = []
        XCTAssertThrowsError(try ProtoRewrite.rewriteApiKey(&body, newToken: [UInt8]("x".utf8))) { e in
            XCTAssertEqual(e as? ProtoRewriteError, .notMetadataFirst)
        }
    }

    func testPingStyleBodyReturnsNotMetadataFirst() {
        // 仅 field 2 string 的 body（不是 0x0a 开头）
        var buf = Data()
        ProtoWire.writeStringField(2, "ping", into: &buf)
        var body = Array(buf)
        XCTAssertThrowsError(try ProtoRewrite.rewriteApiKey(&body, newToken: [UInt8]("x".utf8))) { e in
            XCTAssertEqual(e as? ProtoRewriteError, .notMetadataFirst)
        }
    }

    func testMetadataWithoutField3ReturnsNoApiKey() {
        var inner = Data()
        ProtoWire.writeStringField(1, "windsurf", into: &inner)
        ProtoWire.writeStringField(2, "2.0.67", into: &inner)

        var body = Data()
        body.append(0x0a)
        ProtoWire.encodeVarint(UInt64(inner.count), into: &body)
        body.append(inner)

        var arr = Array(body)
        XCTAssertThrowsError(try ProtoRewrite.rewriteApiKey(&arr, newToken: [UInt8]("X".utf8))) { e in
            XCTAssertEqual(e as? ProtoRewriteError, .noApiKeyField)
        }
    }

    func testTokenLengthMismatchDoesNotModifyBody() {
        let original = token189("A")
        let (bodyArr, _) = buildRealWorldBody(apiKey: original)
        var body = bodyArr
        let snapshot = body

        let bad = "shorter"
        XCTAssertThrowsError(try ProtoRewrite.rewriteApiKey(&body, newToken: [UInt8](bad.utf8))) { e in
            guard case let .tokenLengthMismatch(expected, got) = e as? ProtoRewriteError ?? .notMetadataFirst else {
                XCTFail("expected tokenLengthMismatch, got \(e)")
                return
            }
            XCTAssertEqual(expected, 189)
            XCTAssertEqual(got, 7)
        }
        XCTAssertEqual(body, snapshot, "body must be untouched on length mismatch")
    }

    func testTruncatedInnerIsCaught() {
        // outer 声明 inner 长度 100，但 body 实际只剩 5 字节
        var body: [UInt8] = [0x0a, 100, 0, 0, 0, 0]
        XCTAssertThrowsError(try ProtoRewrite.rewriteApiKey(&body, newToken: [UInt8]("X".utf8))) { e in
            guard case .truncatedInner = e as? ProtoRewriteError else {
                XCTFail("expected truncatedInner, got \(e)")
                return
            }
        }
    }

    func testUnknownWireTypeInInnerErrors() {
        // 外层 field 1 包一个 inner，inner 第一个字节 tag wire-type 6 (无效)
        // tag = (1 << 3) | 6 = 0x0e
        let inner: [UInt8] = [0x0e]
        var body: [UInt8] = [0x0a, UInt8(inner.count)]
        body.append(contentsOf: inner)
        XCTAssertThrowsError(try ProtoRewrite.rewriteApiKey(&body, newToken: [UInt8]("X".utf8))) { e in
            guard case .unknownWireType(let wt, _) = e as? ProtoRewriteError else {
                XCTFail("expected unknownWireType, got \(e)")
                return
            }
            XCTAssertEqual(wt, 6)
        }
    }

    func testVarintFieldInInnerSkippedCorrectly() throws {
        // metadata 里 field 9 (timestamp varint) 排在 field 3 之前，
        // 验证我们正确跳过 varint，不会跑偏。
        var inner = Data()
        ProtoWire.writeVarintField(9, 1714530000, into: &inner) // 大 varint
        let original = token189("A")
        ProtoWire.writeStringField(3, original, into: &inner)

        var body = Data()
        body.append(0x0a)
        ProtoWire.encodeVarint(UInt64(inner.count), into: &body)
        let innerOff = body.count
        body.append(inner)
        var arr = Array(body)

        let new = token189("B")
        try ProtoRewrite.rewriteApiKey(&arr, newToken: [UInt8](new.utf8))

        // varint_field(9) 占用：tag(1B 0x48) + 5B varint = 6B
        // field 3：tag(1B 0x1a) + length varint(2B for 189) + 189B
        let field3ValueOff = innerOff + 6 + 1 + 2
        XCTAssertEqual(
            Array(arr[field3ValueOff..<(field3ValueOff + 189)]),
            Array(new.utf8)
        )
    }

    // MARK: helpers

    private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        for i in 0...(haystack.count - needle.count) {
            var match = true
            for j in 0..<needle.count {
                if haystack[i + j] != needle[j] {
                    match = false; break
                }
            }
            if match { return true }
        }
        return false
    }
}
