//
//  Server.swift
//  Relay
//
//  NIO HTTP 反代 + 账号池调度。
//
//  监听 127.0.0.1:<bind>，收到 HTTP/1.1 请求后：
//    - pool != nil → 走调度路径：lease → splice api_key → 转发 → 重试 → record_*
//    - pool == nil → 透传（向后兼容）
//
//  仅服务 api + inference 两个明文端口；cascade 流量走 IDE 直连原版上游。
//
//  内部端点：
//    - GET /__relay/health  → JSON `{ ok, name, stats, pool? }`
//    - GET /__relay/stats   → 原始 stats JSON
//    - GET /__relay/pool    → 池快照（只读 view）
//

import Foundation
import Core
import NIO
import NIOHTTP1
import NIOPosix
import AsyncHTTPClient
import Logging

public struct RelayInstanceConfig: Sendable {
    public let app: WindsurfApp          // stable / next
    public let name: String              // "stable-api" / "next-inference"
    public let host: String
    public let port: UInt16
    public let upstreamBase: String

    public init(app: WindsurfApp = .stable, name: String, host: String, port: UInt16, upstreamBase: String) {
        self.app = app
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
    public let accountSink: AccountSink?
    public let quotaRefreshSink: QuotaRefreshSink?
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
        accountSink: AccountSink?,
        quotaRefreshSink: QuotaRefreshSink?,
        logger: Logger
    ) {
        self.config = config
        self.group = group
        self.httpClient = httpClient
        self.channel = channel
        self.stats = stats
        self.pool = pool
        self.updateSink = updateSink
        self.accountSink = accountSink
        self.quotaRefreshSink = quotaRefreshSink
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
        accountSink: AccountSink? = nil,
        quotaRefreshSink: QuotaRefreshSink? = nil,
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
                        accountSink: accountSink,
                        quotaRefreshSink: quotaRefreshSink,
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
            accountSink: accountSink,
            quotaRefreshSink: quotaRefreshSink,
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
    private let accountSink: AccountSink?
    private let quotaRefreshSink: QuotaRefreshSink?
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
        accountSink: AccountSink? = nil,
        quotaRefreshSink: QuotaRefreshSink? = nil,
        logger: Logger
    ) {
        self.config = config
        self.httpClient = httpClient
        self.stats = stats
        self.pool = pool
        self.updateSink = updateSink
        self.accountSink = accountSink
        self.quotaRefreshSink = quotaRefreshSink
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
                handleInternal(context: context, head: head, body: bodyBytes)
                return
            }

            // GetPlanStatus 劫持：永远返回伪造的满血响应，不打上游
            if head.uri.contains("/exa.seat_management_pb.SeatManagementService/GetPlanStatus") {
                handleFakePlanStatus(context: context, head: head)
                return
            }

            // CheckUserMessageRateLimit 劫持：永远返回"未限流"
            // windsurf 后端按 user_id 维护消息速率限流——切号无效，必须本地伪造响应。
            if head.uri.contains("/CheckUserMessageRateLimit") {
                handleFakeCheckRateLimit(context: context, head: head)
                return
            }

