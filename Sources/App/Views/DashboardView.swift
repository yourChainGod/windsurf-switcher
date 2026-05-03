//
//  DashboardView.swift
//  App
//
//  调度中心 dashboard——核心页面。
//
//  布局（自上而下）：
//    1. HealthSummary 顶卡：drought / 总数 / 可用 / 冷却 / 封禁 / 最低 weekly%
//    2. RPC 计数卡：累计 / 成功率 / 最近 1min QPS
//    3. 实时 RPC 流：path / 状态 / 账号 email / 耗时（最近 50 条，倒序）
//    4. 号池快照排行：每号 score / daily% / weekly% / inFlight / cooldown 状态
//

import SwiftUI
import Core
import Relay

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summaryCard
                rpcStatsCard
                recentRPCSection
                poolList
            }
            .padding(12)
        }
        .task {
            await state.syncPoolOnce()
        }
    }

    // MARK: - Health summary 顶卡

    private var summaryCard: some View {
        let h = state.poolHealth
        return cardShell(
            title: "号池健康",
            accent: h.drought ? .red : .cyan,
            trailing: AnyView(
                Group {
                    if h.drought {
                        droughtChip
                    } else {
                        Text("OK").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.18))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
            )
        ) {
            HStack(spacing: 6) {
                statBig(label: "总数", value: "\(h.totalAccounts)")
                statBig(label: "可用", value: "\(h.availableAccounts)", color: .green)
                statBig(label: "冷却", value: "\(h.cooledAccounts)", color: .orange)
                statBig(label: "封禁", value: "\(h.bannedAccounts)", color: .red)
                statBig(
                    label: "最低 W%",
                    value: h.lowestWeeklyPercent.map { "\($0)%" } ?? "—",
                    color: lowColor(h.lowestWeeklyPercent)
                )
            }
        }
    }

    private var droughtChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text("枯竭模式")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.red.opacity(0.18))
        .foregroundStyle(.red)
        .clipShape(Capsule())
    }

    // MARK: - RPC 计数卡

    private var rpcStatsCard: some View {
        let s = state.statsSnapshot
        let successRate: String = {
            if s.total == 0 { return "—" }
            let r = Double(s.success) / Double(s.total) * 100
            return String(format: "%.1f%%", r)
        }()
        return cardShell(
            title: "RPC 流量",
            accent: rateColor(s),
            trailing: AnyView(
                HStack(spacing: 4) {
                    pulseDot(active: s.lastMinuteCount > 0)
                    Text("5s 同步")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            )
        ) {
            HStack(spacing: 6) {
                statBig(label: "累计", value: "\(s.total)")
                statBig(label: "成功", value: "\(s.success)", color: .green)
                statBig(label: "失败", value: "\(s.failure)", color: s.failure > 0 ? .red : .secondary)
                statBig(label: "成功率", value: successRate, color: rateColor(s))
                statBig(label: "近 1m", value: "\(s.lastMinuteCount)", color: .blue)
            }
        }
    }

    private func pulseDot(active: Bool) -> some View {
        Circle()
            .fill(active ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(active ? Color.green : Color.clear, lineWidth: 1)
                    .scaleEffect(active ? 1.8 : 1)
                    .opacity(active ? 0 : 0.5)
                    .animation(active ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default, value: active)
            )
    }

    // MARK: - 实时 RPC 列表

    @ViewBuilder
    private var recentRPCSection: some View {
        let recent = state.statsSnapshot.recent
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("实时调度")
                Spacer()
                if !recent.isEmpty {
                    Text("\(min(recent.count, 12)) / \(recent.count)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            if recent.isEmpty {
                emptyHint(icon: "antenna.radiowaves.left.and.right", text: "暂无 RPC，等待 LS 调用…")
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(recent.prefix(12).enumerated()), id: \.offset) { _, rpc in
                        RPCRow(rpc: rpc)
                    }
                }
            }
        }
    }

    // MARK: - 池排行

    @ViewBuilder
    private var poolList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("号池排行（按 score 降序）")
                Spacer()
                if !state.poolSnapshot.isEmpty {
                    Text("Top \(min(state.poolSnapshot.count, 10)) / \(state.poolSnapshot.count)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            if state.poolSnapshot.isEmpty {
                emptyHint(icon: "tray", text: "号池为空，等待同步…")
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(state.poolSnapshot.prefix(10)), id: \.accountId) { entry in
                        PoolEntryRow(snap: entry)
                    }
                }
            }
        }
    }

    // MARK: - card shell

    @ViewBuilder
    private func cardShell<Inner: View>(
        title: String,
        accent: Color,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Inner
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3, height: 12)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let t = trailing { t }
            }
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.06), accent.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.20), lineWidth: 0.7)
        )
    }

    private func sectionTitle(_ s: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 2, height: 9)
            Text(s)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func emptyHint(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.04))
        )
    }

    // MARK: - helpers

    private func statBig(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lowColor(_ pct: Int?) -> Color {
        guard let p = pct else { return .primary }
        switch p {
        case ..<5: return .red
        case 5..<20: return .orange
        default: return .green
        }
    }

    private func rateColor(_ s: StatsSnapshot) -> Color {
        guard s.total > 0 else { return .cyan }
        let r = Double(s.success) / Double(s.total)
        if r >= 0.9 { return .green }
        if r >= 0.6 { return .orange }
        return .red
    }
}

