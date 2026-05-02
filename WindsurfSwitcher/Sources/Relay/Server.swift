//
//  Server.swift
//  Relay
//
//  Phase 3-B：NIO HTTP 反代 + 账号池调度。
//
//  监听 127.0.0.1:<bind>，收到 HTTP/1.1 请求后：
//    - pool != nil → 走调度路径：lease → splice api_key → 转发 → 重试 → record_*
//    - pool == nil → 透传（向后兼容）
//
//  与旧 src-tauri/src/relay/server.rs 的差异（仍未补齐）：
//    - 无 quota rewrite（Phase 3-C）
//    - 无 ban_signal regex（Phase 3-C）
//    - 无 connect_error 应用层错误检测（Phase 3-C）
//    - cascade :42201 TLS 终结暂未启用（Phase 2-B 跳过）
//
//  内部端点：
//    - GET /__relay/health  → JSON `{ ok, name, stats, pool? }`
//    - GET /__relay/stats   → 原始 stats JSON
//    - GET /__relay/pool    → 池快照（只读 view）
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
    /// 可选 Pool 引用：内部端点 + 调度路径用。nil 表示纯透传。
    public let pool: Pool?
    public let updateSink: UpdateSink?
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
        pool: Pool?,
        updateSink: UpdateSink?,
        logger: Logger
    ) {
        self.config = config
        self.group = group
        self.httpClient = httpClient
        self.channel = channel
        self.stats = stats
        self.pool = pool
        self.updateSink = updateSink
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
        pool: Pool? = nil,
        updateSink: UpdateSink? = nil,
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
                        pool: pool,
                        updateSink: updateSink,
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
            pool: pool,
            updateSink: updateSink,
            logger: log
        )
    }
}

// MARK: - HTTP proxy ChannelHandler