            // 路由：
            //   pool == nil       → 纯透传
            //   isGetUserJwt      → forwardForGetUserJwt（lease 选号 + 强制轮转 + 5-attempt）
            //   其它              → forwardWithActive（直接 splice active 号 token，无 lease 无 retry）
            //
            // 设计原则：只有 GetUserJwt 真正切换 LS 客户端账号；其它 RPC（telemetry /
            // GetUserStatus / Record* / GetChatMessage）应严格对齐 LS 持有的 JWT，
            // 不再"per-request 抢号"——避免 12 个 RPC 命中 12 个号的乱飘。
            guard let pool = self.pool else {
                forwardPassthrough(context: context, head: head, body: bodyBytes)
                return
            }
            if head.uri.contains("/exa.auth_pb.AuthService/GetUserJwt") {
                forwardForGetUserJwt(context: context, head: head, body: bodyBytes, pool: pool)
            } else {
                forwardWithActive(context: context, head: head, body: bodyBytes, pool: pool)
            }
        }
    }

    // MARK: CheckUserMessageRateLimit 伪造（不打上游）
    //
    // 字段定义（从 windsurf IDE chat-client/index.js 抓出 protobuf schema）：
    //   exa.language_server_pb.CheckUserMessageRateLimitResponse
    //     field 1: has_capacity (bool)        ← 必须 true，否则 IDE 判限流
    //     field 2: message (string)
    //     field 3: messages_remaining (int32)
    //     field 4: max_messages (int32)
    //     field 5: resets_in_seconds (int64)
    //
    // 注意：旧实现返回空 body 让 has_capacity 走默认 false，反而触发限流——必须显式 set true。

    private func handleFakeCheckRateLimit(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let started = DispatchTime.now()
        let stats = self.stats
        let logger = self.logger
        let chConfig = self.config
        let channel = context.channel
        let eventLoop = context.eventLoop
        // race fix：必须在进 Task 之前拷贝 keepAlive，否则下一个 .head 会覆盖此字段
        let keepAlive = self.keepAlive
        Task {
            let body = QuotaRewrite.buildFakeCheckRateLimitBody()
            let bytes = [UInt8](body)
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/proto")
            headers.add(name: "content-length", value: String(bytes.count))
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            await stats.record(RecentRPC(path: head.uri, status: 200, durationMillis: Int(elapsed)))
            logger.info("[\(chConfig.name)] intercepted CheckUserMessageRateLimit → has_capacity=true (\(bytes.count)B)")
            await Self.writeBack(channel: channel, eventLoop: eventLoop, status: .ok, headers: headers, body: bytes, keepAlive: keepAlive)
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
        let keepAlive = self.keepAlive  // race fix：拷贝再进 Task
        Task {
            let body = QuotaRewrite.buildFakePlanStatusBody()
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/proto")
            headers.add(name: "content-length", value: String(body.count))
            let bytes = [UInt8](body)
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            await stats.record(RecentRPC(path: head.uri, status: 200, durationMillis: Int(elapsed)))
            logger.info("[\(chConfig.name)] intercepted GetPlanStatus → fake unlimited (\(bytes.count)B)")
            await Self.writeBack(channel: channel, eventLoop: eventLoop, status: .ok, headers: headers, body: bytes, keepAlive: keepAlive)
        }
    }

    // MARK: Internal endpoints

    private func handleInternal(context: ChannelHandlerContext, head: HTTPRequestHead, body: [UInt8]) {
        let path = head.uri
        let method = head.method

        // POST /__relay/accounts —— 外部入号 API
        if path == "/__relay/accounts" && method == .POST {
            handleAddAccount(context: context, body: body)
            return
        }

        let promise = context.eventLoop.makePromise(of: Void.self)
        let keepAlive = self.keepAlive  // race fix：拷贝再进 Task
        Task {
            let snap = await stats.snapshot()
            let payload: [String: Any]
            switch path {
            case "/__relay/health":
                var body: [String: Any] = [
                    "ok": true,
                    "app": config.app.rawValue,
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
                            "accountId": rpc.accountId ?? NSNull(),
                            "email": rpc.email ?? NSNull(),
                        ]
                    },
                ]
            case "/__relay/pool":
                if let pool = self.pool {
                    let entries = await pool.snapshot()
                    let active = await pool.getCurrentActiveAccount(app: config.app)
                    let activeByApp = await pool.getCurrentActiveAccounts()
                    payload = [
                        "size": entries.count,
                        "currentActive": active ?? NSNull(),
                        "currentActiveByApp": Dictionary(
                            uniqueKeysWithValues: activeByApp.map { ($0.key.rawValue, $0.value) }
                        ),
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
            self.writeJSON(context: context, status: .ok, body: body, keepAlive: keepAlive, promise: promise)
        }
        _ = promise.futureResult
    }

    /// POST /__relay/accounts —— 外部 curl 灌号入 store。
    /// body: JSON `{"session_token":"...","label":"..."?}`（兼容 sessionToken alias）
    /// 返回 200 `{ok, accountId, added}`；400/500/501 错码对应 BadRequest / sink 错 / 未配置 sink。
    private func handleAddAccount(context: ChannelHandlerContext, body: [UInt8]) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        let sink = self.accountSink
        let logger = self.logger
        let chName = self.config.name
        let keepAlive = self.keepAlive  // race fix：拷贝再进 Task
        Task {
            guard let sink = sink else {
                let resp: [String: Any] = ["ok": false, "error": "no AccountSink configured"]
                let data = (try? JSONSerialization.data(withJSONObject: resp, options: [.sortedKeys])) ?? Data("{}".utf8)
                self.writeJSON(context: context, status: .notImplemented, body: data, keepAlive: keepAlive, promise: promise)
                return
            }
            // 解析 JSON
            guard !body.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(body), options: []),
                  let dict = obj as? [String: Any]
            else {
                let resp: [String: Any] = ["ok": false, "error": "invalid JSON body"]
                let data = (try? JSONSerialization.data(withJSONObject: resp, options: [.sortedKeys])) ?? Data("{}".utf8)
                self.writeJSON(context: context, status: .badRequest, body: data, keepAlive: keepAlive, promise: promise)
                return
            }
            let token = (dict["session_token"] as? String) ?? (dict["sessionToken"] as? String) ?? ""
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let resp: [String: Any] = ["ok": false, "error": "session_token empty"]
                let data = (try? JSONSerialization.data(withJSONObject: resp, options: [.sortedKeys])) ?? Data("{}".utf8)
                self.writeJSON(context: context, status: .badRequest, body: data, keepAlive: keepAlive, promise: promise)
                return
            }
            let label = (dict["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLabel: String? = (label?.isEmpty == false) ? label : nil

            let result = await sink.add(token: trimmed, label: normalizedLabel)
            switch result {
            case .success(let (id, wasNew)):
                logger.info("[\(chName)] POST /__relay/accounts → \(wasNew ? "added" : "updated") acct=\(prefix8(id))")
                let resp: [String: Any] = [
                    "ok": true,
                    "accountId": id,
                    "added": wasNew,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: resp, options: [.sortedKeys])) ?? Data("{}".utf8)
                self.writeJSON(context: context, status: .ok, body: data, keepAlive: keepAlive, promise: promise)
            case .failure(let err):
                logger.warning("[\(chName)] POST /__relay/accounts FAILED: \(err.message)")
                let resp: [String: Any] = ["ok": false, "error": err.message]
                let data = (try? JSONSerialization.data(withJSONObject: resp, options: [.sortedKeys])) ?? Data("{}".utf8)
                self.writeJSON(context: context, status: .internalServerError, body: data, keepAlive: keepAlive, promise: promise)
            }
        }
        _ = promise.futureResult
    }

    private func writeJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, keepAlive: Bool, promise: EventLoopPromise<Void>) {
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
            if !keepAlive {
                context.close(promise: nil)
            }
        }
    }

    // MARK: GetUserJwt 路径（lease 选号 + 强制轮转 + 5-attempt）

    /// 唯一仍走 lease 的路径——GetUserJwt 是"播种"调用，LS 拿到 JWT 后缓存
    /// 5–15min，所以必须从池里精挑最强号；同时把上次 active 加入 excludes
    /// 强制每次换号。成功后 setCurrentActiveAccount → 后续非 JWT RPC 全部
    /// splice 此号 token（forwardWithActive）。
    private func forwardForGetUserJwt(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: [UInt8],
        pool: Pool
    ) {
        let started = DispatchTime.now()
        let upstreamURL = config.upstreamBase + head.uri
        let stats = self.stats
        let logger = self.logger
        let client = self.httpClient
        let chConfig = self.config
        let eventLoop = context.eventLoop
        let channel = context.channel
        let keepAlive = self.keepAlive
        let sink = self.updateSink
        let quotaSink = self.quotaRefreshSink

        Task {
            var excludes: [String] = []
            var lastError: Error?
            var lastResp: (status: HTTPResponseStatus, headers: HTTPHeaders, body: [UInt8])?

            let rotationExcludes = await pool.rotationExcludes(app: chConfig.app)
            if !rotationExcludes.isEmpty {
                excludes.append(contentsOf: rotationExcludes)
                let shown = rotationExcludes.map { prefix8($0) }.joined(separator: ",")
                logger.info("[\(chConfig.name)] GetUserJwt force-rotate: excluding active acct(s)=\(shown)")
            }

            for attempt in 1...HTTPProxyHandler.maxAttempts {
                let lease: Lease
                do {
                    lease = try await pool.lease(excludes: excludes)
                } catch let err {
                    lastError = err
                    if let r = lastResp {
                        await Self.writeBack(channel: channel, eventLoop: eventLoop, status: r.status, headers: r.headers, body: r.body, keepAlive: keepAlive)
                    } else {
                        await Self.writeError(channel: channel, eventLoop: eventLoop, status: .badGateway, detail: "no usable account: \(err)", keepAlive: keepAlive)
                    }
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    await stats.record(RecentRPC(path: head.uri, status: 502, durationMillis: Int(elapsed)))
                    return
                }
                let accountId = lease.accountId
                let token = lease.token

                // splice api_key（容错，参考旧 forwardWithPool）
                var requestBody = body
                let tokenBytes = Array(token.utf8)
                if !body.isEmpty {
                    do {
                        try ProtoRewrite.rewriteApiKey(&requestBody, newToken: tokenBytes)
                    } catch ProtoRewriteError.notMetadataFirst {
                    } catch ProtoRewriteError.noApiKeyField {
                    } catch ProtoRewriteError.tokenLengthMismatch(let exp, let got) {
                        logger.warning("[\(chConfig.name)] token length mismatch (expected \(exp), got \(got)); body untouched")
                    } catch {
                        logger.warning("[\(chConfig.name)] proto rewrite failed: \(error); body untouched")
                    }
                }

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
                    let respBytes = respBody.getBytes(at: respBody.readerIndex, length: respBody.readableBytes) ?? []
                    let statusCode = Int(resp.status.code)

                    // 4xx/5xx → 记账 + ban_signal + 入 excludes 重试
                    if let kind = FailureKind.fromStatus(statusCode) {
                        var override: TimeInterval? = nil
                        if kind == .rateLimit {
                            override = parseResetIn(headers: resp.headers, body: respBytes)
                        }
                        let update = await pool.recordFailureWithCooldown(accountId, kind: kind, cooldownOverride: override)
                        if let upd = update, let s = sink { await s.apply(upd) }

                        if kind == .auth {
                            let text = BanSignal.extractText(respBytes, maxBytes: 8 * 1024)
                            if BanSignal.matches(text) {
                                let banUpd = await pool.recordBanSignal(accountId)
                                if let upd = banUpd, let s = sink { await s.apply(upd) }
                                logger.warning("[\(chConfig.name)] ban_signal hit acct=\(prefix8(accountId)) text=\(text.prefix(120))")
                            }
                        }

                        lastResp = (resp.status, resp.headers, respBytes)
                        excludes.append(accountId)
                        logger.info("[\(chConfig.name)] GetUserJwt attempt \(attempt) acct=\(prefix8(accountId)) → \(statusCode) (\(kind))")
                        continue
                    }

                    // 200 + connect_error
                    let contentType = resp.headers.first(name: "content-type") ?? ""
                    if let appErr = ConnectError.detect(headers: resp.headers, body: respBytes, contentType: contentType) {
                        let kind: FailureKind
                        let override: TimeInterval? = appErr.resetIn
                        if ConnectError.isRateLimit(appErr.message) {
                            kind = .rateLimit
                        } else if appErr.code?.hasPrefix("grpc:7") == true || appErr.message.lowercased().contains("unauthenticated") || appErr.message.lowercased().contains("permission") {
                            kind = .auth
                        } else {
                            kind = .transient
                        }
                        let update = await pool.recordFailureWithCooldown(accountId, kind: kind, cooldownOverride: override)
                        if let upd = update, let s = sink { await s.apply(upd) }
                        if kind == .auth && BanSignal.matches(appErr.message) {
                            let banUpd = await pool.recordBanSignal(accountId)
                            if let upd = banUpd, let s = sink { await s.apply(upd) }
                        }
                        lastResp = (resp.status, resp.headers, respBytes)
                        excludes.append(accountId)
                        logger.info("[\(chConfig.name)] GetUserJwt attempt \(attempt) acct=\(prefix8(accountId)) 200+app_err code=\(appErr.code ?? "?") (\(kind))")
                        continue
                    }

                    // 2xx 成功 → setCurrentActiveAccount + recordSuccess
                    await pool.setCurrentActiveAccount(accountId, app: chConfig.app)
                    logger.info("[\(chConfig.name)] GetUserJwt → set active acct=\(prefix8(accountId))")
                    let updateOk = await pool.recordSuccess(accountId)
                    if let upd = updateOk, let s = sink { await s.apply(upd) }
                    if let qsink = quotaSink {
                        Task { await qsink.requestRefresh(accountId: accountId, force: true) }
                    }
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    await stats.record(RecentRPC(path: head.uri, accountId: accountId, email: lease.email, status: statusCode, durationMillis: Int(elapsed)))
                    await Self.writeBack(channel: channel, eventLoop: eventLoop, status: resp.status, headers: resp.headers, body: respBytes, keepAlive: keepAlive)
                    return
                } catch let err {
                    let update = await pool.recordFailure(accountId, kind: .transient)
                    if let upd = update, let s = sink { await s.apply(upd) }
                    excludes.append(accountId)
                    lastError = err
                    logger.warning("[\(chConfig.name)] GetUserJwt attempt \(attempt) acct=\(prefix8(accountId)) network err: \(err)")
                    continue
                }
            } // end for

            // 5 次都失败：lastResp 兜底，否则 502
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            if let r = lastResp {
                await stats.record(RecentRPC(path: head.uri, status: Int(r.status.code), durationMillis: Int(elapsed)))
                await Self.writeBack(channel: channel, eventLoop: eventLoop, status: r.status, headers: r.headers, body: r.body, keepAlive: keepAlive)
            } else {
                await stats.record(RecentRPC(path: head.uri, status: 502, durationMillis: Int(elapsed)))
                let detail = lastError.map { "\($0)" } ?? "all attempts exhausted"
                await Self.writeError(channel: channel, eventLoop: eventLoop, status: .badGateway, detail: detail, keepAlive: keepAlive)
            }
        }
    }

    // MARK: 非 GetUserJwt 路径（直接 splice active 号 token；GetChatMessage rate-limit 可定向重试）

    /// 所有非 GetUserJwt 的 pool 路径都走这里：取 currentActive snapshot →
    /// splice api_key → 发上游 → 记账到 active。普通失败不 retry——
    /// LS 仍持有 active 号的 JWT 在用，换号没意义。
    /// 例外：GetChatMessage 的模型 rate-limit/permission_denied 会直接展示给用户，
    /// 这里排除当前号后持续重试有额度账号，成功后把 active 锚到新号；耗尽也不回放原始限流帧。
    ///
    /// active 为 nil（fresh boot 还没首个 GetUserJwt） → 走 forwardPassthrough。
    private func forwardWithActive(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: [UInt8],
        pool: Pool
    ) {
        let started = DispatchTime.now()
        let upstreamURL = config.upstreamBase + head.uri
        let stats = self.stats
        let logger = self.logger
        let client = self.httpClient
        let chConfig = self.config
        let eventLoop = context.eventLoop
        let channel = context.channel
        let keepAlive = self.keepAlive
        let sink = self.updateSink
        let quotaSink = self.quotaRefreshSink

        Task {
            guard let active = await pool.getActiveSnapshot(app: chConfig.app) else {
                // active 未设：不要伪造 401。Windsurf 对 GetUserStatus 的
                // Unauthenticated 走登录失败路径，不会可靠触发 GetUserJwt。
                // 直接 passthrough，让 LS 自己的启动 / Cascade 流程决定何时拿 JWT。
                let elapsed0 = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                logger.info("[\(chConfig.name)] no active account → passthrough \(head.uri) (\(elapsed0)ms prep)")
                self.forwardPassthrough(context: context, head: head, body: body)
                return
            }
            let accountId = active.accountId

            let refreshQuotaAfterSuccess = head.uri.contains("/GetChatMessage")

            // splice
            var requestBody = body
            let tokenBytes = Array(active.token.utf8)
            if !body.isEmpty {
                do {
                    try ProtoRewrite.rewriteApiKey(&requestBody, newToken: tokenBytes)
                } catch ProtoRewriteError.notMetadataFirst {
                } catch ProtoRewriteError.noApiKeyField {
                } catch ProtoRewriteError.tokenLengthMismatch(let exp, let got) {
                    logger.warning("[\(chConfig.name)] token length mismatch (expected \(exp), got \(got)); body untouched")
                } catch {
                    logger.warning("[\(chConfig.name)] proto rewrite failed: \(error); body untouched")
                }
            }

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

                // 4xx/5xx → 记账到 active；不 retry，让 LS 自然感知失败
                if let kind = FailureKind.fromStatus(statusCode) {
                    var override: TimeInterval? = nil
                    if kind == .rateLimit {
                        override = parseResetIn(headers: resp.headers, body: respBytes)
                    }
                    let update = await pool.recordFailureWithCooldown(accountId, kind: kind, cooldownOverride: override)
                    if let upd = update, let s = sink { await s.apply(upd) }
                    if kind == .auth {
                        let text = BanSignal.extractText(respBytes, maxBytes: 8 * 1024)
                        if BanSignal.matches(text) {
                            let banUpd = await pool.recordBanSignal(accountId)
                            if let upd = banUpd, let s = sink { await s.apply(upd) }
                            logger.warning("[\(chConfig.name)] ban_signal hit acct=\(prefix8(accountId)) text=\(text.prefix(120))")
                        }
                    }
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    await stats.record(RecentRPC(path: head.uri, accountId: accountId, email: active.email, status: statusCode, durationMillis: Int(elapsed)))
                    await Self.writeBack(channel: channel, eventLoop: eventLoop, status: resp.status, headers: resp.headers, body: respBytes, keepAlive: keepAlive)
                    return
                }

                // 200 + connect_error
                let contentType = resp.headers.first(name: "content-type") ?? ""
                if let appErr = ConnectError.detect(headers: resp.headers, body: respBytes, contentType: contentType) {
                    let kind: FailureKind
                    let override: TimeInterval? = appErr.resetIn
                    if ConnectError.isRateLimit(appErr.message) {
                        kind = .rateLimit
                    } else if appErr.code?.hasPrefix("grpc:7") == true || appErr.message.lowercased().contains("unauthenticated") || appErr.message.lowercased().contains("permission") {
                        kind = .auth
                    } else {
                        kind = .transient
                    }
                    let update = await pool.recordFailureWithCooldown(accountId, kind: kind, cooldownOverride: override)
                    if let upd = update, let s = sink { await s.apply(upd) }
                    if kind == .auth && BanSignal.matches(appErr.message) {
                        let banUpd = await pool.recordBanSignal(accountId)
                        if let upd = banUpd, let s = sink { await s.apply(upd) }
                    }
                    if kind == .rateLimit && refreshQuotaAfterSuccess {
                        var excludes = Set(await pool.rotationExcludes(app: chConfig.app))
                        excludes.insert(accountId)
                        var retryCount = 0
                        while true {
                            let retryLease: Lease
                            do {
                                retryLease = try await pool.lease(excludes: Array(excludes))
                            } catch {
                                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                                await stats.record(RecentRPC(path: head.uri, accountId: accountId, email: active.email, status: 503, durationMillis: Int(elapsed)))
                                logger.warning("[\(chConfig.name)] GetChatMessage rate-limit recovery exhausted acct=\(prefix8(accountId)) retries=\(retryCount): \(error)")
                                await Self.writeError(
                                    channel: channel,
                                    eventLoop: eventLoop,
                                    status: .serviceUnavailable,
                                    detail: "GetChatMessage recovery exhausted: no usable account",
                                    keepAlive: keepAlive
                                )
                                return
                            }

                            let retryAccountId = retryLease.accountId
                            excludes.insert(retryAccountId)
                            retryCount += 1

                            do {
                                var retryBody = body
                                try ProtoRewrite.rewriteApiKey(&retryBody, newToken: Array(retryLease.token.utf8))

                                var retryReq = HTTPClientRequest(url: upstreamURL)
                                retryReq.method = .RAW(value: head.method.rawValue)
                                for (name, value) in head.headers {
                                    if dropHeaders.contains(name.lowercased()) { continue }
                                    retryReq.headers.add(name: name, value: value)
                                }
                                if !retryBody.isEmpty {
                                    retryReq.body = .bytes(ByteBuffer(bytes: retryBody))
                                }

                                let retryResp = try await client.execute(retryReq, timeout: .seconds(120))
                                let retryRespBody = try await retryResp.body.collect(upTo: 64 * 1024 * 1024)
                                let retryBytes = retryRespBody.getBytes(
                                    at: retryRespBody.readerIndex,
                                    length: retryRespBody.readableBytes
                                ) ?? []
                                let retryStatusCode = Int(retryResp.status.code)

                                if let retryKind = FailureKind.fromStatus(retryStatusCode) {
                                    let retryOverride = retryKind == .rateLimit
                                        ? parseResetIn(headers: retryResp.headers, body: retryBytes)
                                        : nil
                                    let retryUpd = await pool.recordFailureWithCooldown(
                                        retryAccountId,
                                        kind: retryKind,
                                        cooldownOverride: retryOverride
                                    )
                                    if let upd = retryUpd, let s = sink { await s.apply(upd) }
                                    logger.info("[\(chConfig.name)] GetChatMessage retry acct=\(prefix8(retryAccountId)) → \(retryStatusCode) (\(retryKind)); trying next")
                                    continue
                                }

                                let retryContentType = retryResp.headers.first(name: "content-type") ?? ""
                                if let retryErr = ConnectError.detect(headers: retryResp.headers, body: retryBytes, contentType: retryContentType) {
                                    let retryKind: FailureKind = ConnectError.isRateLimit(retryErr.message)
                                        ? .rateLimit
                                        : ((retryErr.code?.hasPrefix("grpc:7") == true || retryErr.message.lowercased().contains("permission")) ? .auth : .transient)
                                    let retryUpd = await pool.recordFailureWithCooldown(
                                        retryAccountId,
                                        kind: retryKind,
                                        cooldownOverride: retryErr.resetIn
                                    )
                                    if let upd = retryUpd, let s = sink { await s.apply(upd) }
                                    logger.info("[\(chConfig.name)] GetChatMessage retry acct=\(prefix8(retryAccountId)) 200+app_err code=\(retryErr.code ?? "?") (\(retryKind)); trying next")
                                    continue
                                }

                                await pool.setCurrentActiveAccount(retryAccountId, app: chConfig.app)
                                let retryOk = await pool.recordSuccess(retryAccountId)
                                if let upd = retryOk, let s = sink { await s.apply(upd) }
                                if let qsink = quotaSink {
                                    Task { await qsink.requestRefresh(accountId: retryAccountId, force: true) }
                                }
                                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                                await stats.record(RecentRPC(path: head.uri, accountId: retryAccountId, email: retryLease.email, status: retryStatusCode, durationMillis: Int(elapsed)))
                                logger.info("[\(chConfig.name)] GetChatMessage rate-limit recovered acct=\(prefix8(accountId)) → acct=\(prefix8(retryAccountId)) after \(retryCount) retry")
                                await Self.writeBack(channel: channel, eventLoop: eventLoop, status: retryResp.status, headers: retryResp.headers, body: retryBytes, keepAlive: keepAlive)
                                return
                            } catch {
                                let retryUpd = await pool.recordFailureWithCooldown(
                                    retryAccountId,
                                    kind: .transient,
                                    cooldownOverride: nil
                                )
                                if let upd = retryUpd, let s = sink { await s.apply(upd) }
                                logger.warning("[\(chConfig.name)] GetChatMessage retry failed acct=\(prefix8(retryAccountId)); trying next: \(error)")
                                continue
                            }
                        }
                    }
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    await stats.record(RecentRPC(path: head.uri, accountId: accountId, email: active.email, status: statusCode, durationMillis: Int(elapsed)))
                    logger.info("[\(chConfig.name)] active 200+app_err acct=\(prefix8(accountId)) code=\(appErr.code ?? "?") (\(kind))")
                    await Self.writeBack(channel: channel, eventLoop: eventLoop, status: resp.status, headers: resp.headers, body: respBytes, keepAlive: keepAlive)
                    return
                }

                // 2xx 成功：GetUserStatus 路径改写 quota
                if head.uri.contains("/exa.seat_management_pb.SeatManagementService/GetUserStatus") {
                    do {
                        let rewritten = try QuotaRewrite.rewriteUserStatusQuota(Data(respBytes))
                        respBytes = [UInt8](rewritten)
                        respHeaders.remove(name: "content-length")
                        respHeaders.add(name: "content-length", value: String(respBytes.count))
                        logger.info("[\(chConfig.name)] rewrote GetUserStatus quota (\(respBytes.count)B) acct=\(prefix8(accountId))")
                    } catch {
                        logger.warning("[\(chConfig.name)] GetUserStatus rewrite failed: \(error); passthrough")
                    }
                }

                let updateOk = await pool.recordSuccess(accountId)
                if let upd = updateOk, let s = sink { await s.apply(upd) }
                if refreshQuotaAfterSuccess, let qsink = quotaSink {
                    Task { await qsink.requestRefresh(accountId: accountId, force: true) }
                }
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                await stats.record(RecentRPC(path: head.uri, accountId: accountId, email: active.email, status: statusCode, durationMillis: Int(elapsed)))
                await Self.writeBack(channel: channel, eventLoop: eventLoop, status: resp.status, headers: respHeaders, body: respBytes, keepAlive: keepAlive)
            } catch let err {
                let update = await pool.recordFailure(accountId, kind: .transient)
                if let upd = update, let s = sink { await s.apply(upd) }
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                logger.warning("[\(chConfig.name)] active network err acct=\(prefix8(accountId)) on \(head.uri): \(err)")
                await stats.record(RecentRPC(path: head.uri, accountId: accountId, email: active.email, status: 502, durationMillis: Int(elapsed)))
                await Self.writeError(channel: channel, eventLoop: eventLoop, status: .badGateway, detail: "\(err)", keepAlive: keepAlive)
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
        let keepAlive = self.keepAlive  // race fix：拷贝再进 Task

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
                await Self.writeBack(channel: channel, eventLoop: eventLoop, status: resp.status, headers: resp.headers, body: respBytes, keepAlive: keepAlive)
            } catch {
                let detailed = "\(error)"
                logger.warning("upstream \(chConfig.name) [\(upstreamURL)] failed: \(detailed)")
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                await stats.record(RecentRPC(path: head.uri, status: 502, durationMillis: Int(elapsed)))
                await Self.writeError(channel: channel, eventLoop: eventLoop, status: .badGateway, detail: detailed, keepAlive: keepAlive)
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
