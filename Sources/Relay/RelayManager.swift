//
//  RelayManager.swift
//  Relay
//
//  统一管理 api + inference 两个 relay 实例的启停。
//  （cascade :42201 + DNS 劫持那条路已废，cascade chat 流量直连原版上游）
//

import Foundation
import Core
import NIO
import NIOPosix
import AsyncHTTPClient
import Logging

public struct RelayManagerStatus: Sendable, Equatable {
    public var apiRunning: Bool
    public var apiBoundDescription: String?
    public var inferenceRunning: Bool
    public var inferenceBoundDescription: String?
    public var nextApiRunning: Bool
    public var nextApiBoundDescription: String?
    public var nextInferenceRunning: Bool
    public var nextInferenceBoundDescription: String?

    public init(
        apiRunning: Bool = false, apiBoundDescription: String? = nil,
        inferenceRunning: Bool = false, inferenceBoundDescription: String? = nil,
        nextApiRunning: Bool = false, nextApiBoundDescription: String? = nil,
        nextInferenceRunning: Bool = false, nextInferenceBoundDescription: String? = nil
    ) {
        self.apiRunning = apiRunning
        self.apiBoundDescription = apiBoundDescription
        self.inferenceRunning = inferenceRunning
        self.inferenceBoundDescription = inferenceBoundDescription
        self.nextApiRunning = nextApiRunning
        self.nextApiBoundDescription = nextApiBoundDescription
        self.nextInferenceRunning = nextInferenceRunning
        self.nextInferenceBoundDescription = nextInferenceBoundDescription
    }
}

