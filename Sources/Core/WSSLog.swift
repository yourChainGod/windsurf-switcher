//
//  WSSLog.swift
//  Core
//
//  持久化日志：
//    - 落盘：~/Library/Logs/com.windsurfswitcher.native/wss.log
//    - 滚动：>10MB 时 rename 为 wss.log.1（保留 1 份历史）
//    - 重定向：dup2 stdout / stderr → 日志文件，所以下列输出全部入档：
//        * FileHandle.standardError.write(...)
//        * print(...)
//        * swift-log 默认 StreamLogHandler.standardOutput / standardError
//        * NIO / async-http-client 的 Logger 输出（若 LoggingSystem.bootstrap 用 stdout/stderr handler）
//    - 提供 wsslog(_:) 时间戳行写入 helper（毫秒精度 + pid + thread）
//
//  幂等：bootstrap 多次调用安全；只在第一次 dup2 + 滚动 + 写 banner。
//  线程安全：fileHandle 在 bootstrap 后只读；wsslog 通过单一 NSLock 保护写顺序。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum WSSLog {
    /// 日志文件路径（公开供调试用）
    public static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.windsurfswitcher.native", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wss.log")
    }()

    /// 历史文件（滚动后命名）
    public static let backupURL: URL = logURL.appendingPathExtension("1")

    /// 滚动阈值：10MB
    public static let rotateThreshold: Int = 10 * 1024 * 1024

    private static let writeLock = NSLock()
    private static var didBootstrap = false
    nonisolated(unsafe) private static var fileHandle: FileHandle?

    /// 时间戳格式化器（一次性，避免每次构造）
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 启动日志系统：滚动 + 打开 + dup2 stdout/stderr。
    /// 多次调用安全（只第一次生效）。建议 App 入口最早处调用。
    public static func bootstrap() {
        writeLock.lock(); defer { writeLock.unlock() }
        if didBootstrap { return }
        didBootstrap = true

        // 1. 滚动（>10MB 移到 .1，覆盖旧 .1）
        let path = logURL.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = (attrs[.size] as? NSNumber)?.intValue,
           size > rotateThreshold
        {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: logURL, to: backupURL)
        }

        // 2. 创建文件 + 打开 append
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            // 兜底：fall back to stderr（不重定向）。后续 wsslog 仍能工作。
            FileHandle.standardError.write(Data("[WSSLog] cannot open log file at \(path)\n".utf8))
            return
        }
        // 移到末尾（append）
        do { try fh.seekToEnd() } catch { _ = fh.seekToEndOfFile() }
        fileHandle = fh

        // 3. dup2 stdout/stderr → log fd
        // 之后所有 print / FileHandle.standardError.write / swift-log 默认 handler 都进文件。
        let logFd = fh.fileDescriptor
        _ = dup2(logFd, fileno(stdout))
        _ = dup2(logFd, fileno(stderr))
        // 行缓冲，避免崩溃前丢日志
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)

        // 4. Banner
        let pid = ProcessInfo.processInfo.processIdentifier
        let ts = timestampFormatter.string(from: Date())
        let bundleVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let buildVer = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let banner = """

        =====================================================================
        WSS log opened ts=\(ts) pid=\(pid) version=\(bundleVer)(\(buildVer))
        path=\(path)
        =====================================================================

        """
        writeRaw(banner)
    }

    /// 时间戳 + 内容写入日志。
    /// 格式：`2026-05-04 16:30:15.123 [tag] message`
    public static func log(_ tag: String, _ message: @autoclosure () -> String) {
        let ts = timestampFormatter.string(from: Date())
        let line = "\(ts) [\(tag)] \(message())\n"
        writeLock.lock()
        defer { writeLock.unlock() }
        writeRaw(line)
    }

    /// 等价于 log(tag, message)。供给 swift-log 的 Handler 用。
    public static func writeLine(_ s: String) {
        let line = s.hasSuffix("\n") ? s : s + "\n"
        writeLock.lock()
        defer { writeLock.unlock() }
        writeRaw(line)
    }

    private static func writeRaw(_ s: String) {
        let data = Data(s.utf8)
        if let fh = fileHandle {
            // 直接写入；FileHandle.write 可能抛异常但极罕见
            do { try fh.write(contentsOf: data) }
            catch { fh.write(data) /* deprecated 但可用做兜底 */ }
        } else {
            FileHandle.standardError.write(data)
        }
    }
}

/// 全局便捷函数：等价于 WSSLog.log(tag, message)
public func wsslog(_ tag: String, _ message: @autoclosure () -> String) {
    WSSLog.log(tag, message())
}
