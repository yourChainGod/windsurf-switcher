//
//  GetOTTTests.swift
//  WindsurfClientTests
//
//  本地解析 / body 构造测试，不打真实网络。
//

import XCTest
@testable import WindsurfClient
@testable import Core

final class GetOTTTests: XCTestCase {

    func testBuildRequestBodyMatchesSamplePrefix() {
        // 旧 windsurf.rs::tests::ott_body_matches_sample_prefix
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzZXNzaW9uX2lkIjoid2luZHN1cmYtc2Vzc2lvbi1jYWRjZDVlZmVkNGE0MThmYTQyNjIyNWQ5Y2MxNmU5YiJ9.OLNgeJwjDUVHLd1t_M8I2vKGBwSFaxRhSOS8zqcU_iU"
        let body = GetOTTClient.buildRequestBody(token: jwt)
        // 0a bd 01 = field 1, length 189
        XCTAssertEqual(body[0], 0x0a)
        XCTAssertEqual(body[1], 0xbd)
        XCTAssertEqual(body[2], 0x01)
        XCTAssertEqual(body.count, 192)
        // 内容前缀 "devin-session-token$"
        let prefix = Data("devin-session-token".utf8)
        XCTAssertEqual(body.subdata(in: 3..<(3 + prefix.count)), prefix)
        XCTAssertEqual(body[3 + prefix.count], UInt8(ascii: "$"))
    }

    func testBuildRequestBodyAvoidsDoublePrefix() {
        // 已带 cookie value 前缀的 token 不应造成 "devin-session-token$devin-session-token$..."
        let raw = "abc.def.ghi"
        let withPrefix = "devin-session-token$\(raw)"
        let bodyA = GetOTTClient.buildRequestBody(token: raw)
        let bodyB = GetOTTClient.buildRequestBody(token: withPrefix)
        XCTAssertEqual(bodyA, bodyB)
    }

    func testParseRealWorldPayload() throws {
        let sample = "/ott$jom8gQQ2vtcPhuhPRanBcCHuv-OTtiZWh5zZwoVPRpE"
        var buf = Data()
        ProtoWire.writeStringField(1, sample, into: &buf)
        let parsed = try GetOTTClient.parseResponse(buf)
        XCTAssertEqual(parsed, sample)
    }

    func testParseTrimsTrailingNewline() throws {
        var buf = Data()
        ProtoWire.writeStringField(1, "/ott$abcDEF123\n", into: &buf)
        let parsed = try GetOTTClient.parseResponse(buf)
        XCTAssertEqual(parsed, "/ott$abcDEF123")
    }

    func testParseStripsGRPCWebFramePrefix() throws {
        // 假设响应前面有 5 字节 grpc-web frame header
        var buf = Data([0x00, 0x00, 0x00, 0x00, 0x31])
        var inner = Data()
        ProtoWire.writeStringField(1, "/ott$xyz123", into: &inner)
        buf.append(inner)
        let parsed = try GetOTTClient.parseResponse(buf)
        XCTAssertEqual(parsed, "/ott$xyz123")
    }

    func testParseEmptyOTTThrows() {
        var buf = Data()
        ProtoWire.writeStringField(1, "", into: &buf)
        XCTAssertThrowsError(try GetOTTClient.parseResponse(buf)) { err in
            guard case GetOTTError.ottEmpty = err else {
                return XCTFail("expected ottEmpty, got \(err)")
            }
        }
    }
}
