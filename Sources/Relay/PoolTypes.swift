//
//  PoolTypes.swift
//  Relay
//
//  Pool 公开类型：直译 src-tauri/src/relay/pool.rs 的 PoolConfig / FailureKind /
//  PoolError / Lease / AccountUpdate / EntrySnapshot / HealthSummary。
//
//  时间戳约定：与旧 rust 一致用 i64 unix 秒（不是 Date）——
//    - 测试 deterministic 注入更简单
//    - cooldown / ban 比较直接整数比较，性能 / 等价性最稳
//

import Foundation

// MARK: - FailureKind

public enum FailureKind: String, Sendable, Equatable {
    case auth        // 401 / 403
    case rateLimit   // 429
    case transient   // 5xx / 网络错误

    /// HTTP status → FailureKind；返回 nil 表示不算失败。
    public static func fromStatus(_ status: Int) -> FailureKind? {
        switch status {
        case 401, 403: return .auth
        case 429: return .rateLimit
        case 500...599: return .transient
        default: return nil
        }
    }

    /// 默认冷却时长。Transient 单次不冷却（streak 触发才冷）。
    public func cooldown(_ cfg: PoolConfig) -> TimeInterval? {
        switch self {
        case .auth: return cfg.cooldownOnAuth
        case .rateLimit: return cfg.cooldownOnRateLimit
        case .transient: return nil
        }
    }
}

// MARK: - PoolError

public enum PoolError: Error, CustomStringConvertible, Equatable {
    case empty
    case allExcluded

    public var description: String {
        switch self {
        case .empty: return "pool is empty (no accounts loaded)"
        case .allExcluded: return "all accounts excluded (retried)"
        }
    }
}

// MARK: - PoolConfig

public struct PoolConfig: Sendable, Equatable {
    /// 同账号并发上限（默认 2，避免单号被打爆）
    public var perTokenConcurrency: Int

    /// auth 失败默认冷却（300s）
    public var cooldownOnAuth: TimeInterval
    /// rate-limit 默认 fallback 冷却（300s；优先用响应里 "Resets in: ..."）
    public var cooldownOnRateLimit: TimeInterval

    /// 连续 transient 累计达到此次数才冷却（避免单次抖动误伤）
    public var internalErrorStreakThreshold: Int
    /// 累计阈值后冷却时长
    public var cooldownOnInternalErrorStreak: TimeInterval

    /// ban_signal 累计窗口（30min）
    public var banSignalWindow: TimeInterval
    /// 窗口内累计阈值（默认 2 次升级到 banned）
    public var banSignalThreshold: Int
    /// 升级后封禁时长（默认 10 年）
    public var bannedLockout: TimeInterval

    public init(
        perTokenConcurrency: Int = 2,
        cooldownOnAuth: TimeInterval = 300,
        cooldownOnRateLimit: TimeInterval = 300,
        internalErrorStreakThreshold: Int = 2,
        cooldownOnInternalErrorStreak: TimeInterval = 300,
        banSignalWindow: TimeInterval = 30 * 60,
        banSignalThreshold: Int = 2,
        bannedLockout: TimeInterval = 10 * 365 * 24 * 3600
    ) {
        self.perTokenConcurrency = perTokenConcurrency
        self.cooldownOnAuth = cooldownOnAuth
        self.cooldownOnRateLimit = cooldownOnRateLimit
        self.internalErrorStreakThreshold = internalErrorStreakThreshold
        self.cooldownOnInternalErrorStreak = cooldownOnInternalErrorStreak
        self.banSignalWindow = banSignalWindow
        self.banSignalThreshold = banSignalThreshold
        self.bannedLockout = bannedLockout
    }

    public static let `default` = PoolConfig()
}

// MARK: - Lease

/// 调用方 lease 拿到的句柄。`Task { ... }` 内使用即可，离开作用域 deinit 自动释放并发槽。
///
/// **不要**把 Lease 实例跨 actor 传或长期持有。它是 RAII，应当紧贴单次请求生命周期。
public final class Lease {
    public let accountId: String
    public let token: String
    /// `email` 仅给日志 / stats 标记用，可空。
    public let email: String?
    private let release: LeaseReleaseHook

    init(accountId: String, token: String, email: String?, release: LeaseReleaseHook) {
        self.accountId = accountId
        self.token = token
        self.email = email
        self.release = release
    }