// MARK: - RPC 行

private struct RPCRow: View {
    let rpc: RecentRPC

    var body: some View {
        HStack(spacing: 6) {
            statusPill
            Text(shortPath)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let email = rpc.email {
                Text(emailLocalPart(email))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let id = rpc.accountId {
                Text(String(id.prefix(8)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("\(rpc.durationMillis)ms")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(timeAgo)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBg)
        )
    }

    private var statusPill: some View {
        Text("\(rpc.status)")
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(statusColor.opacity(0.20))
            .foregroundStyle(statusColor)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(minWidth: 30)
    }

    private var statusColor: Color {
        switch rpc.status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 401, 403: return .red
        case 429: return .orange
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }

    private var rowBg: Color {
        switch rpc.status {
        case 200..<300: return Color.secondary.opacity(0.04)
        case 401, 403: return Color.red.opacity(0.05)
        case 429: return Color.orange.opacity(0.05)
        case 500..<600: return Color.red.opacity(0.05)
        default: return Color.secondary.opacity(0.04)
        }
    }

    private var shortPath: String {
        if rpc.path.hasPrefix("/__relay/") { return rpc.path }
        if let lastSlash = rpc.path.lastIndex(of: "/") {
            return String(rpc.path[rpc.path.index(after: lastSlash)...])
        }
        return rpc.path
    }

    private func emailLocalPart(_ email: String) -> String {
        if let at = email.firstIndex(of: "@") {
            return String(email[..<at])
        }
        return email
    }

    private var timeAgo: String {
        let s = Int(-rpc.timestamp.timeIntervalSinceNow)
        if s < 1 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

// MARK: - 池排行行

private struct PoolEntryRow: View {
    let snap: EntrySnapshot

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            Text(snap.email ?? String(snap.accountId.prefix(8)))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
            Text("\(snap.score)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(quotaText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(quotaColor)
            if snap.inFlight > 0 {
                Text("⇋\(snap.inFlight)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            if let reason = snap.unavailableReason {
                Text(reason)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(reason == "banned" ? Color.red.opacity(0.18) : Color.orange.opacity(0.18))
                    .foregroundStyle(reason == "banned" ? .red : .orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
    }

    private var dotColor: Color {
        if snap.unavailableReason == "banned" { return .red }
        if snap.unavailableReason == "cooled" { return .orange }
        if snap.consecutiveFailures > 0 { return .yellow }
        return .green
    }

    private var quotaText: String {
        let d = snap.dailyPercent.map(String.init) ?? "—"
        let w = snap.weeklyPercent.map(String.init) ?? "—"
        return "D\(d)% W\(w)%"
    }

    private var quotaColor: Color {
        let w = snap.weeklyPercent ?? 100
        switch w {
        case ..<5: return .red
        case 5..<20: return .orange
        default: return .secondary
        }
    }
}
