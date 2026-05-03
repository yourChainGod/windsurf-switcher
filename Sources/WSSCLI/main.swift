//
//  main.swift
//  WSSCLI
//
//  Phase 1-A 的命令行驱动器，用于验证 Core/WindsurfClient/External 已就位。
//
//  子命令：
//    wss-cli check           — 自检：旧 binary 状态 / 双 app 安装 / 数据目录
//    wss-cli migrate [--force] — 跑数据迁移
//    wss-cli list            — 列出当前账号
//    wss-cli add <token> [label]  — 添加 token（含 GetOTT 校验 + GetPlanStatus 拉取）
//    wss-cli delete <id>     — 按 UUID 删账号
//    wss-cli refresh <id>    — 刷新单号 quota
//    wss-cli switch <id> <stable|next>  — 切号到指定 app
//    wss-cli kill-legacy     — 终止旧 windsurf-switcher 进程
//

import Foundation
import Core
import WindsurfClient
import External

@main
struct WSSCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            printUsage()
            exit(1)
        }
        let rest = Array(args.dropFirst())
        do {
            switch cmd {
            case "check": try await cmdCheck()
            case "migrate": try await cmdMigrate(rest)
            case "list": try await cmdList()
            case "add": try await cmdAdd(rest)
            case "delete": try await cmdDelete(rest)
            case "refresh": try await cmdRefresh(rest)
            case "switch": try await cmdSwitch(rest)
            case "kill-legacy": cmdKillLegacy()
            case "-h", "--help", "help": printUsage()
            default:
                fputs("unknown command: \(cmd)\n", stderr)
                printUsage()
                exit(2)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        wss-cli — windsurf-switcher native (Phase 1-A)

        Commands:
          check                    Self-check (legacy binary, both apps, data dir)
          migrate [--force]        Import legacy ~/Library/Application Support/com.windsurf.switcher
          list                     List accounts
          add <token> [label]      Add an account (validates via GetOTT + fetches plan)
          delete <id>              Delete account by UUID
          refresh <id>             Refresh plan status for one account
          switch <id> <app>        Trigger deep-link switch (app = stable | next)
          kill-legacy              SIGTERM old windsurf-switcher binary
        """)
    }

    // MARK: - Commands

    static func cmdCheck() async throws {
        print("⚙ Self-check")
        print("  Stable installed:  \(WindsurfApp.stable.isInstalled) (\(WindsurfApp.stable.appPath.path))")
        print("  Next installed:    \(WindsurfApp.next.isInstalled) (\(WindsurfApp.next.appPath.path))")

        let dataDir = try defaultDataDirectory()
        print("  Data dir:          \(dataDir.path)")
        let legacyDir = try? legacyDataDirectory()
        print("  Legacy dir:        \(legacyDir?.path ?? "n/a")")
        print("  Needs migration:   \(DataMigration.needsMigration())")

        let pids = LegacyCleanup.findLegacyPids()
        if pids.isEmpty {
            print("  Legacy binary:     none running")
        } else {
            print("  Legacy binary:     PIDs \(pids)")
        }
        print("  Legacy daemon:     \(LegacyCleanup.legacyLaunchDaemonLoaded() ? "loaded" : "not loaded")")
    }

    static func cmdMigrate(_ args: [String]) async throws {
        let force = args.contains("--force")
        let r = try DataMigration.migrateLegacy(force: force)
        if r.alreadyMigrated {
            print("✓ already migrated (use --force to overwrite)")
        } else if r.sourcePath == nil {
            print("✓ no legacy data to migrate")
        } else {
            print("✓ migrated \(r.importedCount) account(s) from \(r.sourcePath!.path)")
        }
    }

    static func cmdList() async throws {
        let store = try await AccountStore.openDefault()
        let accounts = await store.list()
        if accounts.isEmpty {
            print("(no accounts)")
            return
        }
        print(pad("id", 36) + "  " + pad("label/email", 30) + "  " + pad("app", 8) + "  " + "daily%/weekly%")
        for a in accounts {
            let app = a.lastUsedApp.map { $0.rawValue } ?? "-"
            let dPct = a.planStatus?.dailyPercent.map(String.init) ?? "-"
            let wPct = a.planStatus?.weeklyPercent.map(String.init) ?? "-"
            print(pad(a.id.uuidString, 36)
                  + "  " + pad(String(a.displayName.prefix(30)), 30)
                  + "  " + pad(app, 8)
                  + "  " + "\(dPct)/\(wPct)")
        }
    }

    static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    static func cmdAdd(_ args: [String]) async throws {
        guard let token = args.first else {
            fputs("usage: wss-cli add <token> [label]\n", stderr)
            exit(2)
        }
        let label = args.dropFirst().first ?? ""

        let store = try await AccountStore.openDefault()
        var account = Account(label: label, sessionToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
        account.jwtInfo = JWTDecode.decode(account.sessionToken)
        let saved = try await store.upsert(account)
        print("✓ saved account \(saved.id) [\(saved.displayName)]")

        // 异步拉 plan + 验证 OTT
        let plan = try? await GetPlanStatusClient().getPlanStatus(token: account.sessionToken)
        if let plan = plan {
            try await store.update(id: saved.id) { $0.planStatus = plan; $0.lastError = nil }
            print("  plan: \(plan.planName ?? "?") daily=\(plan.dailyPercent.map(String.init) ?? "-") weekly=\(plan.weeklyPercent.map(String.init) ?? "-")")
        } else {
            print("  ✗ plan fetch failed (token saved anyway)")
        }
    }

    static func cmdDelete(_ args: [String]) async throws {
        guard let s = args.first, let uuid = UUID(uuidString: s) else {
            fputs("usage: wss-cli delete <uuid>\n", stderr)
            exit(2)
        }
        let store = try await AccountStore.openDefault()
        try await store.delete(id: uuid)
        print("✓ deleted \(uuid)")
    }

    static func cmdRefresh(_ args: [String]) async throws {
        guard let s = args.first, let uuid = UUID(uuidString: s) else {
            fputs("usage: wss-cli refresh <uuid>\n", stderr)
            exit(2)
        }
        let store = try await AccountStore.openDefault()
        guard let acc = await store.get(id: uuid) else {
            fputs("not found\n", stderr)
            exit(1)
        }
        do {
            let plan = try await GetPlanStatusClient().getPlanStatus(token: acc.sessionToken)
            try await store.update(id: uuid) { $0.planStatus = plan; $0.lastError = nil }
            print("✓ refreshed: \(plan.planName ?? "?") daily=\(plan.dailyPercent.map(String.init) ?? "-")")
        } catch {
            try await store.update(id: uuid) { $0.lastError = "\(error)" }
            throw error
        }
    }

    static func cmdSwitch(_ args: [String]) async throws {
        guard args.count >= 2,
              let uuid = UUID(uuidString: args[0]),
              let app = WindsurfApp(rawValue: args[1])
        else {
            fputs("usage: wss-cli switch <uuid> <stable|next>\n", stderr)
            exit(2)
        }
        let store = try await AccountStore.openDefault()
        guard let acc = await store.get(id: uuid) else {
            fputs("not found\n", stderr)
            exit(1)
        }
        let ott = try await GetOTTClient().getOneTimeAuthToken(token: acc.sessionToken)
        guard let url = app.switchURL(ott: ott) else {
            fputs("could not build switch URL\n", stderr)
            exit(1)
        }
        print("✓ OTT \(String(ott.prefix(12)))…  → opening \(url.absoluteString.prefix(80))…")
        // open the URL via /usr/bin/open（CLI 上下文不引 AppKit）
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url.absoluteString]
        try task.run()
        task.waitUntilExit()
        try await store.update(id: uuid) {
            $0.lastSwitchedAt = Date()
            $0.lastUsedApp = app
        }
    }

    static func cmdKillLegacy() {
        let r = LegacyCleanup.terminateLegacyBinaries()
        print("✓ killed: \(r.killedPids), still alive after SIGKILL: \(r.stillAlivePids)")
    }
}
