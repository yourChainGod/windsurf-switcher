//
//  Server.swift
//  Relay
//
//  Phase 2-A：最简 NIO HTTP 反代。
//
//  监听 127.0.0.1:<bind>，收到 HTTP/1.1 请求后用 AsyncHTTPClient 转发到上游
//  base URL，仅剥 hop-by-hop header。
//
//  与旧 src-tauri/src/relay/server.rs 的差异（Phase 2-A 暂留）：
//    - 无账号池 / 无 splice api_key（Phase 3）
//    - 无 quota rewrite（Phase 3）
//    - 无重试链（Phase 3）
//    - 无 ban_signal / connect_error 检测（Phase 3）
//    - 不支持 TLS 终结（Phase 2-B 接 cascade :42201）
//    - 不支持 path_prefix_strip（Phase 2-B / 3）
//
//  内部端点：
//    - GET /__relay/health  → JSON `{ "ok": true, "name": "...", "stats": {...} }`
//    - GET /__relay/stats   → 原始 stats JSON
//

import Foundation
import NIO
import NIOHTTP1
import NIOPosix
import AsyncHTTPClient
import Logging

public struct RelayInstanceConfig: Sendable {
    public let name: String              // "api" / "inference" / "cascade"
    public let host: String
    public let port: UInt16
    public let upstreamBase: String

    public init(name: String, host: String, port: UInt16, upstreamBase: String) {
        self.name = name
        self.host = host
        self.port = port
        self.upstreamBase = upstreamBase
    }
}

/// 单个 relay 实例的运行时句柄。`stop()` 优雅关闭。
public final class RelayInstance: @unchecked Sendable {
    public let config: RelayInstanceConfig
    public let stats: RelayStats
    private let group: any EventLoopGroup
    private let httpClient: HTTPClient
    private let channel: Channel
    private let logger: Logger

    init(
        config: RelayInstanceConfig,
        group: any EventLoopGroup,
        httpClient: HTTPClient,
        channel: Channel,
        stats: RelayStats,
        logger: Logger
    ) {
        self.config = config
        self.group = group
        self.httpClient = httpClient
        self.channel = channel
        self.stats = stats
        self.logger = logger
    }

    public var boundAddress: SocketAddress? { channel.localAddress }

    public func stop() async {
        do {
            try await channel.close().get()
        } catch {
            logger.warning("relay channel close failed: \(error)")
        }
    }
}

public enum RelayServer {
    /// 启动一个明文 HTTP relay。返回的 RelayInstance 可 await stop() 优雅关闭。
    public static func start(
        config: RelayInstanceConfig,
        group: any EventLoopGroup,
        httpClient: HTTPClient,
        stats: RelayStats? = nil,
        logger: Logger? = nil
    ) async throws -> RelayInstance {
        let log = logger ?? Logger(label: "wss.relay.\(config.name)")
        let st = stats ?? RelayStats()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    let handler = HTTPProxyHandler(
                        config: config,
                        httpClient: httpClient,
                        stats: st,
                        logger: log
                    )
                    return channel.pipeline.addHandler(handler)
                }
            }

        let channel = try await bootstrap.bind(host: config.host, port: Int(config.port)).get()
        log.info("relay '\(config.name)' bound on \(config.host):\(config.port) → \(config.upstreamBase)")

        return RelayInstance(
            config: config,
            group: group,
            httpClient: httpClient,
            channel: channel,
            stats: st,
            logger: log
        )
    }
}

// MARK: - HTTP proxy ChannelHandler

