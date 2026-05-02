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

    private var apiInstance: RelayInstance?
    private var inferenceInstance: RelayInstance?

    public init(config: RelayConfig = .default) {
        self.config = config
        // singleton group + HTTPClient.shared：库自管生命周期，不会被 deinit 误关
        self.group = MultiThreadedEventLoopGroup.singleton
        self.httpClient = HTTPClient.shared
        self.logger = Logger(label: "wss.relay.manager")
    }

    /// 启动 api + inference 两个明文 relay。Phase 2-A 不启 cascade。
    public func start() async throws {
        if apiInstance == nil {
            let cfg = RelayInstanceConfig(
                name: "api",
                host: config.apiBindHost,
                port: config.apiBindPort,
                upstreamBase: config.apiUpstreamBase
            )
            apiInstance = try await RelayServer.start(
                config: cfg, group: group, httpClient: httpClient, logger: logger
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
                config: cfg, group: group, httpClient: httpClient, logger: logger
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

    // 不写 deinit：singleton group + HTTPClient.shared 由库自管。
}
