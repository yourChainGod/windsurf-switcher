//
//  RelayConfig.swift
//  Relay
//
//  cascade-relay 端口与上游配置（直译 src-tauri/src/config.rs::RelayConfig）。
//

import Foundation

public struct RelayConfig: Sendable, Equatable {
    /// api_server 端口（telemetry / auth / GetUserStatus 等）
    public var apiBindHost: String
    public var apiBindPort: UInt16
    public var apiUpstreamBase: String

    /// inference 端口（cascade chat / 推理 / completions）
    public var inferenceBindHost: String
    public var inferenceBindPort: UInt16
    public var inferenceUpstreamBase: String

    /// cascade 端口（被劫持的 server.codeium.com 流量；TLS 终结。Phase 2-B 接通）
    public var cascadeBindHost: String
    public var cascadeBindPort: UInt16
    public var cascadeUpstreamBase: String
    /// LS 二进制 patch 后基址附加的固定路径前缀，转发上游前剥掉
    public var cascadePathPrefix: String

    public init(
        apiBindHost: String = "127.0.0.1",
        apiBindPort: UInt16 = 42199,
        apiUpstreamBase: String = "https://server.self-serve.windsurf.com",
        inferenceBindHost: String = "127.0.0.1",
        inferenceBindPort: UInt16 = 42200,
        inferenceUpstreamBase: String = "https://inference.codeium.com",
        cascadeBindHost: String = "127.0.0.1",
        cascadeBindPort: UInt16 = 42201,
        cascadeUpstreamBase: String = "https://server.codeium.com",
        cascadePathPrefix: String = "/svc"
    ) {
        self.apiBindHost = apiBindHost
        self.apiBindPort = apiBindPort
        self.apiUpstreamBase = apiUpstreamBase
        self.inferenceBindHost = inferenceBindHost
        self.inferenceBindPort = inferenceBindPort
        self.inferenceUpstreamBase = inferenceUpstreamBase
        self.cascadeBindHost = cascadeBindHost
        self.cascadeBindPort = cascadeBindPort
        self.cascadeUpstreamBase = cascadeUpstreamBase
        self.cascadePathPrefix = cascadePathPrefix
    }

    public static let `default` = RelayConfig()
}
