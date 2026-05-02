//
//  ConnectErrorTests.swift
//  RelayTests
//
//  直译 src-tauri/src/relay/connect_error.rs::tests。
//

import XCTest
import NIOHTTP1
@testable import Relay

final class ConnectErrorTests: XCTestCase {

    // MARK: parseResetIn

    func testResetInMinutesSeconds() {
        XCTAssertEqual(ConnectError.parseResetIn("Resets in: 10m35s"), TimeInterval(10 * 60 + 35))
    }

    func testResetInWithHoursAndTrace() {
        XCTAssertEqual(
            ConnectError.parseResetIn("Resets in: 2h59m58s (trace ID: abc)"),
            TimeInterval(2 * 3600 + 59 * 60 + 58)
        )
    }

    func testResetInSecondsOnly() {
        XCTAssertEqual(ConnectError.parseResetIn("Resets in: 60s"), 60)
    }

    func testResetInNoColonLowercase() {
        XCTAssertEqual(ConnectError.parseResetIn("resets in 3h"), TimeInterval(3 * 3600))
    }

    func testResetInFullUserMessage() {
        let msg = "Permission denied: Reached message rate limit for this model. " +
                  "Please try again later. Resets in: 10m35s (trace ID: 0f35214a)"
        XCTAssertEqual(ConnectError.parseResetIn(msg), TimeInterval(10 * 60 + 35))
    }

    func testResetInNoneWhenAbsent() {
        XCTAssertNil(ConnectError.parseResetIn("Some error without time hint"))
        XCTAssertNil(ConnectError.parseResetIn(""))
    }

    // MARK: isRateLimit

    func testRateLimitPositive() {
        XCTAssertTrue(ConnectError.isRateLimit("Permission denied: Reached message rate limit"))
        XCTAssertTrue(ConnectError.isRateLimit("rate_limit_exceeded"))
        XCTAssertTrue(ConnectError.isRateLimit("Too many requests"))
        XCTAssertTrue(ConnectError.isRateLimit("Quota exhausted"))
        XCTAssertTrue(ConnectError.isRateLimit("RESOURCE_EXHAUSTED"))
        XCTAssertTrue(ConnectError.isRateLimit("permission denied"))
    }

    func testRateLimitNegative() {
        XCTAssertFalse(ConnectError.isRateLimit("Some unrelated error"))
        XCTAssertFalse(ConnectError.isRateLimit(""))
        XCTAssertFalse(ConnectError.isRateLimit("internal server error"))
    }

    // MARK: parseJsonError

    func testJsonErrorNestedWithCode() {
        let body: [UInt8] = Array(#"{"error":{"code":"permission_denied","message":"Reached message rate limit. Resets in: 5m"}}"#.utf8)
        let err = ConnectError.parseJsonError(body)
        XCTAssertNotNil(err)
        XCTAssertEqual(err?.message, "Reached message rate limit. Resets in: 5m")
        XCTAssertEqual(err?.code, "permission_denied")
        XCTAssertEqual(err?.resetIn, 5 * 60)
    }

    func testJsonErrorFlatForm() {
        let body: [UInt8] = Array(#"{"code":"resource_exhausted","message":"quota exhausted"}"#.utf8)
        let err = ConnectError.parseJsonError(body)
        XCTAssertEqual(err?.code, "resource_exhausted")
        XCTAssertEqual(err?.message, "quota exhausted")
    }

    func testJsonErrorNoMessageReturnsNone() {
        let body: [UInt8] = Array(#"{"foo":"bar"}"#.utf8)
        XCTAssertNil(ConnectError.parseJsonError(body))
    }

    // MARK: scanConnectFrames

    func testConnectEndStreamWithError() {
        let json: [UInt8] = Array(#"{"error":{"code":"permission_denied","message":"Reached message rate limit. Resets in: 1m"}}"#.utf8)
        var body: [UInt8] = [0x02]
        let lenBE = UInt32(json.count).bigEndian
        withUnsafeBytes(of: lenBE) { body.append(contentsOf: $0) }
        body.append(contentsOf: json)
        let err = ConnectError.scanConnectFrames(body)
        XCTAssertEqual(err?.code, "permission_denied")
        XCTAssertEqual(err?.resetIn, 60)
    }

    func testConnectDataFrameThenEmptyEndStreamNoError() {
        var body: [UInt8] = [0x00]
        var len = UInt32(3).bigEndian
        withUnsafeBytes(of: &len) { body.append(contentsOf: $0) }
        body.append(contentsOf: [0x61, 0x62, 0x63]) // "abc"
        body.append(0x02)
        var len2 = UInt32(2).bigEndian
        withUnsafeBytes(of: &len2) { body.append(contentsOf: $0) }
        body.append(contentsOf: [0x7b, 0x7d]) // "{}"
        XCTAssertNil(ConnectError.scanConnectFrames(body))
    }

    func testConnectOversizedLengthDoesNotPanic() {
        var body: [UInt8] = [0x02]
        var maxLen = UInt32.max.bigEndian
        withUnsafeBytes(of: &maxLen) { body.append(contentsOf: $0) }
        body.append(contentsOf: [0x6a, 0x75, 0x6e, 0x6b]) // "junk"
        XCTAssertNil(ConnectError.scanConnectFrames(body))
    }

    // MARK: detect

    func testDetectViaGrpcStatusHeader() {
        var headers = HTTPHeaders()
        headers.add(name: "grpc-status", value: "7")
        headers.add(name: "grpc-message", value: "Permission%20denied%3A%20Reached%20message%20rate%20limit.%20Resets%20in%3A%2010m")
        let err = ConnectError.detect(headers: headers, body: [], contentType: "application/grpc")
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.message.contains("Reached message rate limit") ?? false)
        XCTAssertEqual(err?.code, "grpc:7")
        XCTAssertEqual(err?.resetIn, TimeInterval(10 * 60))
    }

    func testDetectViaConnectBody() {
        let json: [UInt8] = Array(#"{"error":{"code":"permission_denied","message":"Reached message rate limit. Resets in: 30s"}}"#.utf8)
        var body: [UInt8] = [0x02]
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { body.append(contentsOf: $0) }
        body.append(contentsOf: json)
        let err = ConnectError.detect(headers: HTTPHeaders(), body: body, contentType: "application/connect+proto")
        XCTAssertEqual(err?.resetIn, 30)
    }

    func testDetectViaUnaryJson() {
        let body: [UInt8] = Array(#"{"error":{"code":"permission_denied","message":"Reached message rate limit. Resets in: 5s"}}"#.utf8)
        let err = ConnectError.detect(headers: HTTPHeaders(), body: body, contentType: "application/json")
        XCTAssertEqual(err?.resetIn, 5)
    }

    func testDetectGrpcStatusZeroIsOk() {
        var headers = HTTPHeaders()
        headers.add(name: "grpc-status", value: "0")
        XCTAssertNil(ConnectError.detect(headers: headers, body: [], contentType: "application/grpc"))
    }

    func testDetectNormalProtoResponseReturnsNone() {
        let body: [UInt8] = [0x0a, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f] // proto field 1: "hello"
        XCTAssertNil(ConnectError.detect(headers: HTTPHeaders(), body: body, contentType: "application/proto"))
    }

    // MARK: percentDecode

    func testPercentDecodeBasic() {
        let s = ConnectError.percentDecode("Hello%20World%21")
        XCTAssertEqual(s, "Hello World!")
    }
}
