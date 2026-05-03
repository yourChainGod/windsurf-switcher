//
//  JWTDecodeTests.swift
//  WindsurfClientTests
//

import XCTest
@testable import WindsurfClient
@testable import Core

final class JWTDecodeTests: XCTestCase {

    /// 用 base64url 编码一段 JSON 当 payload；header / sig 任意填。
    private func makeJWT(payload: String) -> String {
        let header = JWTDecode.base64urlEncode(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let p = JWTDecode.base64urlEncode(Data(payload.utf8))
        let sig = JWTDecode.base64urlEncode(Data("fakesig".utf8))
        return "\(header).\(p).\(sig)"
    }

    func testDecodeWithCookiePrefix() {
        let jwt = makeJWT(payload: #"{"session_id":"sess-abc","email":"a@b.c","exp":1777719036,"iat":1777718136}"#)
        let token = "devin-session-token$\(jwt)"
        let info = JWTDecode.decode(token)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.email, "a@b.c")
        XCTAssertEqual(info?.sessionId, "sess-abc")
        XCTAssertEqual(info?.expiresAt?.timeIntervalSince1970, 1777719036)
    }

    func testDecodeBareJWT() {
        let jwt = makeJWT(payload: #"{"sub":"u-42","email":"x@y.z"}"#)
        let info = JWTDecode.decode(jwt)
        XCTAssertEqual(info?.email, "x@y.z")
        XCTAssertEqual(info?.userId, "u-42")
    }

    func testJWTOnlyStripsPrefix() {
        XCTAssertEqual(JWTDecode.jwtOnly("devin-session-token$abc.def.ghi"), "abc.def.ghi")
        XCTAssertEqual(JWTDecode.jwtOnly("abc.def.ghi"), "abc.def.ghi")
    }

    func testPrefixedAvoidsDoublePrefix() {
        XCTAssertEqual(JWTDecode.prefixed("abc.def.ghi"), "devin-session-token$abc.def.ghi")
        XCTAssertEqual(JWTDecode.prefixed("devin-session-token$abc.def.ghi"),
                       "devin-session-token$abc.def.ghi")
    }

    func testBase64URLNoPaddingRoundtrip() {
        let raw = Data("{\"hello\":1}".utf8)
        let encoded = JWTDecode.base64urlEncode(raw)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(JWTDecode.base64urlDecode(encoded), raw)
    }

    func testInvalidJWTReturnsNil() {
        XCTAssertNil(JWTDecode.decode("not-a-jwt"))
        XCTAssertNil(JWTDecode.decode("only.two"))
    }
}
