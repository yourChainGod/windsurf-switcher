//
//  RelayConfig.swift
//  Relay
//
//  Relay 端口与上游配置：stable/next 各一组 api + inference 明文端口。
//  （cascade :42201 + DNS 劫持 + Loon plugin 那条路已废，cascade 流量直连原版上游）
//

import Foundation
import Core

public struct RelayConfig: Sendable, Equatable {
    /// Stable api_server 端口（telemetry / auth / GetUserStatus 等）
    public var apiBindHost: String
    public var apiBindPort: UInt16
    public var apiUpstreamBase: String

    /// Stable inference 端口（推理 / completions）
    public var inferenceBindHost: String
    public var inferenceBindPort: UInt16
    public var inferenceUpstreamBase: String

    /// Next 专用端口；与 stable 分开，让 relay 能天然识别 app scope。
    public var nextApiBindPort: UInt16
    public var nextInferenceBindPort: UInt16

    public init(
        apiBindHost: String = "127.0.0.1",
        apiBindPort: UInt16 = 42199,
        apiUpstreamBase: String = "https://server.self-serve.windsurf.com",
        inferenceBindHost: String = "127.0.0.1",
        inferenceBindPort: UInt16 = 42200,
        inferenceUpstreamBase: String = "https://inference.codeium.com",
        nextApiBindPort: UInt16 = 42201,
        nextInferenceBindPort: UInt16 = 42202
    ) {
        self.apiBindHost = apiBindHost
        self.apiBindPort = apiBindPort
        self.apiUpstreamBase = apiUpstreamBase
        self.inferenceBindHost = inferenceBindHost
        self.inferenceBindPort = inferenceBindPort
        self.inferenceUpstreamBase = inferenceUpstreamBase
        self.nextApiBindPort = nextApiBindPort
        self.nextInferenceBindPort = nextInferenceBindPort
    }

    public func apiBindHost(for app: WindsurfApp) -> String {
        apiBindHost
    }

    public func apiBindPort(for app: WindsurfApp) -> UInt16 {
        switch app {
        case .stable: return apiBindPort
        case .next: return nextApiBindPort
        }
    }

    public func inferenceBindHost(for app: WindsurfApp) -> String {
        inferenceBindHost
    }

    public func inferenceBindPort(for app: WindsurfApp) -> UInt16 {
        switch app {
        case .stable: return inferenceBindPort
        case .next: return nextInferenceBindPort
        }
    }

    public static let `default` = RelayConfig()
}
