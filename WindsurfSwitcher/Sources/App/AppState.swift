//
//  AppState.swift
//  App
//
//  全局状态管理：账号列表 / 当前 segment / 后台任务。
//
//  并发：用 ObservableObject + @Published（兼容 macOS 13）。
//  所有 Account 写操作都过 AccountStore actor 串行；UI 更新用 @MainActor。
//

import Foundation
import SwiftUI
import Core
import WindsurfClient
import External

/// UI 顶部 segmented control 的过滤维度。
public enum AppFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case stable
    case next

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .all: return "全部"
        case .stable: return "Windsurf"
        case .next: return "Next"
        }
    }

    /// 过滤匹配：`.all` 全通过；指定 app 时匹配 `lastUsedApp == app`，未打标的也通过（待用户首次切号打标）。
    public func matches(_ account: Account) -> Bool {
        switch self {
        case .all: return true
        case .stable:
            return account.lastUsedApp == nil || account.lastUsedApp == .stable
        case .next:
            return account.lastUsedApp == nil || account.lastUsedApp == .next
        }
    }

    /// 当 segment 是某个具体 app 时，作为切号目标 app；`.all` 时由用户在卡片上选择。
    public var targetApp: WindsurfApp? {
        switch self {
        case .all: return nil
        case .stable: return .stable
        case .next: return .next
        }
    }
}

/// 简短瞬时通知。
public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public let kind: Kind
    public let text: String

    public enum Kind: Equatable { case success, warning, error, info }
}

@MainActor
public final class AppState: ObservableObject {
    // MARK: Published state

    @Published public var accounts: [Account] = []
    @Published public var filter: AppFilter = .all
    @Published public var loading: Bool = false
    @Published public var migrationBanner: MigrationResult?
    @Published public var toast: Toast?
    @Published public var refreshingIds: Set<UUID> = []
    @Published public var switchingIds: Set<UUID> = []

    // MARK: Backing services

    private var store: AccountStore?
    private let ottClient = GetOTTClient()
    private let planClient = GetPlanStatusClient()
    private var quotaTickerTask: Task<Void, Never>?

    public init() {}

    // MARK: Lifecycle

    /// App 启动钩子：旧 binary 清理 → 数据迁移 → 加载账号 → 启动后台 quota 刷新。
    public func bootstrap() async {
        // 1. 旧 binary 清理（同步操作，快）
        let cleanup = LegacyCleanup.terminateLegacyBinaries()
        if !cleanup.killedPids.isEmpty {
            self.toast = Toast(kind: .info, text: "已停止旧版 binary（PID: \(cleanup.killedPids)）")
        }

        // 2. 数据迁移（仅在新数据为空时跑）
        if DataMigration.needsMigration() {
            do {
                let r = try DataMigration.migrateLegacy()
                if r.importedCount > 0 {
                    self.migrationBanner = r
                    self.toast = Toast(kind: .success, text: "已导入旧版 \(r.importedCount) 个账号")
                }
            } catch {
                self.toast = Toast(kind: .error, text: "数据迁移失败：\(error)")
            }
        }

        // 3. 打开 store + 加载账号
        do {
            let s = try await AccountStore.openDefault()
            self.store = s
            await reload()
        } catch {
            self.toast = Toast(kind: .error, text: "无法打开数据目录：\(error)")
        }

        // 4. 后台定时刷新 quota（每 5min 一轮，每轮挑 8 号串行）
        startQuotaTicker()
    }

    /// 从 store 重新加载账号列表。按 lastSwitchedAt / addedAt 倒序。
    public func reload() async {
        guard let store = store else { return }
        let list = await store.list()
        self.accounts = list.sorted { lhs, rhs in
            let lt = lhs.lastSwitchedAt ?? lhs.addedAt
            let rt = rhs.lastSwitchedAt ?? rhs.addedAt
            return lt > rt
        }
    }

    public var filteredAccounts: [Account] {
        accounts.filter { filter.matches($0) }
    }

    /// 顶部统计：未冷却数 / 冷却中 / 长封禁。
    public var summary: (active: Int, cooled: Int, banned: Int) {
        var a = 0, c = 0, b = 0
        for acc in filteredAccounts {
            if acc.isBanned { b += 1 }
            else if acc.isCoolingDown { c += 1 }
            else { a += 1 }
        }
        return (a, c, b)
    }

    // MARK: Account ops

