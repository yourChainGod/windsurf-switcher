//
//  Stats.swift
//  Relay
//
//  实时统计：环形 buffer + 累计计数器（直译 src-tauri/src/relay/stats.rs）。
//  给 Dashboard 提供 "最近 50 个 RPC" / "累计请求数" / "最近一分钟吞吐"。
//

import Foundation

public struct RecentRPC: Sendable, Equatable {
    public let timestamp: Date
    public let path: String
    public let accountId: String?
    public let email: String?
    public let status: Int
    public let cascadeId: String?
    public let durationMillis: Int

    public init(
        timestamp: Date = Date(),
        path: String,
        accountId: String? = nil,
        email: String? = nil,
        status: Int,
        cascadeId: String? = nil,
        durationMillis: Int
    ) {
        self.timestamp = timestamp
        self.path = path
        self.accountId = accountId
        self.email = email
        self.status = status
        self.cascadeId = cascadeId
        self.durationMillis = durationMillis
    }
}

public struct StatsSnapshot: Sendable, Equatable {
    public let total: UInt64
    public let success: UInt64
    public let failure: UInt64
    public let lastMinuteCount: UInt64
    public let recent: [RecentRPC]

    public init(
        total: UInt64,
        success: UInt64,
        failure: UInt64,
        lastMinuteCount: UInt64,
        recent: [RecentRPC]
    ) {
        self.total = total
        self.success = success
        self.failure = failure
        self.lastMinuteCount = lastMinuteCount
        self.recent = recent
    }
}

public actor RelayStats {
    private static let ringCapacity = 50
    private var recent: [RecentRPC] = []
    private(set) var total: UInt64 = 0
    private(set) var success: UInt64 = 0
    private(set) var failure: UInt64 = 0

    public init() {}

    public func record(_ rpc: RecentRPC) {
        total += 1
        if (200..<300).contains(rpc.status) {
            success += 1
        } else {
            failure += 1
        }
        if recent.count >= Self.ringCapacity {
            recent.removeFirst()
        }
        recent.append(rpc)
    }

    public func snapshot() -> StatsSnapshot {
        let now = Date()
        let lastMinute = recent.filter {
            now.timeIntervalSince($0.timestamp) <= 60
        }.count
        return StatsSnapshot(
            total: total,
            success: success,
            failure: failure,
            lastMinuteCount: UInt64(lastMinute),
            // 反序：最新的在前
            recent: recent.reversed()
        )
    }
}
