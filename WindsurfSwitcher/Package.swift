// swift-tools-version: 5.10
import PackageDescription

// Phase 2-A 依赖：
//   - swift-nio 2.x：HTTP/1.1 服务器（cascade-relay 反代基础）
//   - async-http-client 1.x：上游反代客户端，h2 ALPN 自动协商 + 流式响应 body
//   - swift-log：与 NIO 默认 logger 互操作
//
// Phase 2-B 再加 swift-certificates + swift-asn1 + swift-crypto + swift-nio-ssl
//   做 cascade :42201 端口的 TLS 终结。
//
// Phase 3 再加 swift-protobuf 处理 quota rewrite 的部分（手搓 ProtoWire 已能覆盖
// 多数场景，仅复杂嵌套消息可能受益于 codegen）。

let package = Package(
    name: "WindsurfSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "WindsurfClient", targets: ["WindsurfClient"]),
        .library(name: "External", targets: ["External"]),
        .library(name: "Wrapper", targets: ["Wrapper"]),
        .library(name: "Relay", targets: ["Relay"]),
        .executable(name: "wss-cli", targets: ["WSSCLI"]),
        .executable(name: "WindsurfSwitcher", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .target(
            name: "WindsurfClient",
            dependencies: ["Core"],
            path: "Sources/WindsurfClient"
        ),
        .target(
            name: "External",
            dependencies: ["Core"],
            path: "Sources/External"
        ),
        .target(
            name: "Wrapper",
            dependencies: ["Core"],
            path: "Sources/Wrapper"
        ),
        .target(
            name: "Relay",
            dependencies: [
                "Core",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Relay"
        ),
        .executableTarget(
            name: "WSSCLI",
            dependencies: ["Core", "WindsurfClient", "External", "Wrapper"],
            path: "Sources/WSSCLI"
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Core", "WindsurfClient", "External", "Wrapper", "Relay"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "WindsurfClientTests",
            dependencies: ["WindsurfClient", "Core"],
            path: "Tests/WindsurfClientTests"
        ),
        .testTarget(
            name: "WrapperTests",
            dependencies: ["Wrapper", "Core"],
            path: "Tests/WrapperTests"
        ),
        .testTarget(
            name: "RelayTests",
            dependencies: ["Relay"],
            path: "Tests/RelayTests"
        ),
    ]
)
