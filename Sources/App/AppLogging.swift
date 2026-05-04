//
//  AppLogging.swift
//  App
//
//  把 swift-log 接入 WSSLog：所有 Logger 的输出都带时间戳 + level + label，落盘到
//  ~/Library/Logs/com.windsurfswitcher.native/wss.log。
//
//  WSSLog.bootstrap() 已经把 stdout/stderr dup2 到日志文件，所以即便有人用 print/
//  FileHandle.standardError 也会落盘；这里是给 Logger 加结构化前缀。
//
//  调用顺序：WindsurfSwitcherApp.init 第一行 → AppLogging.bootstrap()。
//

import Foundation
import Logging
import Core

/// swift-log 自定义 LogHandler：写入 WSSLog（含时间戳、level、label、metadata）。
struct WSSLogHandler: LogHandler {
    var logLevel: Logger.Level = .debug
    var metadata: Logger.Metadata = [:]
    let label: String

    init(label: String) { self.label = label }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var merged = self.metadata
        if let m = event.metadata { for (k, v) in m { merged[k] = v } }
        let metaStr = merged.isEmpty
            ? ""
            : " " + merged.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        let lvl = event.level.rawValue.uppercased()
        WSSLog.log(lvl, "\(label): \(event.message)\(metaStr)")
    }
}

public enum AppLogging {
    private static var didBootstrap = false
    private static let lock = NSLock()

    public static func bootstrap() {
        lock.lock(); defer { lock.unlock() }
        if didBootstrap { return }
        didBootstrap = true

        // 1. 先打开日志文件 + dup2 stdout/stderr
        WSSLog.bootstrap()

        // 2. 接入 swift-log；保留 .debug 全收。NIO / async-http-client 也用这个 handler。
        LoggingSystem.bootstrap { label in
            var handler = WSSLogHandler(label: label)
            handler.logLevel = .debug
            return handler
        }

        // 3. 写一条启动日志
        WSSLog.log("BOOT", "AppLogging bootstrapped; LoggingSystem → WSSLogHandler")
    }
}
