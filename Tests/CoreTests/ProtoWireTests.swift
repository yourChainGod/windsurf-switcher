//
//  ProtoWireTests.swift
//  CoreTests
//
//  ProtoWire 基础编解码测试 + 真实抓包样本断言。
//

import XCTest
@testable import Core

final class ProtoWireTests: XCTestCase {

    // MARK: - varint

    func testVarintRoundtrip() throws {
        let cases: [UInt64] = [0, 1, 127, 128, 189, 16383, 16384, 1 << 32, UInt64.max]
        for v in cases {
            var buf = Data()
            ProtoWire.encodeVarint(v, into: &buf)
            let (decoded, n) = try ProtoWire.decodeVarint(buf, offset: 0)
            XCTAssertEqual(decoded, v, "value \(v)")
            XCTAssertEqual(n, buf.count, "byte count for \(v)")
        }
    }

    func testTruncatedVarintThrows() {
        // 仅写 0x80（continuation bit 已设）但后续无字节
        let buf = Data([0x80])
        XCTAssertThrowsError(try ProtoWire.decodeVarint(buf, offset: 0)) { err in
            guard case ProtoWireError.truncatedVarint = err else {
                return XCTFail("expected truncatedVarint, got \(err)")
            }
        }
    }

    // MARK: - string field

    func testStringFieldMatchesSample() {
        // 旧 proto.rs::tests::string_field_matches_sample —— 189 字节 payload → 0a bd 01 头
        var out = Data()
        let payload = String(repeating: "x", count: 189)
        ProtoWire.writeStringField(1, payload, into: &out)
        XCTAssertEqual(out[0], 0x0a)
        XCTAssertEqual(out[1], 0xbd)
        XCTAssertEqual(out[2], 0x01)
        XCTAssertEqual(out.count, 3 + 189)
    }

    func testRoundtripStringField() throws {
        var out = Data()
        ProtoWire.writeStringField(1, "hello", into: &out)
        ProtoWire.writeVarintField(2, 42, into: &out)
        let fields = try ProtoWire.parseFields(out)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(ProtoWire.firstString(fields, 1), "hello")
        XCTAssertEqual(ProtoWire.firstVarint(fields, 2), 42)
    }

    func testFirstBytesReturnsRawSlice() throws {
        var out = Data()
        ProtoWire.writeBytesField(3, Data([0xde, 0xad, 0xbe, 0xef]), into: &out)
        let fields = try ProtoWire.parseFields(out)
        XCTAssertEqual(ProtoWire.firstBytes(fields, 3), Data([0xde, 0xad, 0xbe, 0xef]))
    }

    // MARK: - real-world OTT sample

    func testParseRealWorldOTTPayload() throws {
        // 旧 windsurf.rs::tests::parse_real_world_ott_payload
        let sample = "/ott$jom8gQQ2vtcPhuhPRanBcCHuv-OTtiZWh5zZwoVPRpE"
        XCTAssertEqual(sample.count, 48)
        var buf = Data()
        ProtoWire.writeStringField(1, sample, into: &buf)
        XCTAssertEqual(buf[0], 0x0a)
        XCTAssertEqual(Int(buf[1]), sample.count)
        XCTAssertEqual(buf.count, 2 + sample.count)

        let fields = try ProtoWire.parseFields(buf)
        XCTAssertEqual(ProtoWire.firstString(fields, 1), sample)
    }

    // MARK: - unknown wire type

    func testUnknownWireTypeThrows() {
        // tag = (1 << 3) | 6 = 0x0e — wire-type 6 不存在
        let buf = Data([0x0e])
        XCTAssertThrowsError(try ProtoWire.parseFields(buf)) { err in
            guard case ProtoWireError.unknownWireType(let wt, _) = err else {
                return XCTFail("expected unknownWireType, got \(err)")
            }
            XCTAssertEqual(wt, 6)
        }
    }

    // MARK: - truncated len-delim

    func testTruncatedLenDelimThrows() {
        // outer 声明 100 字节但 body 只剩 4
        let buf = Data([0x0a, 100, 0, 0, 0, 0])
        XCTAssertThrowsError(try ProtoWire.parseFields(buf)) { err in
            guard case ProtoWireError.truncatedLenDelim = err else {
                return XCTFail("expected truncatedLenDelim, got \(err)")
            }
        }
    }
}
