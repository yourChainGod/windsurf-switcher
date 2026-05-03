//
//  AccountCardView.swift
//  App
//
//  单条账号卡片：
//    - 主信息：displayName + plan_name + cooldown 状态
//    - 配额：daily% / weekly% 横条
//    - 操作：切号 / 刷新 / 删除（带确认）/ 重命名
//

import SwiftUI
import Core

struct AccountCardView: View {
    @EnvironmentObject var state: AppState
    let account: Account

    @State private var hovering = false
    @State private var deleteCountdown = 0
    @State private var deleteTimer: Timer?
    @State private var renaming = false
    @State private var renameDraft = ""
    /// 长 lastError 默认折叠 — 点 "详情" 才展开。避免 401 长串污染列表。
    @State private var errorExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusDot
                if renaming {
                    TextField("备注", text: $renameDraft, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                } else {
                    Text(account.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { startRename() }
                }
                if let plan = account.planName {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                }
                if let app = account.lastUsedApp {
                    Text(app.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hovering {
                    actionButtons
                }
            }
            quotaBars
            if account.isCoolingDown, let until = account.cooldownUntil {
                Text("冷却中 · 剩余 \(formatRemaining(until))")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if account.isBanned, let until = account.bannedUntil {
                Text("⚠️ 长封禁至 \(formatDate(until))")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
            if let err = account.lastError {
                errorRow(err)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { handleTap() }
    }

    /// 错误信息：默认折叠成单行 "⚠ 配额刷新失败"，点 "详情" 展开看全文。
    /// 长 401 unauthenticated body 不再红字大显眼，避免污染列表观感。
    @ViewBuilder
    private func errorRow(_ err: String) -> some View {
        let summary: String = {
            if err.localizedCaseInsensitiveContains("unauthenticated")
                || err.localizedCaseInsensitiveContains("invalid token") {
                return "Token 失效"
            }
            if err.localizedCaseInsensitiveContains("rate limit")
                || err.localizedCaseInsensitiveContains("429") {
                return "限流（rate limit）"
            }
            if err.localizedCaseInsensitiveContains("timeout") {
                return "上游超时"
            }
            return "配额刷新失败"
        }()
        if errorExpanded {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(summary)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("收起") { errorExpanded = false }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(err)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(summary)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Spacer()
                Button("详情") { errorExpanded = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sub views

    private var statusDot: some View {
        Group {
            if state.switchingIds.contains(account.id) {
                ProgressView().controlSize(.small)
            } else if account.isBanned {
                Circle().fill(Color.red).frame(width: 7, height: 7)
            } else if account.isCoolingDown {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
            } else if account.lastError != nil {
                Circle().fill(Color.yellow).frame(width: 7, height: 7)
            } else {
                Circle().fill(Color.green).frame(width: 7, height: 7)
            }
        }
        .frame(width: 14)
    }

    private var quotaBars: some View {
        HStack(spacing: 8) {
            quotaBar(label: "日", value: account.planStatus?.dailyPercent)
            quotaBar(label: "周", value: account.planStatus?.weeklyPercent)
        }
    }

    private func quotaBar(label: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(value.map { "\($0)%" } ?? "-")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            GeometryReader { geo in
                let pct = CGFloat(value ?? 0) / 100.0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.25))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(quotaColor(value))
                        .frame(width: max(0, geo.size.width * pct))
                }
            }
            .frame(height: 4)
        }
    }

    private func quotaColor(_ pct: Int?) -> Color {
        guard let p = pct else { return .gray }
        switch p {
        case ..<10: return .red
        case 10..<40: return .orange
        default: return .green
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Menu {
                Button {
                    switchTo(.stable)
                } label: {
                    Label("切到 Windsurf", systemImage: "wind")
                }
                Button {
                    switchTo(.next)
                } label: {
                    Label("切到 Next", systemImage: "wind.snow")
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("选择切号目标")

            Button {
                Task { await state.refreshQuota(id: account.id) }
            } label: {
                if state.refreshingIds.contains(account.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
            }
            .buttonStyle(.borderless)
            .help("刷新配额")

            Button { startRename() } label: {
                Image(systemName: "pencil").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("重命名")

            Button { handleDelete() } label: {
                Image(systemName: deleteCountdown > 0 ? "trash.fill" : "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(deleteCountdown > 0 ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .help(deleteCountdown > 0 ? "再次点击确认删除（\(deleteCountdown)s）" : "删除")
        }
    }

    private var cardBg: Color {
        if state.switchingIds.contains(account.id) {
            return Color.blue.opacity(0.12)
        }
        if account.isBanned { return Color.red.opacity(0.06) }
        if account.isCoolingDown { return Color.orange.opacity(0.06) }
        // lastError 不再单独着色——折叠后已不刺眼，避免 list 一片黄
        return Color.secondary.opacity(0.05)
    }

    private var cardBorder: Color {
        if state.switchingIds.contains(account.id) { return Color.blue.opacity(0.45) }
        if hovering { return Color.secondary.opacity(0.35) }
        return Color.secondary.opacity(0.18)
    }

    // MARK: - Actions

    private func handleTap() {
        if renaming { return }
        // 取消删除倒计时（点别处不算确认）
        if deleteCountdown > 0 {
            deleteCountdown = 0
            deleteTimer?.invalidate()
            return
        }
        switchTo(account.lastUsedApp ?? .stable)
    }

    private func switchTo(_ app: WindsurfApp) {
        Task { await state.switchAccount(account.id, to: app) }
    }

    private func startRename() {
        renameDraft = account.label.isEmpty ? account.displayName : account.label
        renaming = true
    }

    private func commitRename() {
        let new = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
        if new != account.label {
            Task { await state.renameAccount(account.id, label: new) }
        }
    }

    private func handleDelete() {
        if deleteCountdown > 0 {
            // 二次点击确认
            deleteTimer?.invalidate()
            deleteCountdown = 0
            Task { await state.deleteAccount(account.id) }
        } else {
            // 第一次点击启动 4 秒倒计时
            deleteCountdown = 4
            deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                Task { @MainActor in
                    deleteCountdown -= 1
                    if deleteCountdown <= 0 { t.invalidate() }
                }
            }
        }
    }

    // MARK: - Format helpers

    private func formatRemaining(_ until: Date) -> String {
        let secs = Int(until.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)min" }
        return "\(secs / 3600)h\((secs % 3600) / 60)min"
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}
