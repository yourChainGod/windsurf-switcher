//
//  DataMigrationTests.swift
//  CoreTests
//
//  直译旧 schema 的真实样本，验证 LegacyAccount → Account 转换无丢字段。
//

import XCTest
@testable import Core

final class DataMigrationTests: XCTestCase {

    /// 真实结构样本：Account 层 snake_case，jwt_info / status 层 camelCase。
    private let sampleJSON = """
    {
      "version": 1,
      "accounts": [
        {
          "id": "1d84f5ae-be6f-4b44-aaaa-123456789012",
          "label": "工作号",
          "session_token": "devin-session-token$eyJhbGciOiJIUzI1NiJ9.payload.sig",
          "jwt_info": {
            "sessionId": "windsurf-session-cadcd5efed4a418fa426225d9cc16e9b",
            "email": "alice@example.com",
            "userId": "u-123",
            "expiresAt": 1777719036,
            "issuedAt": 1777718136
          },
          "status": {
            "planName": "Pro",
            "planStart": 1700000000,
            "planEnd": 1800000000,
            "dailyPercent": 87,
            "weeklyPercent": 65,
            "dailyResetAt": 1777722000,
            "weeklyResetAt": 1778122000,
            "promptUsed": 1234,
            "promptLimit": 50000,
            "promptRemaining": 48766,
            "flowUsed": 50,
            "flowLimit": 1000,
            "flowRemaining": 950,
            "flexUsed": 0,
            "flexRemaining": 1000,
            "fetchedAt": 1700000500
          },
          "added_at": 1700000000,
          "last_switched_at": 1700001000,
          "last_error": null,
          "cooldown_until": null,
          "consecutive_failures": 0,
          "last_used_by_relay": 1700000999,
          "internal_error_streak": 0,
          "ban_signal_count": 0,
          "ban_signal_first_at": null,
          "banned_until": null
        }
      ]
    }
    """

    func testParseLegacySample() throws {
        let data = sampleJSON.data(using: .utf8)!
        let store = try DataMigration.legacyDecoder().decode(LegacyStoreFile.self, from: data)
        XCTAssertEqual(store.accounts.count, 1)

        let a = store.accounts[0].toNewAccount()
        XCTAssertEqual(a.id.uuidString.lowercased(), "1d84f5ae-be6f-4b44-aaaa-123456789012")
        XCTAssertEqual(a.label, "工作号")
        XCTAssertTrue(a.sessionToken.hasPrefix("devin-session-token$"))
        XCTAssertEqual(a.jwtInfo?.email, "alice@example.com")
        XCTAssertEqual(a.jwtInfo?.userId, "u-123")
        XCTAssertEqual(a.jwtInfo?.expiresAt?.timeIntervalSince1970, 1777719036)

        XCTAssertEqual(a.planStatus?.planName, "Pro")
        XCTAssertEqual(a.planStatus?.dailyPercent, 87)
        XCTAssertEqual(a.planStatus?.weeklyPercent, 65)
        XCTAssertEqual(a.planStatus?.promptUsed, 1234)
        XCTAssertEqual(a.planStatus?.flowRemaining, 950)
        XCTAssertEqual(a.planStatus?.fetchedAt.timeIntervalSince1970, 1700000500)

        XCTAssertEqual(a.addedAt.timeIntervalSince1970, 1700000000)
        XCTAssertEqual(a.lastSwitchedAt?.timeIntervalSince1970, 1700001000)
        XCTAssertEqual(a.lastUsedByRelay?.timeIntervalSince1970, 1700000999)
        XCTAssertNil(a.lastUsedApp, "旧版无此字段，迁移后应为 nil")
    }

    func testParseLegacyMinimumFields() throws {
        // 旧版账号最小化样本（只必填字段）
        let json = """
        {
          "version": 1,
          "accounts": [
            { "id": "00000000-0000-0000-0000-000000000001",
              "session_token": "x",
              "added_at": 1700000000 }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let store = try DataMigration.legacyDecoder().decode(LegacyStoreFile.self, from: data)
        let a = store.accounts[0].toNewAccount()
        XCTAssertEqual(a.label, "")
        XCTAssertEqual(a.consecutiveFailures, 0)
        XCTAssertNil(a.planStatus)
        XCTAssertNil(a.jwtInfo)
        XCTAssertNil(a.lastError)
    }
}
