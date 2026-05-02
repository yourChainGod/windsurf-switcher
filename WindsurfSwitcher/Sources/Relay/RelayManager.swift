//
//  RelayManager.swift
//  Relay
//
//  统一管理 api / inference / cascade 三个 relay 实例的启停。Phase 2-A 仅启
//  api + inference 两个明文端口；cascade :42201 留 Phase 2-B（TLS 终结）。
//

import Foundation
import NIO
import NIOPosix
import AsyncHTTPClient
import Logging

public struct RelayManagerStatus: Sendable, Equatable {
    public var apiRunning: Bool
    public var apiBoundDescription: String?
    public var inferenceRunning: Bool
    public var inferenceBoundDescription: String?
    public var cascadeRunning: Bool   // Phase 2-A 始终 false（待 2-B）

    public init(
        apiRunning: Bool = false, apiBoundDescription: String? = nil,
        inferenceRunning: Bool = false, inferenceBoundDescription: String? = nil,
        cascadeRunning: Bool = false
    ) {
        self.apiRunning = apiRunning
        self.apiBoundDescription = apiBoundDescription
        self.inferenceRunning = inferenceRunning
        self.inferenceBoundDescription = inferenceBoundDescription
        self.cascadeRunning = cascadeRunning
    }
}

public actor RelayManager {
    private let group: any EventLoopGroup
    private let httpClient: HTTPClient
    private let logger: Logger

    public let config: RelayConfig
    /// 调度中心：Pool actor（号池）。
    public let pool: Pool

    private var apiInstance: RelayInstance?
    private var inferenceInstance: RelayInstance?
    private var updateSink: UpdateSink?

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

    /// 启动 api + inference 两个明文 relay，并把 Pool 关联到 api 实例（让其
    /// 内部端点 /__relay/health + /__relay/pool 暴露调度中心快照）。
    public func start() async throws {
        if apiInstance == nil {
            let cfg = RelayInstanceConfig(
                name: "api",
                host: config.apiBindHost,
                port: config.apiBindPort,
                upstreamBase: config.apiUpstreamBase
            )
            apiInstance = try await RelayServer.start(
                config: cfg, group: group, httpClient: httpClient,
                pool: pool, updateSink: updateSink, logger: logger
            )
        }
        if inferenceInstance == nil {
            let cfg = RelayInstanceConfig(
                name: "inference",
                host: config.inferenceBindHost,
                port: config.inferenceBindPort,
                upstreamBase: config.inferenceUpstreamBase
            )
            inferenceInstance = try await RelayServer.start(
                config: cfg, group: group, httpClient: httpClient,
                pool: pool, updateSink: updateSink, logger: logger
            )
        }
    }

    public func stop() async {
        if let i = apiInstance {
            await i.stop()
            apiInstance = nil
        }
        if let i = inferenceInstance {
            await i.stop()
            inferenceInstance = nil
        }
    }

    public func status() -> RelayManagerStatus {
        RelayManagerStatus(
            apiRunning: apiInstance != nil,
            apiBoundDescription: apiInstance?.boundAddress?.description,
            inferenceRunning: inferenceInstance != nil,
            inferenceBoundDescription: inferenceInstance?.boundAddress?.description,
            cascadeRunning: false
        )
    }

    public var apiStats: RelayStats? { apiInstance?.stats }
    public var inferenceStats: RelayStats? { inferenceInstance?.stats }

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
