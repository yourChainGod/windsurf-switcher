//
//  BanSignalTests.swift
//  RelayTests
//
//  BanSignal 中英正负例矩阵。
//

import XCTest
@testable import Relay

final class BanSignalTests: XCTestCase {

    func testEmptyBodyDoesNotMatch() {
        XCTAssertFalse(BanSignal.matches(""))
    }

    func testBenignErrorDoesNotMatch() {
        XCTAssertFalse(BanSignal.matches("Internal server error"))
        XCTAssertFalse(BanSignal.matches("rate limit exceeded; please retry"))
        XCTAssertFalse(BanSignal.matches("payment required"))
    }

    func testAccountSuspendedEnglish() {
        XCTAssertTrue(BanSignal.matches("Your account has been suspended due to abuse."))
        XCTAssertTrue(BanSignal.matches("Error: account_suspended"))
        XCTAssertTrue(BanSignal.matches("ACCOUNT-DISABLED by admin"))
    }

    func testUserBannedForm() {
        XCTAssertTrue(BanSignal.matches("User has been banned"))
        XCTAssertTrue(BanSignal.matches("user_banned"))
    }

    func testApiKeyRevoked() {
        XCTAssertTrue(BanSignal.matches("Your API key has been revoked"))
        XCTAssertTrue(BanSignal.matches("api-key-revoked"))
        XCTAssertTrue(BanSignal.matches("Invalid API key"))
    }

    func testSubscriptionTerminated() {
        XCTAssertTrue(BanSignal.matches("Your subscription has been cancelled"))
        XCTAssertTrue(BanSignal.matches("subscription expired, please renew"))
    }

    func testAuthenticationFailedPhrase() {
        XCTAssertTrue(BanSignal.matches("Authentication failed: token expired"))
    }

    func testChineseSignals() {
        XCTAssertTrue(BanSignal.matches("账号已停用"))
        XCTAssertTrue(BanSignal.matches("您的账号被封禁"))
        XCTAssertTrue(BanSignal.matches("用户已禁用"))
        XCTAssertTrue(BanSignal.matches("订阅已过期"))
    }

    func testExtractTextTruncates() {
        let body: [UInt8] = [0x68, 0x65, 0x6c, 0x6c, 0x6f, 0xff, 0x77, 0x6f, 0x72, 0x6c, 0x64] // "hello\xffworld"
        let s = BanSignal.extractText(body, maxBytes: 5)
        XCTAssertEqual(s, "hello")
    }
}
