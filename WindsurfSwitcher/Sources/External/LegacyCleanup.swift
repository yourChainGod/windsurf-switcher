//
//  LegacyCleanup.swift
//  External
//
//  启动时清理旧 rust+tauri windsurf-switcher 的运行实例：
//    1. pgrep 查 `target/release/windsurf-switcher` / `windsurf-switcher.app/Contents/MacOS/`
//    2. SIGTERM；2 秒等待；仍存活 → SIGKILL
//    3. launchctl unload 旧 LaunchDaemon（cascade-port-forwarder）—— 仅当我们要装新的
//
//  注意：`/Library/LaunchDaemons/com.windsurf-switcher.cascade-port-forward.plist`
//  这个 daemon 是新旧 app 共用的，**不**自动卸载（否则 cascade :443 转发会断）。
//  只有用户在 Settings 里点"重装 cascade 端口转发"时才 unload+reload。
//

import Foundation

public enum LegacyCleanup {

    /// 旧 rust+tauri binary 进程匹配模式（pgrep -f）。
    /// 命中：
    ///   1. cargo run 的 release 路径
    ///   2. 拷成 .app 后在 Applications 内的路径（旧版 README 描述）
    public static let legacyProcessPatterns: [String] = [
        "target/release/windsurf-switcher",
        "windsurf-switcher.app/Contents/MacOS/windsurf-switcher",
    ]

    /// 旧 LaunchDaemon plist 路径（**当前不卸载**，仅记录）。
    public static let legacyLaunchDaemonPlist =
        "/Library/LaunchDaemons/com.windsurf-switcher.cascade-port-forward.plist"

    public struct CleanupReport: Equatable {
        public let killedPids: [Int32]
        public let stillAlivePids: [Int32]

        public var isClean: Bool { stillAlivePids.isEmpty }
    }

    /// 找到所有匹配旧 binary 的 PID。
    public static func findLegacyPids() -> [Int32] {
        var pids: Set<Int32> = []
        for pattern in legacyProcessPatterns {
            let result = runCommand("/usr/bin/pgrep", ["-f", pattern])
            guard result.exitCode == 0 else { continue }
            for line in result.stdout.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    pids.insert(pid)
                }
            }
        }
        // 排除自己
        let myPid = ProcessInfo.processInfo.processIdentifier
        pids.remove(myPid)
        return Array(pids).sorted()
    }

    /// 杀掉所有旧 binary。先 SIGTERM（15），等 2s，仍存活再 SIGKILL（9）。
    @discardableResult
    public static func terminateLegacyBinaries(gracePeriod: TimeInterval = 2.0) -> CleanupReport {
        let initial = findLegacyPids()
        for pid in initial {
            kill(pid, SIGTERM)
        }
        if !initial.isEmpty {
            Thread.sleep(forTimeInterval: gracePeriod)
        }
        var stillAlive: [Int32] = []
        for pid in initial {
            if kill(pid, 0) == 0 {
                // 仍存活
                stillAlive.append(pid)
                kill(pid, SIGKILL)
            }
        }
        return CleanupReport(killedPids: initial, stillAlivePids: [])
            .with(stillAlivePids: stillAlive)
    }

    /// 检查旧 LaunchDaemon 是否在运行（未来需要时调用 launchctl unload）。
    public static func legacyLaunchDaemonLoaded() -> Bool {
        let result = runCommand("/bin/launchctl", ["list", "com.windsurf-switcher.cascade-port-forward"])
        return result.exitCode == 0
    }

    // MARK: - Process helpers

    struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func runCommand(_ launchPath: String, _ arguments: [String]) -> CommandResult {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
        task.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            exitCode: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

private extension LegacyCleanup.CleanupReport {
    func with(stillAlivePids: [Int32]) -> LegacyCleanup.CleanupReport {
        LegacyCleanup.CleanupReport(killedPids: killedPids, stillAlivePids: stillAlivePids)
    }
}
