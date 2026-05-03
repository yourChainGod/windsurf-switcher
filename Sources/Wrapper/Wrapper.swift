//
//  Wrapper.swift
//  Wrapper
//
//  LS binary 替换：检测状态机 / 安装 / 卸载（直译 src-tauri/src/wrapper.rs）。
//
//  路径：<App>/Contents/Resources/app/extensions/windsurf/bin/language_server_macos_arm
//
//  状态：
//    - Missing: LS 二进制不存在
//    - Pristine: 真 binary（Mach-O magic 头），可装 wrapper
//    - InstalledMatching: 已装 wrapper 且端口与当前 relay 一致
//    - InstalledStale: 已装 wrapper 但端口已陈旧（需刷新）
//    - Foreign: 文件存在但非 Mach-O 也非吾们的 wrapper（拒绝覆盖）
//
//  写权限：先尝试普通 fs 操作；EACCES 时调 osascript 提权。
//

import Foundation
import Core

public enum WrapperState: String, Codable, Sendable, Equatable {
    case missing = "Missing"
    case pristine = "Pristine"
    case installedMatching = "InstalledMatching"
    case installedStale = "InstalledStale"
    case foreign = "Foreign"
}

public struct WrapperStatus: Equatable, Sendable {
    public let app: WindsurfApp
    public let lsPath: URL
    public let realBackupPath: URL
    public let state: WrapperState
    public let relayPort: UInt16
    public let inferencePort: UInt16
}

public enum WrapperError: Error, CustomStringConvertible {
    case lsNotFound(URL)
    case foreignContent(URL)
    case backupAlreadyExists(URL)
    case backupMissing(URL)
    case shellFailed(stderr: String)
    case osascriptFailed(stderr: String)

    public var description: String {
        switch self {
        case .lsNotFound(let p): return "LS binary not found at \(p.path); is the app installed?"
        case .foreignContent(let p): return "\(p.path) is neither Mach-O nor our wrapper; refusing to overwrite"
        case .backupAlreadyExists(let p): return "\(p.path) already exists but main binary is still pristine"
        case .backupMissing(let p): return "wrapper installed but \(p.path) missing; reinstall app to recover"
        case .shellFailed(let s): return "shell failed: \(s)"
        case .osascriptFailed(let s): return "osascript privileged install failed: \(s)"
        }
    }
}

/// Mach-O 64-bit 魔数（little-endian / big-endian 各识别一种，arm64 是 LE）。
private let machoMagicLE: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]
private let machoMagicBE: [UInt8] = [0xFE, 0xED, 0xFA, 0xCF]

public struct Wrapper {
    public let app: WindsurfApp
    public let relayPort: UInt16
    public let inferencePort: UInt16

    public init(app: WindsurfApp, relayPort: UInt16, inferencePort: UInt16) {
        self.app = app
        self.relayPort = relayPort
        self.inferencePort = inferencePort
    }

    public var lsPath: URL { app.lsBinaryPath }
    public var realBackupPath: URL { app.lsBinaryRealBackupPath }

    public var expectedScript: String {
        WrapperScript.render(relayPort: relayPort, inferencePort: inferencePort)
    }

    /// 不修改任何文件，仅诊断当前状态。
    public func status() -> WrapperStatus {
        WrapperStatus(
            app: app,
            lsPath: lsPath,
            realBackupPath: realBackupPath,
            state: detectState(),
            relayPort: relayPort,
            inferencePort: inferencePort
        )
    }

