// swift-tools-version: 5.10
import PackageDescription

// Phase 1-A：Core + WindsurfClient + External，零外部依赖（纯 Foundation）。
// Phase 2 再加 NIO（HTTP 服务器），Phase 3 再加 swift-certificates / swift-asn1 / swift-crypto。
//
// App target（NSStatusItem + SwiftUI popover）走 Xcode .xcodeproj 单独承载，
// SwiftPM 这边只负责 lib 与 CLI 工具链路。

let package = Package(
    name: "WindsurfSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "WindsurfClient", targets: ["WindsurfClient"]),
        .library(name: "External", targets: ["External"]),
        .executable(name: "wss-cli", targets: ["WSSCLI"]),
    ],
    dependencies: [],
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
        .executableTarget(
            name: "WSSCLI",
            dependencies: ["Core", "WindsurfClient", "External"],
            path: "Sources/WSSCLI"
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
    ]
)