/// 缓冲完整请求 + AsyncHTTPClient 转发上游 + 回写响应（buffered，phase 2-A 简单实现，
/// SSE 流式后续 phase 改造）。
final class HTTPProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: RelayInstanceConfig
    private let httpClient: HTTPClient
    private let stats: RelayStats
    private let logger: Logger

    // 单连接 keep-alive 上下游帧汇聚
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var keepAlive = true

    init(config: RelayInstanceConfig, httpClient: HTTPClient, stats: RelayStats, logger: Logger) {
        self.config = config
        self.httpClient = httpClient
        self.stats = stats
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            requestBody = nil
            keepAlive = head.isKeepAlive
        case .body(var buf):
            if requestBody == nil {
                requestBody = context.channel.allocator.buffer(capacity: buf.readableBytes)
            }
            requestBody!.writeBuffer(&buf)
        case .end:
            guard let head = requestHead else {
                return
            }
            // 缓冲 body
            let bodyBytes = requestBody.flatMap { $0.getBytes(at: $0.readerIndex, length: $0.readableBytes) } ?? []
            requestHead = nil
            requestBody = nil

            // 内部端点：/__relay/health, /__relay/stats
            if head.uri.hasPrefix("/__relay/") {
                handleInternal(context: context, head: head)
                return
            }

            // 普通转发：异步发上游，回来后写回 client
            forwardToUpstream(context: context, head: head, body: bodyBytes)
        }
    }

    // MARK: Internal endpoints

    private func handleInternal(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = head.uri
        let promise = context.eventLoop.makePromise(of: Void.self)
        Task {
            let snap = await stats.snapshot()
            let payload: [String: Any]
            switch path {
            case "/__relay/health":
                payload = [
                    "ok": true,
                    "name": config.name,
                    "host": config.host,
                    "port": config.port,
                    "upstream": config.upstreamBase,
                    "stats": [
                        "total": snap.total,
                        "success": snap.success,
                        "failure": snap.failure,
                        "lastMinute": snap.lastMinuteCount,
                    ],
                ]
            case "/__relay/stats":
                payload = [
                    "total": snap.total,
                    "success": snap.success,
                    "failure": snap.failure,
                    "lastMinute": snap.lastMinuteCount,
                    "recent": snap.recent.map { rpc -> [String: Any] in
                        [
                            "ts": Int(rpc.timestamp.timeIntervalSince1970 * 1000),
                            "path": rpc.path,
                            "status": rpc.status,
                            "durationMillis": rpc.durationMillis,
                        ]
                    },
                ]
            default:
                payload = ["error": "unknown internal path \(path)"]
            }
            let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
            self.writeJSON(context: context, status: .ok, body: body, promise: promise)
        }
        _ = promise.futureResult
    }

    private func writeJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, promise: EventLoopPromise<Void>) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(body.count))
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.eventLoop.execute {
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).cascade(to: promise)
            if !self.keepAlive {
                context.close(promise: nil)
            }
        }
    }

    // MARK: Upstream forwarding

    private func forwardToUpstream(context: ChannelHandlerContext, head: HTTPRequestHead, body: [UInt8]) {
        let started = DispatchTime.now()
        let upstreamURL = config.upstreamBase + head.uri
        let stats = self.stats
        let logger = self.logger
        let client = self.httpClient
        let chConfig = self.config
        let eventLoop = context.eventLoop

        // 复制 channel 引用以便异步回写
        let channel = context.channel

        Task {
            do {
                var req = HTTPClientRequest(url: upstreamURL)
                req.method = .RAW(value: head.method.rawValue)
                // hop-by-hop / 不能透传的 header
                let dropHeaders: Set<String> = [
                    "connection",
                    "transfer-encoding",
                    "keep-alive",
                    "upgrade",
                    "proxy-authenticate",
                    "proxy-authorization",
                    "te",
                    "trailers",
                    "host",            // AsyncHTTPClient 自动按 url 设置
                    "content-length",  // AsyncHTTPClient 按 body 自动重设
                ]
                for (name, value) in head.headers {
                    if dropHeaders.contains(name.lowercased()) { continue }
                    req.headers.add(name: name, value: value)
                }
                if !body.isEmpty {
                    req.body = .bytes(ByteBuffer(bytes: body))
                }

                let resp = try await client.execute(req, timeout: .seconds(120))
                let respBody = try await resp.body.collect(upTo: 64 * 1024 * 1024)
                let respBytes = respBody.getBytes(at: respBody.readerIndex, length: respBody.readableBytes) ?? []

                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                await stats.record(RecentRPC(
                    path: head.uri,
                    status: Int(resp.status.code),
                    durationMillis: Int(elapsed)
                ))

                // 回写 client（在 EventLoop 上）
                eventLoop.execute {
                    var headers = HTTPHeaders()
                    let hopByHop: Set<String> = ["transfer-encoding", "connection", "keep-alive", "trailer"]
                    for (n, v) in resp.headers {
                        if hopByHop.contains(n.lowercased()) { continue }
                        headers.add(name: n, value: v)
                    }
                    headers.replaceOrAdd(name: "content-length", value: String(respBytes.count))
                    let respHead = HTTPResponseHead(
                        version: .http1_1,
                        status: HTTPResponseStatus(statusCode: Int(resp.status.code)),
                        headers: headers
                    )
                    channel.write(NIOAny(HTTPServerResponsePart.head(respHead)), promise: nil)
                    var buf = channel.allocator.buffer(capacity: respBytes.count)
                    buf.writeBytes(respBytes)
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
                    channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                        if !self.keepAlive {
                            channel.close(promise: nil)
                        }
                    }
                }
            } catch {
                let detailed = "\(error)"
                logger.warning("upstream \(chConfig.name) [\(upstreamURL)] failed: \(detailed)")
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                await stats.record(RecentRPC(
                    path: head.uri,
                    status: 502,
                    durationMillis: Int(elapsed)
                ))
                eventLoop.execute {
                    let bodyText = "{\"error\":\"upstream failed\",\"detail\":\(self.jsonEscape(detailed))}"
                    let body = Data(bodyText.utf8)
                    var headers = HTTPHeaders()
                    headers.add(name: "content-type", value: "application/json")
                    headers.add(name: "content-length", value: String(body.count))
                    let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
                    channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                    var buf = channel.allocator.buffer(capacity: body.count)
                    buf.writeBytes(body)
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
                    channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                        if !self.keepAlive {
                            channel.close(promise: nil)
                        }
                    }
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("relay handler error: \(error)")
        context.close(promise: nil)
    }

    private func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