    public func detectState() -> WrapperState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: lsPath.path) else { return .missing }

        guard let head = readFirstBytes(at: lsPath, count: 4), head.count == 4 else {
            return .foreign
        }
        let bytes = [UInt8](head)
        if bytes == machoMagicLE || bytes == machoMagicBE {
            return .pristine
        }
        // 不是 Mach-O；看是不是吾们的 wrapper
        guard let body = try? String(contentsOf: lsPath, encoding: .utf8) else {
            return .foreign
        }
        if !body.contains(WrapperScript.signature) {
            return .foreign
        }
        return body == expectedScript ? .installedMatching : .installedStale
    }

    /// 安装：备份原 binary 为 .real，写入 wrapper 脚本。已 InstalledMatching → 幂等返回。
    @discardableResult
    public func install() throws -> WrapperStatus {
        switch detectState() {
        case .installedMatching:
            return status()
        case .missing:
            throw WrapperError.lsNotFound(lsPath)
        case .foreign:
            throw WrapperError.foreignContent(lsPath)
        case .pristine:
            try installFromPristine()
        case .installedStale:
            try installRefreshOnly()
        }
        return status()
    }

    /// 卸载：把 .real 移回原位（覆盖 wrapper）。Pristine → 幂等返回。
    @discardableResult
    public func uninstall() throws -> WrapperStatus {
        switch detectState() {
        case .pristine, .missing:
            return status()
        case .foreign:
            throw WrapperError.foreignContent(lsPath)
        case .installedMatching, .installedStale:
            if !FileManager.default.fileExists(atPath: realBackupPath.path) {
                throw WrapperError.backupMissing(realBackupPath)
            }
            try runWithElevation(script: """
                mv \(shellQuote(realBackupPath.path)) \(shellQuote(lsPath.path))
                """)
        }
        return status()
    }

    // MARK: - Private installers

    private func installFromPristine() throws {
        if FileManager.default.fileExists(atPath: realBackupPath.path) {
            throw WrapperError.backupAlreadyExists(realBackupPath)
        }
        try runWithElevation(script: writeScriptShell(includeMv: true))
    }

    private func installRefreshOnly() throws {
        if !FileManager.default.fileExists(atPath: realBackupPath.path) {
            throw WrapperError.backupMissing(realBackupPath)
        }
        try runWithElevation(script: writeScriptShell(includeMv: false))
    }

    /// 生成一段 sh 脚本：写入 wrapper、chmod、清 quarantine。
    /// includeMv=true 时先 mv 原 binary → .real。
    private func writeScriptShell(includeMv: Bool) -> String {
        // wrapper 内容写到一个临时 file（避免 heredoc 与 osascript 引号嵌套地狱），
        // 然后 mv 到目标位置；与旧版 rust 代码用 heredoc 相同语义但更稳。
        let tmp = "/tmp/wss-wrapper-\(UUID().uuidString.prefix(8)).sh"
        let body = expectedScript
        // base64 安全传递避免特殊字符
        let b64 = Data(body.utf8).base64EncodedString()
        let src = shellQuote(lsPath.path)
        let dst = shellQuote(realBackupPath.path)
        let mv = includeMv ? "mv \(src) \(dst) && " : ""
        return """
            \(mv)printf '%s' '\(b64)' | base64 -D > \(shellQuote(tmp)) && mv \(shellQuote(tmp)) \(src) && chmod +x \(src) && /usr/bin/xattr -dr com.apple.quarantine \(src) 2>/dev/null; true
            """
    }

    // MARK: - Privileged execution

    /// 先尝试普通 sh -c，权限不足再走 osascript admin privileges。
    private func runWithElevation(script: String) throws {
        let direct = runShell(script)
        if direct.exitCode == 0 { return }
        let stderrLower = direct.stderr.lowercased()
        let needsElev = stderrLower.contains("permission denied")
            || stderrLower.contains("operation not permitted")
            || stderrLower.contains("read-only file system")
        if !needsElev {
            throw WrapperError.shellFailed(stderr: direct.stderr.isEmpty ? direct.stdout : direct.stderr)
        }
        // osascript：do shell script "..." with administrator privileges
        // 转义 " 和 \
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", osa]
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WrapperError.osascriptFailed(stderr: err)
        }
    }

    /// 同时安装两个 app 的 wrapper。osascript 弹一次密码框完成两份替换。
    public static func installBoth(relayPort: UInt16, inferencePort: UInt16) throws -> [WrapperStatus] {
        try installBoth(
            stableRelayPort: relayPort,
            stableInferencePort: inferencePort,
            nextRelayPort: relayPort,
            nextInferencePort: inferencePort
        )
    }

    /// 同时安装两个 app 的 wrapper；stable/next 可以使用不同端口以隔离 active JWT。
    public static func installBoth(
        stableRelayPort: UInt16,
        stableInferencePort: UInt16,
        nextRelayPort: UInt16,
        nextInferencePort: UInt16
    ) throws -> [WrapperStatus] {
        let stable = Wrapper(app: .stable, relayPort: stableRelayPort, inferencePort: stableInferencePort)
        let next = Wrapper(app: .next, relayPort: nextRelayPort, inferencePort: nextInferencePort)

        // 收集两组需要执行的命令；只对真正需要装 / 刷新的 app 执行
        var scripts: [String] = []
        for w in [stable, next] {
            switch w.detectState() {
            case .missing, .foreign:
                continue // 跳过；调用方可单独处理
            case .installedMatching:
                continue // 已就绪
            case .pristine:
                if FileManager.default.fileExists(atPath: w.realBackupPath.path) {
                    continue
                }
                scripts.append(w.writeScriptShell(includeMv: true))
            case .installedStale:
                if !FileManager.default.fileExists(atPath: w.realBackupPath.path) {
                    continue
                }
                scripts.append(w.writeScriptShell(includeMv: false))
            }
        }

        if !scripts.isEmpty {
            // 拼成一条 sh 命令，整体一次提权
            let combined = scripts.joined(separator: " && ")
            let dummy = Wrapper(app: .stable, relayPort: stableRelayPort, inferencePort: stableInferencePort)
            try dummy.runWithElevation(script: combined)
        }

        return [stable.status(), next.status()]
    }
}

// MARK: - Helpers

private func readFirstBytes(at url: URL, count: Int) -> Data? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    return try? h.read(upToCount: count)
}

private func shellQuote(_ s: String) -> String {
    if !s.contains("'") {
        return "'\(s)'"
    }
    let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runShell(_ script: String) -> ShellResult {
    let p = Process()
    p.launchPath = "/bin/sh"
    p.arguments = ["-c", script]
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch {
        return ShellResult(exitCode: -1, stdout: "", stderr: "\(error)")
    }
    p.waitUntilExit()
    let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return ShellResult(
        exitCode: p.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}
