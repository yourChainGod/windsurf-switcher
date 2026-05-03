// swift-tools-version: 5.10
import PackageDescription

// Relay 依赖：
//   - swift-nio 2.x：HTTP/1.1 服务器（api + inference 明文反代）
//   - async-http-client 1.x：上游反代客户端，h2 ALPN 自动协商 + 流式响应 body
//   - swift-log：与 NIO 默认 logger 互操作
//
// 当前只代理 language server 的 api / inference 明文端口，不做 TLS 终结。
// 因此不需要 swift-nio-ssl / swift-certificates。

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
