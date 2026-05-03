//
//  JWTRewriteTests.swift
//  RelayTests
//
//  直译 src-tauri/src/relay/jwt_rewrite.rs::tests。
//

import XCTest
import Core
@testable import Relay

final class JWTRewriteTests: XCTestCase {

    private func makeJwt(_ payloadJson: String) -> String {
        let header = JWTRewrite.base64UrlEncode(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = JWTRewrite.base64UrlEncode(Data(payloadJson.utf8))
        let sig = JWTRewrite.base64UrlEncode(Data("fakesig".utf8))
        return "\(header).\(payload).\(sig)"
    }

    private func wrapInProtoField1(_ jwt: String) -> Data {
        var out = Data()
        ProtoWire.writeStringField(1, jwt, into: &out)
        return out
    }

    private func extractJwtFromProto(_ body: Data) throws -> String {
        let fields = try ProtoWire.parseFields(body)
        guard let s = ProtoWire.firstString(fields, 1) else {
            XCTFail("no field 1")
            return ""
        }
        return s
    }

    private func parsePayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let bytes = JWTRewrite.base64UrlDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    func testRewriteChangesExpOnly() throws {
        let original = makeJwt(#"{"email":"a@b.c","exp":1777719036,"name":"x"}"#)
        let body = wrapInProtoField1(original)
        let newBody = try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 1234567890)
        let newJwt = try extractJwtFromProto(newBody)

        let origParts = original.split(separator: ".")
        let newParts = newJwt.split(separator: ".")
        XCTAssertEqual(origParts.count, 3)
        XCTAssertEqual(newParts.count, 3)
        XCTAssertEqual(origParts[0], newParts[0], "header unchanged")
        XCTAssertEqual(origParts[2], newParts[2], "signature unchanged")

        guard let p = parsePayload(newJwt) else { XCTFail(); return }
        XCTAssertEqual(p["exp"] as? Int64 ?? Int64(p["exp"] as? Int ?? 0), 1234567890)
        XCTAssertEqual(p["email"] as? String, "a@b.c")
        XCTAssertEqual(p["name"] as? String, "x")
    }

    func testRewriteInsertsExpWhenMissing() throws {
        let original = makeJwt(#"{"email":"a@b.c"}"#)
        let body = wrapInProtoField1(original)
        let newBody = try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 999)
        let newJwt = try extractJwtFromProto(newBody)
        guard let p = parsePayload(newJwt) else { XCTFail(); return }
        let exp = (p["exp"] as? Int64) ?? Int64((p["exp"] as? Int) ?? 0)
        XCTAssertEqual(exp, 999)
    }

    func testRejectsBodyWithoutField1() {
        var body = Data()
        ProtoWire.writeVarintField(2, 42, into: &body)
        XCTAssertThrowsError(try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 1)) { e in
            guard case JWTRewriteError.noJwtField = e else {
                XCTFail("expected noJwtField, got \(e)")
                return
            }
        }
    }

    func testRejectsMalformedJwt() {
        let body = wrapInProtoField1("not.a.jwt.too.many.dots")
        XCTAssertThrowsError(try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 1)) { e in
            guard case JWTRewriteError.jwtFormat = e else {
                XCTFail("expected jwtFormat, got \(e)")
                return
            }
        }
    }

    func testRejectsNonJsonPayload() {
        let header = JWTRewrite.base64UrlEncode(Data("{}".utf8))
        let payload = JWTRewrite.base64UrlEncode(Data("not-json".utf8))
        let sig = JWTRewrite.base64UrlEncode(Data("x".utf8))
        let jwt = "\(header).\(payload).\(sig)"
        let body = wrapInProtoField1(jwt)
        XCTAssertThrowsError(try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 1)) { e in
            guard case JWTRewriteError.payloadJson = e else {
                XCTFail("expected payloadJson, got \(e)")
                return
            }
        }
    }

    func testRejectsNonObjectPayload() {
        let header = JWTRewrite.base64UrlEncode(Data("{}".utf8))
        let payload = JWTRewrite.base64UrlEncode(Data("[1,2,3]".utf8))
        let sig = JWTRewrite.base64UrlEncode(Data("x".utf8))
        let jwt = "\(header).\(payload).\(sig)"
        let body = wrapInProtoField1(jwt)
        XCTAssertThrowsError(try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 1)) { e in
            guard case JWTRewriteError.payloadNotObject = e else {
                XCTFail("expected payloadNotObject, got \(e)")
                return
            }
        }
    }

    func testRoundTripPreservesOtherFields() throws {
        let payload = #"{"email":"e","exp":111,"api_key":"k","pro":false,"team_ids":[],"team_config":"{\"x\":1}"}"#
        let original = makeJwt(payload)
        let body = wrapInProtoField1(original)
        let newBody = try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 222)
        let newJwt = try extractJwtFromProto(newBody)
        guard let p = parsePayload(newJwt) else { XCTFail(); return }
        XCTAssertEqual(p["email"] as? String, "e")
        XCTAssertEqual(((p["exp"] as? Int64) ?? Int64((p["exp"] as? Int) ?? 0)), 222)
        XCTAssertEqual(p["api_key"] as? String, "k")
        XCTAssertEqual(p["pro"] as? Bool, false)
        XCTAssertNotNil(p["team_ids"] as? [Any])
        XCTAssertEqual(p["team_config"] as? String, "{\"x\":1}")
    }

    func testHandlesRealWorldSize() throws {
        let bigPayload = #"{"email":"a@b","exp":1777719036,"api_key":"\#(String(repeating: "x", count: 1000))","pro":false}"#
        let jwt = makeJwt(bigPayload)
        let body = wrapInProtoField1(jwt)
        XCTAssertGreaterThan(body.count, 1000)
        let newBody = try JWTRewrite.rewriteJwtExp(body, newExpUnixSec: 9999)
        let newJwt = try extractJwtFromProto(newBody)
        guard let p = parsePayload(newJwt) else { XCTFail(); return }
        XCTAssertEqual(((p["exp"] as? Int64) ?? Int64((p["exp"] as? Int) ?? 0)), 9999)
    }

    // MARK: base64url helpers

    func testBase64UrlRoundTrip() {
        let raw = Data([0xff, 0x00, 0x01, 0x7e, 0x40, 0x3f])
        let encoded = JWTRewrite.base64UrlEncode(raw)
        XCTAssertFalse(encoded.contains("="), "padding stripped")
        XCTAssertFalse(encoded.contains("+"), "+ replaced with -")
        XCTAssertFalse(encoded.contains("/"), "/ replaced with _")
        let decoded = JWTRewrite.base64UrlDecode(encoded)
        XCTAssertEqual(decoded, raw)
    }
}