    deinit {
        release.fire()
    }
}

// MARK: - AccountUpdate

/// Pool 修改完账号状态后产出的差异，调用方负责落库。
public struct AccountUpdate: Sendable, Equatable {
    public let accountId: String
    public let cooldownUntil: Int64?
    public let consecutiveFailures: Int
    public let lastUsedByRelay: Int64?
    public let internalErrorStreak: Int
    public let banSignalCount: Int
    public let banSignalFirstAt: Int64?
    public let bannedUntil: Int64?

    public init(
        accountId: String,
        cooldownUntil: Int64? = nil,
        consecutiveFailures: Int = 0,
        lastUsedByRelay: Int64? = nil,
        internalErrorStreak: Int = 0,
        banSignalCount: Int = 0,
        banSignalFirstAt: Int64? = nil,
        bannedUntil: Int64? = nil
    ) {
        self.accountId = accountId
        self.cooldownUntil = cooldownUntil
        self.consecutiveFailures = consecutiveFailures
        self.lastUsedByRelay = lastUsedByRelay
        self.internalErrorStreak = internalErrorStreak
        self.banSignalCount = banSignalCount
        self.banSignalFirstAt = banSignalFirstAt
        self.bannedUntil = bannedUntil
    }
}

// MARK: - EntrySnapshot

/// `/__relay/health` 单条快照。
public struct EntrySnapshot: Sendable, Equatable {
    public let accountId: String
    public let email: String?
    public let tokenPrefix: String
    public let cooldownUntil: Int64?
    public let consecutiveFailures: Int
    public let dailyPercent: Int?
    public let weeklyPercent: Int?
    public let lastUsedAt: Int64?
    public let inFlight: Int
    public let unavailableReason: String?    // banned / cooled / nil
    public let bannedUntil: Int64?
    public let internalErrorStreak: Int
    public let score: Int64

    public init(
        accountId: String, email: String?, tokenPrefix: String,
        cooldownUntil: Int64?, consecutiveFailures: Int,
        dailyPercent: Int?, weeklyPercent: Int?,
        lastUsedAt: Int64?, inFlight: Int,
        unavailableReason: String?, bannedUntil: Int64?,
        internalErrorStreak: Int, score: Int64
    ) {
        self.accountId = accountId
        self.email = email
        self.tokenPrefix = tokenPrefix
        self.cooldownUntil = cooldownUntil
        self.consecutiveFailures = consecutiveFailures
        self.dailyPercent = dailyPercent
        self.weeklyPercent = weeklyPercent
        self.lastUsedAt = lastUsedAt
        self.inFlight = inFlight
        self.unavailableReason = unavailableReason
        self.bannedUntil = bannedUntil
        self.internalErrorStreak = internalErrorStreak
        self.score = score
    }
}

// MARK: - NextJwtCandidate

/// Pool 预览下一次 GetUserJwt 会使用的账号。
/// 只给 App 侧软触发 StartCascade 前做 quota 复检和 apiKey 播种用。
public struct NextJwtCandidate: Sendable, Equatable {
    public let accountId: String
    public let token: String
    public let email: String?

    public init(accountId: String, token: String, email: String?) {
        self.accountId = accountId
        self.token = token
        self.email = email
    }
}

// MARK: - HealthSummary

/// 池整体健康（drought 模式判定）。
public struct HealthSummary: Sendable, Equatable {
    public let drought: Bool
    public let droughtThreshold: Int
    public let totalAccounts: Int
    public let availableAccounts: Int
    public let cooledAccounts: Int
    public let bannedAccounts: Int
    public let lowestWeeklyPercent: Int?
    public let lowestDailyPercent: Int?

    public init(
        drought: Bool, droughtThreshold: Int, totalAccounts: Int,
        availableAccounts: Int, cooledAccounts: Int, bannedAccounts: Int,
        lowestWeeklyPercent: Int?, lowestDailyPercent: Int?
    ) {
        self.drought = drought
        self.droughtThreshold = droughtThreshold
        self.totalAccounts = totalAccounts
        self.availableAccounts = availableAccounts
        self.cooledAccounts = cooledAccounts
        self.bannedAccounts = bannedAccounts
        self.lowestWeeklyPercent = lowestWeeklyPercent
        self.lowestDailyPercent = lowestDailyPercent
    }
}
