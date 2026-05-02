//
//  Account.swift
//  Core
//
//  账号模型：1:1 对应旧 src-tauri/src/store.rs::Account，外加 `lastUsedApp` 双 app 标记。
//
//  字段命名：JSON 里写 camelCase（旧版是 snake_case，DataMigration 负责转换）。
//

import Foundation

/// 解码出的 JWT payload 元信息（不验签，仅展示）。
public struct JWTInfo: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var email: String?
    public var userId: String?
    public var expiresAt: Date?
    public var issuedAt: Date?

    public init(
        sessionId: String? = nil,
        email: String? = nil,
        userId: String? = nil,
        expiresAt: Date? = nil,
        issuedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.email = email
        self.userId = userId
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
    }
}

/// GetPlanStatus 解析结果。两套度量：百分比配额（cascade）+ 月度 credits。
public struct PlanStatus: Codable, Equatable, Sendable {
    public var planName: String?
    public var planStart: Date?
    public var planEnd: Date?

    public var dailyPercent: Int?
    public var weeklyPercent: Int?
    public var dailyResetAt: Date?
    public var weeklyResetAt: Date?

    public var promptUsed: Int?
    public var promptLimit: Int?
    public var promptRemaining: Int?

    public var flowUsed: Int?
    public var flowLimit: Int?
    public var flowRemaining: Int?

    public var flexUsed: Int?
    public var flexRemaining: Int?

    public var fetchedAt: Date

    public init(fetchedAt: Date = Date()) {
        self.fetchedAt = fetchedAt
    }
}

/// 单个账号。`sessionToken` 既可能是裸 JWT 也可能是 `devin-session-token$<JWT>` 完整 cookie 值。
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var sessionToken: String

    public var jwtInfo: JWTInfo?
    public var planStatus: PlanStatus?

    public var addedAt: Date
    public var lastSwitchedAt: Date?
    public var lastError: String?

    /// 双 app：上次切到哪个 app 用过这号。仅 UI / 记账，relay 不感知。
    public var lastUsedApp: WindsurfApp?

    // ─── Pool 调度状态（与旧 store.rs::Account 一一对应） ─────────────
    public var cooldownUntil: Date?
    public var consecutiveFailures: Int
    public var lastUsedByRelay: Date?
    public var internalErrorStreak: Int
    public var banSignalCount: Int
    public var banSignalFirstAt: Date?
    public var bannedUntil: Date?

    public init(
        id: UUID = UUID(),
        label: String = "",
        sessionToken: String,
        jwtInfo: JWTInfo? = nil,
        planStatus: PlanStatus? = nil,
        addedAt: Date = Date(),
        lastSwitchedAt: Date? = nil,
        lastError: String? = nil,
        lastUsedApp: WindsurfApp? = nil,
        cooldownUntil: Date? = nil,
        consecutiveFailures: Int = 0,
        lastUsedByRelay: Date? = nil,
        internalErrorStreak: Int = 0,
        banSignalCount: Int = 0,
        banSignalFirstAt: Date? = nil,
        bannedUntil: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.sessionToken = sessionToken
        self.jwtInfo = jwtInfo
        self.planStatus = planStatus
        self.addedAt = addedAt
        self.lastSwitchedAt = lastSwitchedAt
        self.lastError = lastError
        self.lastUsedApp = lastUsedApp
        self.cooldownUntil = cooldownUntil
        self.consecutiveFailures = consecutiveFailures
        self.lastUsedByRelay = lastUsedByRelay
        self.internalErrorStreak = internalErrorStreak
        self.banSignalCount = banSignalCount
        self.banSignalFirstAt = banSignalFirstAt
        self.bannedUntil = bannedUntil
    }

    /// 优先 label > email > session_id 前 12 位 > id 前 8 位。
    public var displayName: String {
        if !label.isEmpty { return label }
        if let email = jwtInfo?.email, !email.isEmpty { return email }
        if let sid = jwtInfo?.sessionId, !sid.isEmpty {
            return String(sid.prefix(12)) + (sid.count > 12 ? "…" : "")
        }
        return String(id.uuidString.prefix(8))
    }

    /// 用户付费 / 团队 plan 名（"Pro" / "Free" / "Enterprise"），空返回 nil。
    public var planName: String? { planStatus?.planName }

    /// 是否处于短期冷却中（auth/rate-limit/streak 触发）。
    public var isCoolingDown: Bool {
        guard let until = cooldownUntil else { return false }
        return until > Date()
    }

    /// 是否处于长期封禁中（ban_signal 升级触发）。
    public var isBanned: Bool {
        guard let until = bannedUntil else { return false }
        return until > Date()
    }
}