/// 缓冲完整请求 + AsyncHTTPClient 转发上游 + 回写响应。
final class HTTPProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// 调度路径单次重试上限（参考 server.rs）
    static let maxAttempts = 5

    private let config: RelayInstanceConfig
    private let httpClient: HTTPClient
    private let stats: RelayStats
    private let pool: Pool?
    private let updateSink: UpdateSink?
    private let logger: Logger

    // 单连接 keep-alive 上下游帧汇聚
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var keepAlive = true

    init(
        config: RelayInstanceConfig,
        httpClient: HTTPClient,
        stats: RelayStats,
        pool: Pool?,
        updateSink: UpdateSink?,
        logger: Logger
    ) {
        self.config = config
        self.httpClient = httpClient
        self.stats = stats
        self.pool = pool
        self.updateSink = updateSink
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
            let bodyBytes = requestBody.flatMap { $0.getBytes(at: $0.readerIndex, length: $0.readableBytes) } ?? []
            requestHead = nil
            requestBody = nil

            if head.uri.hasPrefix("/__relay/") {
                handleInternal(context: context, head: head)
                return
            }

            // GetPlanStatus 劫持：永远返回伪造的满血响应，不打上游
            if head.uri.contains("/exa.seat_management_pb.SeatManagementService/GetPlanStatus") {
                handleFakePlanStatus(context: context, head: head)
                return
            }

            // 调度路径 vs 透传
            if pool != nil {
                forwardWithPool(context: context, head: head, body: bodyBytes)
            } else {
                forwardPassthrough(context: context, head: head, body: bodyBytes)
            }
        }
    }

    // MARK: GetPlanStatus 伪造（不打上游）

    private func handleFakePlanStatus(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let started = DispatchTime.now()
        let stats = self.stats
        let logger = self.logger
        let chConfig = self.config
        let channel = context.channel
        let eventLoop = context.eventLoop
        Task {
            let body = QuotaRewrite.buildFakePlanStatusBody()
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/proto")
            headers.add(name: "content-length", value: String(body.count))
            let bytes = [UInt8](body)
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            await stats.record(RecentRPC(path: head.uri, status: 200, durationMillis: Int(elapsed)))
            logger.info("[\(chConfig.name)] intercepted GetPlanStatus → fake unlimited (\(bytes.count)B)")
            await Self.writeBack(channel: channel, eventLoop: eventLoop, status: .ok, headers: headers, body: bytes, keepAlive: self.keepAlive)
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
                var body: [String: Any] = [
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
                if let pool = self.pool {
                    let h = await pool.healthSummary()
                    body["pool"] = [
                        "drought": h.drought,
                        "total": h.totalAccounts,
                        "available": h.availableAccounts,
                        "cooled": h.cooledAccounts,
                        "banned": h.bannedAccounts,
                        "lowestWeeklyPercent": h.lowestWeeklyPercent ?? -1,
                        "lowestDailyPercent": h.lowestDailyPercent ?? -1,
                    ]
                }
                payload = body
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
            case "/__relay/pool":
                if let pool = self.pool {
                    let entries = await pool.snapshot()
                    payload = [
                        "size": entries.count,
                        "entries": entries.map { e -> [String: Any] in
                            [
                                "id": e.accountId,
                                "email": e.email ?? NSNull(),
                                "score": e.score,
                                "daily": e.dailyPercent ?? NSNull(),
                                "weekly": e.weeklyPercent ?? NSNull(),
                                "inFlight": e.inFlight,
                                "lastUsed": e.lastUsedAt ?? NSNull(),
                                "cooldownUntil": e.cooldownUntil ?? NSNull(),
                                "consecutiveFailures": e.consecutiveFailures,
                                "internalErrorStreak": e.internalErrorStreak,
                                "bannedUntil": e.bannedUntil ?? NSNull(),
                                "unavailableReason": e.unavailableReason ?? NSNull(),
                            ]
                        },
                    ]
                } else {
                    payload = ["error": "pool not attached to this relay"]
                }
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

    // MARK: 调度路径（pool != nil）

    /// 池化转发：lease → splice api_key（若 body 是 metadata）→ 调上游 →
    /// 失败 record_failure 入 excludes 重试 → 成功 record_success；最多 5 次。
    /// 拿到的 AccountUpdate 通过 updateSink 异步落库。
    private func forwardWithPool(context: ChannelHandlerContext, head: HTTPRequestHead, body: [UInt8]) {
        let started = DispatchTime.now()
        let upstreamURL = config.upstreamBase + head.uri
        let stats = self.stats
        let logger = self.logger
        let client = self.httpClient
        let chConfig = self.config
        let eventLoop = context.eventLoop
        let channel = context.channel
        guard let pool = self.pool else {
            forwardPassthrough(context: context, head: head, body: body)
            return
        }
        let sink = self.updateSink
        // cascadeId 在 cascade :42201 启用后从请求 header 提取；当前 phase 全 nil
        let cascadeId: String? = nil

        // GetUserJwt 是"播种"调用：LS 拿到 JWT 后会缓存使用，必须给真正最强号。
        // → strictBest=true 触发 score 优先排序（不分桶、忽略 inFlight、忽略 sticky）。
        let isGetUserJwt = head.uri.contains("/exa.auth_pb.AuthService/GetUserJwt")

        Task {
            var excludes: [String] = []
            var lastError: Error?
            // last "good enough" response 用于 AllExcluded 兜底
            var lastResp: (status: HTTPResponseStatus, headers: HTTPHeaders, body: [UInt8])?

            for attempt in 1...HTTPProxyHandler.maxAttempts {
                let lease: Lease
                do {
                    lease = try await pool.lease(
                        cascadeId: cascadeId,
                        excludes: excludes,
                        strictBest: isGetUserJwt
                    )
                } catch let err {
                    lastError = err
                    // 没号可用：用 last good 兜底，否则 502
                    if let r = lastResp {
                        await Self.writeBack(channel: channel, eventLoop: eventLoop, status: r.status, headers: r.headers, body: r.body, keepAlive: self.keepAlive)
                    } else {
                        await Self.writeError(channel: channel, eventLoop: eventLoop, status: .badGateway, detail: "no usable account: \(err)", keepAlive: self.keepAlive)
                    }
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    await stats.record(RecentRPC(path: head.uri, status: 502, durationMillis: Int(elapsed)))
                    return
                }
                let accountId = lease.accountId
                let token = lease.token

                // 构造请求 body：若是 metadata 包，splice api_key
                var requestBody = body
                let tokenBytes = Array(token.utf8)
                if !body.isEmpty {
                    do {
                        try ProtoRewrite.rewriteApiKey(&requestBody, newToken: tokenBytes)
                    } catch ProtoRewriteError.notMetadataFirst {
                        // 不是 metadata（Ping 等）→ 透传
                    } catch ProtoRewriteError.noApiKeyField {
                        // 初始化期 RPC 等 → 透传
                    } catch ProtoRewriteError.tokenLengthMismatch(let exp, let got) {
                        logger.warning("[\(chConfig.name)] token length mismatch (expected \(exp), got \(got)); body untouched")
                    } catch {
                        logger.warning("[\(chConfig.name)] proto rewrite failed: \(error); body untouched")
                    }
                }

                // 发上游
                do {
                    var req = HTTPClientRequest(url: upstreamURL)
                    req.method = .RAW(value: head.method.rawValue)
                    let dropHeaders: Set<String> = [
                        "connection", "transfer-encoding", "keep-alive", "upgrade",
                        "proxy-authenticate", "proxy-authorization", "te", "trailers",
                        "host", "content-length",
                    ]
                    for (name, value) in head.headers {
                        if dropHeaders.contains(name.lowercased()) { continue }
                        req.headers.add(name: name, value: value)
                    }
                    if !requestBody.isEmpty {
                        req.body = .bytes(ByteBuffer(bytes: requestBody))
                    }

                    let resp = try await client.execute(req, timeout: .seconds(120))
                    let respBody = try await resp.body.collect(upTo: 64 * 1024 * 1024)
                    var respBytes = respBody.getBytes(at: respBody.readerIndex, length: respBody.readableBytes) ?? []
                    let statusCode = Int(resp.status.code)
                    var respHeaders = resp.headers

                    // ── 4xx/5xx：record_failure + ban_signal 检测 ─────────
                    if let kind = FailureKind.fromStatus(statusCode) {
                        var override: TimeInterval? = nil
                        if kind == .rateLimit {
                            override = parseResetIn(headers: resp.headers, body: respBytes)
                        }
                        let update = await pool.recordFailureWithCooldown(accountId, kind: kind, cooldownOverride: override)
                        if let upd = update, let s = sink {
                            await s.apply(upd)
                        }

                        // 401/403 → 检 ban_signal（30min 窗内 2 次 → banned 10 年）
                        if kind == .auth {
                            let text = BanSignal.extractText(respBytes, maxBytes: 8 * 1024)
                            if BanSignal.matches(text) {
                                let banUpd = await pool.recordBanSignal(accountId)
                                if let upd = banUpd, let s = sink {
                                    await s.apply(upd)
                                }
                                logger.warning("[\(chConfig.name)] ban_signal hit acct=\(prefix8(accountId)) text=\(text.prefix(120))")
                            }
                        }

                        lastResp = (resp.status, resp.headers, respBytes)
                        excludes.append(accountId)
                        logger.info("[\(chConfig.name)] attempt \(attempt) acct=\(prefix8(accountId)) → \(statusCode) (\(kind)); retry=\(attempt < HTTPProxyHandler.maxAttempts)")
                        continue
                    }

                    // ── 2xx：先看应用层 connect_error 帧 ─────────────────
                    let contentType = resp.headers.first(name: "content-type") ?? ""
                    if let appErr = ConnectError.detect(headers: resp.headers, body: respBytes, contentType: contentType) {
                        // 200 但应用层有错——视为失败，按错误类型决定 cooldown
                        let kind: FailureKind
                        var override: TimeInterval? = appErr.resetIn
                        if ConnectError.isRateLimit(appErr.message) {
                            kind = .rateLimit
                        } else if appErr.code?.hasPrefix("grpc:7") == true || appErr.message.lowercased().contains("unauthenticated") || appErr.message.lowercased().contains("permission") {
                            kind = .auth
                        } else {
                            kind = .transient
                        }
                        let update = await pool.recordFailureWithCooldown(accountId, kind: kind, cooldownOverride: override)
                        if let upd = update, let s = sink {
                            await s.apply(upd)
                        }
                        // ban signal 也来一次（200 但带 ban 文案的偶发场景）
                        if kind == .auth && BanSignal.matches(appErr.message) {
                            let banUpd = await pool.recordBanSignal(accountId)
                            if let upd = banUpd, let s = sink {
                                await s.apply(upd)
                            }
                        }
                        lastResp = (resp.status, resp.headers, respBytes)
                        excludes.append(accountId)
                        logger.info("[\(chConfig.name)] attempt \(attempt) acct=\(prefix8(accountId)) 200+app_err code=\(appErr.code ?? "?") msg=\(appErr.message.prefix(80)) (\(kind))")
                        continue
                    }

                    // ── 2xx 成功：GetUserStatus 路径改写 quota ───────────
                    if head.uri.contains("/exa.seat_management_pb.SeatManagementService/GetUserStatus") {
                        do {
                            let rewritten = try QuotaRewrite.rewriteUserStatusQuota(Data(respBytes))
                            respBytes = [UInt8](rewritten)
                            // 重设 content-length
                            respHeaders.remove(name: "content-length")
                            respHeaders.add(name: "content-length", value: String(respBytes.count))
                            logger.info("[\(chConfig.name)] rewrote GetUserStatus quota (\(respBytes.count)B)")
                        } catch {
                            logger.warning("[\(chConfig.name)] GetUserStatus rewrite failed: \(error); passthrough")
                        }
                    }

                    let updateOk = await pool.recordSuccess(accountId)
                    if let upd = updateOk, let s = sink {
                        await s.apply(upd)
                    }
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    await stats.record(RecentRPC(path: head.uri, accountId: accountId, email: lease.email, status: statusCode, durationMillis: Int(elapsed)))
                    await Self.writeBack(channel: channel, eventLoop: eventLoop, status: resp.status, headers: respHeaders, body: respBytes, keepAlive: self.keepAlive)
                    return
                } catch let err {
                    // 网络层 / timeout → transient
                    let update = await pool.recordFailure(accountId, kind: .transient)
                    if let upd = update, let s = sink {
                        await s.apply(upd)
                    }
                    excludes.append(accountId)
                    lastError = err
                    logger.warning("[\(chConfig.name)] attempt \(attempt) acct=\(prefix8(accountId)) network err: \(err)")
                    continue
                }
            } // end for

            // 5 次都失败：用 lastResp 兜底，否则报 502
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            if let r = lastResp {
                await stats.record(RecentRPC(path: head.uri, status: Int(r.status.code), durationMillis: Int(elapsed)))
                await Self.writeBack(channel: channel, eventLoop: eventLoop, status: r.status, headers: r.headers, body: r.body, keepAlive: self.keepAlive)
            } else {
                await stats.record(RecentRPC(path: head.uri, status: 502, durationMillis: Int(elapsed)))
                let detail = lastError.map { "\($0)" } ?? "all attempts exhausted"
                await Self.writeError(channel: channel, eventLoop: eventLoop, status: .badGateway, detail: detail, keepAlive: self.keepAlive)
            }
        }
    }

    // MARK: 透传路径（pool == nil）

    private func forwardPassthrough(context: ChannelHandlerContext, head: HTTPRequestHead, body: [UInt8]) {
        let started = DispatchTime.now()
        let upstreamURL = config.upstreamBase + head.uri
        let stats = self.stats
        let logger = self.logger
        let client = self.httpClient
        let chConfig = self.config
        let eventLoop = context.eventLoop
        let channel = context.channel

        Task {
            do {
                var req = HTTPClientRequest(url: upstreamURL)
                req.method = .RAW(value: head.method.rawValue)
                let dropHeaders: Set<String> = [
                    "connection", "transfer-encoding", "keep-alive", "upgrade",
                    "proxy-authenticate", "proxy-authorization", "te", "trailers",
                    "host", "content-length",
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
                await stats.record(RecentRPC(path: head.uri, status: Int(resp.status.code), durationMillis: Int(elapsed)))
                await Self.writeBack(channel: channel, eventLoop: eventLoop, status: resp.status, headers: resp.headers, body: respBytes, keepAlive: self.keepAlive)
            } catch {
                let detailed = "\(error)"
                logger.warning("upstream \(chConfig.name) [\(upstreamURL)] failed: \(detailed)")
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                await stats.record(RecentRPC(path: head.uri, status: 502, durationMillis: Int(elapsed)))
                await Self.writeError(channel: channel, eventLoop: eventLoop, status: .badGateway, detail: detailed, keepAlive: self.keepAlive)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("relay handler error: \(error)")
        context.close(promise: nil)
    }

    // MARK: 静态写回 helpers（async 包到 EventLoop）

    private static func writeBack(
        channel: Channel,
        eventLoop: EventLoop,
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        body: [UInt8],
        keepAlive: Bool
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            eventLoop.execute {
                var outHeaders = HTTPHeaders()
                // 关键：AsyncHTTPClient.shared 默认 decompression=.enabled，
                // 收到 content-encoding: gzip/br/deflate 的响应会自动解压 body。
                // 此时若把原 content-encoding 头透传，LS 会试图再解一次 →
                // "gzip: invalid header"。必须把 content-encoding 也当 hop-by-hop 剥掉。
                // content-length 反正下面会按"已解压字节数"重设，不能透传。
                let hopByHop: Set<String> = [
                    "transfer-encoding", "connection", "keep-alive", "trailer",
                    "content-encoding", "content-length",
                ]
                for (n, v) in headers {
                    if hopByHop.contains(n.lowercased()) { continue }
                    outHeaders.add(name: n, value: v)
                }
                outHeaders.replaceOrAdd(name: "content-length", value: String(body.count))
                let respHead = HTTPResponseHead(version: .http1_1, status: status, headers: outHeaders)
                channel.write(NIOAny(HTTPServerResponsePart.head(respHead)), promise: nil)
                var buf = channel.allocator.buffer(capacity: body.count)
                buf.writeBytes(body)
                channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
                channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                    if !keepAlive { channel.close(promise: nil) }
                    cont.resume()
                }
            }
        }
    }

    private static func writeError(
        channel: Channel,
        eventLoop: EventLoop,
        status: HTTPResponseStatus,
        detail: String,
        keepAlive: Bool
    ) async {
        let escaped = detail
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let bodyText = "{\"error\":\"upstream failed\",\"detail\":\"\(escaped)\"}"
        let body = Data(bodyText.utf8)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            eventLoop.execute {
                var headers = HTTPHeaders()
                headers.add(name: "content-type", value: "application/json")
                headers.add(name: "content-length", value: String(body.count))
                let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
                channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                var buf = channel.allocator.buffer(capacity: body.count)
                buf.writeBytes(body)
                channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
                channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                    if !keepAlive { channel.close(promise: nil) }
                    cont.resume()
                }
            }
        }
    }
}

// MARK: - Reset-in 解析

/// 从 429 响应里挖 "Resets in: 2h59m58s" 风格的剩余时间。
/// 优先 header（retry-after / x-resets-in），其次 body 文本。返回 TimeInterval 秒。
/// 解析失败返回 nil → 上层用默认 cooldown_on_rate_limit。
func parseResetIn(headers: HTTPHeaders, body: [UInt8]) -> TimeInterval? {
    // header: Retry-After: 30 (秒) or HTTP-date
    if let v = headers.first(name: "retry-after"), let s = Double(v.trimmingCharacters(in: .whitespaces)) {
        return s
    }
    // body: 解析 "Resets in: 2h59m58s"
    guard let text = String(bytes: body, encoding: .utf8) else { return nil }
    return parseResetInText(text)
}

/// 公开给测试用：从纯文本中解析 "Resets in: 2h59m58s" / "Resets in 1h" / "Resets in: 45m12s" 等。
func parseResetInText(_ text: String) -> TimeInterval? {
    // 找 "Resets in" 后第一段连续 [0-9hms] 字符
    let lower = text.lowercased()
    guard let range = lower.range(of: "resets in") else { return nil }
    let tail = lower[range.upperBound...]
    // 跳过冒号 / 空白
    var iter = tail.makeIterator()
    var captured = ""
    var sawDigit = false
    while let c = iter.next() {
        if c == ":" || c == " " || c == "\t" || c == "\n" {
            if sawDigit { break }
            continue
        }
        if c.isNumber || c == "h" || c == "m" || c == "s" {
            captured.append(c)
            if c.isNumber { sawDigit = true }
        } else {
            if sawDigit { break } else { return nil }
        }
    }
    if captured.isEmpty { return nil }

    var seconds: TimeInterval = 0
    var num: Int = 0
    var any = false
    for c in captured {
        if let d = c.hexDigitValue, c.isNumber {
            num = num * 10 + d
        } else if c == "h" {
            seconds += TimeInterval(num) * 3600
            num = 0
            any = true
        } else if c == "m" {
            seconds += TimeInterval(num) * 60
            num = 0
            any = true
        } else if c == "s" {
            seconds += TimeInterval(num)
            num = 0
            any = true
        }
    }
    // 末尾还有未带后缀的纯数字 → 当秒处理
    if num > 0 {
        seconds += TimeInterval(num)
        any = true
    }
    return any ? seconds : nil
}

private func prefix8(_ s: String) -> String { String(s.prefix(8)) }
