//
//  DataMigration.swift
//  Core
//
//  迁移旧版工程的 accounts.json：
//    旧路径：~/Library/Application Support/com.windsurf.switcher/accounts.json
//    新路径：~/Library/Application Support/com.windsurfswitcher.native/accounts.json
//
//  旧 JSON schema：
//    - Account 层用 snake_case：session_token / added_at / last_switched_at / cooldown_until …
//    - JwtInfo 层用 camelCase（serde rename_all = "camelCase"）
//    - PlanStatus 层用 camelCase（同上）
//    - 时间戳一律 i64 unix 秒
//
//  新 schema：全 camelCase + Date（编解码用 secondsSince1970，与旧 i64 完全兼容）。
//
//  设计：迁移**不删旧文件**，仅复制 + 转换；旧版仍可读以便回滚。
//

import Foundation

/// 迁移结果摘要。
public struct MigrationResult: Equatable {
    public let importedCount: Int
    public let skippedCount: Int
    public let sourcePath: URL?
    public let destinationPath: URL?
    public let alreadyMigrated: Bool

    public static let none = MigrationResult(
        importedCount: 0, skippedCount: 0,
        sourcePath: nil, destinationPath: nil,
        alreadyMigrated: false
    )
}

public enum DataMigration {
    /// 检查是否存在旧数据可迁移（且新目录尚未有数据）。
    public static func needsMigration() -> Bool {
        guard let legacyDir = try? legacyDataDirectory() else { return false }
        let legacyFile = legacyDir.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: legacyFile.path) else { return false }

        guard let newDir = try? defaultDataDirectory() else { return false }
        let newFile = newDir.appendingPathComponent("accounts.json")
        // 新文件存在且非空 → 视为已迁移
        if let attrs = try? FileManager.default.attributesOfItem(atPath: newFile.path),
           let size = attrs[.size] as? Int, size > 4 {
            return false
        }
        return true
    }

    /// 一次性迁移：旧 → 新。`force=true` 时覆盖已有的新文件。
    @discardableResult
    public static func migrateLegacy(force: Bool = false) throws -> MigrationResult {
        let legacyDir = try legacyDataDirectory()
        let legacyFile = legacyDir.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: legacyFile.path) else {
            return .none
        }
        let newDir = try defaultDataDirectory()
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newFile = newDir.appendingPathComponent("accounts.json")

        if !force,
           let attrs = try? FileManager.default.attributesOfItem(atPath: newFile.path),
           let size = attrs[.size] as? Int, size > 4 {
            return MigrationResult(
                importedCount: 0, skippedCount: 0,
                sourcePath: legacyFile, destinationPath: newFile,
                alreadyMigrated: true
            )
        }

        let raw = try Data(contentsOf: legacyFile)
        let legacyStore = try Self.legacyDecoder().decode(LegacyStoreFile.self, from: raw)
        let converted = legacyStore.accounts.map { $0.toNewAccount() }

        let newStore = StoreFile(version: 1, accounts: converted)
        let out = try AccountStore.makeEncoder().encode(newStore)
        try out.write(to: newFile, options: [.atomic])

        return MigrationResult(
            importedCount: converted.count,
            skippedCount: 0,
            sourcePath: legacyFile,
            destinationPath: newFile,
            alreadyMigrated: false
        )
    }

    // MARK: - Codec helpers

    static func legacyDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        // 旧 Account 是 snake_case；JwtInfo / PlanStatus 内部已是 camelCase。
        // 我们用 LegacyAccount 显式 CodingKeys 处理 Account 字段；JwtInfo/PlanStatus 保持默认。
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

// MARK: - Legacy schema (snake_case Account + camelCase 内嵌)

struct LegacyStoreFile: Codable {
    var version: Int?
    var accounts: [LegacyAccount]
}

/// 旧版 Account 结构的完整映射。
struct LegacyAccount: Codable {
    var id: String                    // 旧版 UUID 字符串
    var label: String?
    var session_token: String
    var jwt_info: LegacyJWTInfo?
    var status: LegacyPlanStatus?     // 注意：旧字段名 "status"，新字段 planStatus
    var added_at: Int64
    var last_switched_at: Int64?
    var last_error: String?
    var cooldown_until: Int64?
    var consecutive_failures: UInt32?
    var last_used_by_relay: Int64?
    var internal_error_streak: UInt32?
    var ban_signal_count: UInt32?
    var ban_signal_first_at: Int64?
    var banned_until: Int64?

    func toNewAccount() -> Account {
        Account(
            id: UUID(uuidString: id) ?? UUID(),
            label: label ?? "",
            sessionToken: session_token,
            jwtInfo: jwt_info?.toNew(),
            planStatus: status?.toNew(),
            addedAt: Date(timeIntervalSince1970: TimeInterval(added_at)),
            lastSwitchedAt: last_switched_at.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastError: last_error,
            // 旧版没有 lastUsedApp，迁移后留空，等用户首次切号时打标
            lastUsedApp: nil,
            cooldownUntil: cooldown_until.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            consecutiveFailures: Int(consecutive_failures ?? 0),
            lastUsedByRelay: last_used_by_relay.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            internalErrorStreak: Int(internal_error_streak ?? 0),
            banSignalCount: Int(ban_signal_count ?? 0),
            banSignalFirstAt: ban_signal_first_at.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            bannedUntil: banned_until.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

/// 旧版 JwtInfo（camelCase）。
struct LegacyJWTInfo: Codable {
    var sessionId: String?
    var email: String?
    var userId: String?
    var expiresAt: Int64?
    var issuedAt: Int64?

    func toNew() -> JWTInfo {
        JWTInfo(
            sessionId: sessionId,
            email: email,
            userId: userId,
            expiresAt: expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            issuedAt: issuedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

/// 旧 windsurf.rs::PlanStatus（camelCase）。
struct LegacyPlanStatus: Codable {
    var planName: String?
    var planStart: Int64?
    var planEnd: Int64?

    var dailyPercent: UInt32?
    var weeklyPercent: UInt32?
    var dailyResetAt: Int64?
    var weeklyResetAt: Int64?

    var promptUsed: UInt64?
    var promptLimit: UInt64?
    var promptRemaining: UInt64?

    var flowUsed: UInt64?
    var flowLimit: UInt64?
    var flowRemaining: UInt64?

    var flexUsed: UInt64?
    var flexRemaining: UInt64?

    var fetchedAt: Int64?

    func toNew() -> PlanStatus {
        var ps = PlanStatus(
            fetchedAt: Date(timeIntervalSince1970: TimeInterval(fetchedAt ?? 0))
        )
        ps.planName = planName
        ps.planStart = planStart.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ps.planEnd = planEnd.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ps.dailyPercent = dailyPercent.map(Int.init)
        ps.weeklyPercent = weeklyPercent.map(Int.init)
        ps.dailyResetAt = dailyResetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ps.weeklyResetAt = weeklyResetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ps.promptUsed = promptUsed.map(Int.init)
        ps.promptLimit = promptLimit.map(Int.init)
        ps.promptRemaining = promptRemaining.map(Int.init)
        ps.flowUsed = flowUsed.map(Int.init)
        ps.flowLimit = flowLimit.map(Int.init)
        ps.flowRemaining = flowRemaining.map(Int.init)
        ps.flexUsed = flexUsed.map(Int.init)
        ps.flexRemaining = flexRemaining.map(Int.init)
        return ps
    }
}