public actor RelayManager {
    private let group: any EventLoopGroup
    private let httpClient: HTTPClient
    private let logger: Logger

    public let config: RelayConfig
    /// 调度中心：Pool actor（号池）。
    public let pool: Pool

    private var apiInstances: [WindsurfApp: RelayInstance] = [:]
    private var inferenceInstances: [WindsurfApp: RelayInstance] = [:]
    private var updateSink: UpdateSink?
    private var accountSink: AccountSink?
    private var quotaRefreshSink: QuotaRefreshSink?

    public init(config: RelayConfig = .default, poolConfig: PoolConfig = .default) {
        self.config = config
        self.group = MultiThreadedEventLoopGroup.singleton
        self.httpClient = HTTPClient.shared
        self.logger = Logger(label: "wss.relay.manager")
        self.pool = Pool(config: poolConfig)
    }

    /// AppState 启动时注入 sink；relay start 后调度路径会通过此 sink 落库。
    public func setUpdateSink(_ sink: UpdateSink) {
        self.updateSink = sink
    }

    /// 注入 AccountSink；POST /__relay/accounts 来号时通过它入库。
    /// 必须在 start() 之前调用，否则 instance 拿不到。
    public func setAccountSink(_ sink: AccountSink) {
        self.accountSink = sink
    }

    /// 注入 QuotaRefreshSink；GetChatMessage 完成 / active 切号等事件触发即时 quota 刷新。
    /// 必须在 start() 之前调用。
    public func setQuotaRefreshSink(_ sink: QuotaRefreshSink) {
        self.quotaRefreshSink = sink
    }

    /// 暴露 Pool 当前 active accountId（active fast-refresh ticker 用）。
    public func currentActiveAccountId() async -> String? {
        await pool.getCurrentActiveAccount(app: .stable)
    }

    public func currentActiveAccountId(app: WindsurfApp) async -> String? {
        await pool.getCurrentActiveAccount(app: app)
    }

    public func currentActiveAccountIds() async -> [String] {
        let active = await pool.getCurrentActiveAccounts()
        return Array(Set(active.values))
    }

    /// 预览下一次 GetUserJwt 会选择的账号；App 侧软触发 StartCascade 前用于
    /// 强制 quota 复检和 apiKey 播种，避免触发后切到无额度账号。
    public func nextJwtCandidate(
        app: WindsurfApp = .stable,
        forceRotateFromActive: Bool = true
    ) async -> NextJwtCandidate? {
        await pool.nextJwtCandidate(app: app, forceRotateFromActive: forceRotateFromActive)
    }

    /// 启动 stable/next 各一组 api + inference relay，并共享同一个 Pool。
    /// app scope 由端口对应的 RelayInstanceConfig 携带；active JWT 状态按 app 隔离。
    ///
    /// api 实例暴露内部端点 /__relay/health + /__relay/pool。
    /// stable api 额外挂 AccountSink；POST /__relay/accounts 仍由 :42199 处理。
    public func start() async throws {
        for app in WindsurfApp.allCases {
            if apiInstances[app] == nil {
                let cfg = RelayInstanceConfig(
                    app: app,
                    name: "\(app.rawValue)-api",
                    host: config.apiBindHost(for: app),
                    port: config.apiBindPort(for: app),
                    upstreamBase: config.apiUpstreamBase
                )
                apiInstances[app] = try await RelayServer.start(
                    config: cfg, group: group, httpClient: httpClient,
                    pool: pool, updateSink: updateSink,
                    accountSink: app == .stable ? accountSink : nil,
                    quotaRefreshSink: quotaRefreshSink,
                    logger: logger
                )
            }
            if inferenceInstances[app] == nil {
                let cfg = RelayInstanceConfig(
                    app: app,
                    name: "\(app.rawValue)-inference",
                    host: config.inferenceBindHost(for: app),
                    port: config.inferenceBindPort(for: app),
                    upstreamBase: config.inferenceUpstreamBase
                )
                inferenceInstances[app] = try await RelayServer.start(
                    config: cfg, group: group, httpClient: httpClient,
                    pool: pool, updateSink: updateSink,
                    quotaRefreshSink: quotaRefreshSink,
                    logger: logger
                )
            }
        }
    }

    public func stop() async {
        for i in apiInstances.values {
            await i.stop()
        }
        apiInstances.removeAll()
        for i in inferenceInstances.values {
            await i.stop()
        }
        inferenceInstances.removeAll()
    }

    public func status() -> RelayManagerStatus {
        RelayManagerStatus(
            apiRunning: apiInstances[.stable] != nil,
            apiBoundDescription: apiInstances[.stable]?.boundAddress?.description,
            inferenceRunning: inferenceInstances[.stable] != nil,
            inferenceBoundDescription: inferenceInstances[.stable]?.boundAddress?.description,
            nextApiRunning: apiInstances[.next] != nil,
            nextApiBoundDescription: apiInstances[.next]?.boundAddress?.description,
            nextInferenceRunning: inferenceInstances[.next] != nil,
            nextInferenceBoundDescription: inferenceInstances[.next]?.boundAddress?.description
        )
    }

    public var apiStats: RelayStats? { apiInstances[.stable]?.stats }
    public var inferenceStats: RelayStats? { inferenceInstances[.stable]?.stats }

    /// 拼合 api + inference 两路 stats 给 Dashboard 用。
    public func combinedStatsSnapshot() async -> StatsSnapshot {
        var snaps: [StatsSnapshot] = []
        for instance in apiInstances.values {
            snaps.append(await instance.stats.snapshot())
        }
        for instance in inferenceInstances.values {
            snaps.append(await instance.stats.snapshot())
        }
        let total = snaps.reduce(UInt64(0)) { $0 + $1.total }
        let success = snaps.reduce(UInt64(0)) { $0 + $1.success }
        let failure = snaps.reduce(UInt64(0)) { $0 + $1.failure }
        let lastMin = snaps.reduce(UInt64(0)) { $0 + $1.lastMinuteCount }
        // 合并 recent 并按时间倒序
        var recent = snaps.flatMap(\.recent)
        recent.sort { $0.timestamp > $1.timestamp }
        if recent.count > 50 { recent = Array(recent.prefix(50)) }
        return StatsSnapshot(
            total: total, success: success, failure: failure,
            lastMinuteCount: lastMin, recent: recent
        )
    }

    /// 同步外部账号列表到 Pool（5s ticker 调用）。
    public func syncPool(_ seeds: [PoolAccountSeed]) async {
        await pool.replaceAccounts(seeds)
    }

    public func poolSnapshot() async -> [EntrySnapshot] {
        await pool.snapshot()
    }

    public func poolHealth() async -> HealthSummary {
        await pool.healthSummary()
    }

    // 不写 deinit：singleton group + HTTPClient.shared 由库自管。
}