    public func addToken(_ token: String, label: String) async {
        guard let store = store else { return }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.toast = Toast(kind: .warning, text: "token 为空")
            return
        }
        var account = Account(label: label, sessionToken: trimmed)
        account.jwtInfo = JWTDecode.decode(trimmed)
        do {
            let saved = try await store.upsert(account)
            await reload()
            self.toast = Toast(kind: .success, text: "已添加：\(saved.displayName)")
            // 异步拉 quota；失败不阻塞
            await refreshQuota(id: saved.id)
        } catch {
            self.toast = Toast(kind: .error, text: "保存失败：\(error)")
        }
    }

    public func deleteAccount(_ id: UUID) async {
        guard let store = store else { return }
        do {
            try await store.delete(id: id)
            await reload()
        } catch {
            self.toast = Toast(kind: .error, text: "删除失败：\(error)")
        }
    }

    public func renameAccount(_ id: UUID, label: String) async {
        guard let store = store else { return }
        do {
            try await store.update(id: id) { $0.label = label }
            await reload()
        } catch {
            self.toast = Toast(kind: .error, text: "重命名失败：\(error)")
        }
    }

    /// 刷新单号 plan status；返回成功时无 toast，失败 toast warning。
    public func refreshQuota(id: UUID) async {
        guard let store = store else { return }
        guard let account = await store.get(id: id) else { return }
        refreshingIds.insert(id)
        defer { refreshingIds.remove(id) }
        do {
            let plan = try await planClient.getPlanStatus(token: account.sessionToken)
            try await store.update(id: id) {
                $0.planStatus = plan
                $0.lastError = nil
                $0.jwtInfo = JWTDecode.decode($0.sessionToken)
            }
            await reload()
        } catch {
            _ = try? await store.update(id: id) { $0.lastError = "\(error)" }
            await reload()
            self.toast = Toast(kind: .warning, text: "刷新失败：\(account.displayName)")
        }
    }

    /// 刷新所有过滤后可见账号；串行，避免上游限流。
    public func refreshAllVisible() async {
        let ids = filteredAccounts.map { $0.id }
        guard !ids.isEmpty else { return }
        loading = true
        defer { loading = false }
        var ok = 0, fail = 0
        for id in ids {
            let before = accounts.first(where: { $0.id == id })?.lastError
            await refreshQuota(id: id)
            let after = accounts.first(where: { $0.id == id })?.lastError
            if (before == nil && after == nil) || (before != nil && after == nil) {
                ok += 1
            } else if after != nil {
                fail += 1
            }
            // 单轮间隔 1.5s 防限流
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if fail == 0 {
            self.toast = Toast(kind: .success, text: "已刷新 \(ok) 个账号")
        } else {
            self.toast = Toast(kind: .warning, text: "刷新完成：成功 \(ok)，失败 \(fail)")
        }
    }

    /// 触发切号到指定 app（segment 当前选中的或卡片上覆写的）。
    public func switchAccount(_ id: UUID, to app: WindsurfApp) async {
        guard let store = store else { return }
        guard let account = await store.get(id: id) else { return }
        switchingIds.insert(id)
        defer { switchingIds.remove(id) }
        do {
            let ott = try await ottClient.getOneTimeAuthToken(token: account.sessionToken)
            guard let url = app.switchURL(ott: ott) else {
                self.toast = Toast(kind: .error, text: "构造 deep link 失败")
                return
            }
            // NSWorkspace.open；不引入 AppKit 依赖到 Core/WindsurfClient，App target 直接用
            #if canImport(AppKit)
            _ = NSWorkspace.shared.open(url)
            #endif
            try await store.update(id: id) {
                $0.lastSwitchedAt = Date()
                $0.lastUsedApp = app
            }
            await reload()
            let preview = String(ott.prefix(12))
            self.toast = Toast(kind: .success, text: "切号成功 → \(app.displayName)（OTT \(preview)…）")
        } catch {
            self.toast = Toast(kind: .error, text: "切号失败：\(error)")
        }
    }

    public func quit() {
        quotaTickerTask?.cancel()
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #else
        exit(0)
        #endif
    }

    // MARK: Quota ticker

    /// 后台每 5 分钟挑 8 个最旧的账号串行刷 quota。失败一个不影响其他。
    private func startQuotaTicker() {
        quotaTickerTask?.cancel()
        quotaTickerTask = Task { [weak self] in
            // 启动后等 30s 再开第一次
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            while !Task.isCancelled {
                await self?.refreshStaleQuotas()
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5min
            }
        }
    }

    private func refreshStaleQuotas() async {
        guard let store = store else { return }
        let now = Date()
        let staleThreshold: TimeInterval = 30 * 60 // 半小时
        let candidates = (await store.list())
            .compactMap { acc -> (UUID, TimeInterval)? in
                if let fetched = acc.planStatus?.fetchedAt {
                    let age = now.timeIntervalSince(fetched)
                    if age > staleThreshold { return (acc.id, fetched.timeIntervalSince1970) }
                    return nil
                } else {
                    return (acc.id, 0)
                }
            }
            .sorted { $0.1 < $1.1 }
            .prefix(8)

        for (id, _) in candidates {
            await refreshQuota(id: id)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}

// 仅 macOS：把 NSWorkspace 暴露给 AppState
#if canImport(AppKit)
import AppKit
#endif
