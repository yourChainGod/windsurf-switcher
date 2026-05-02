//
//  DashboardView.swift
//  App
//
//  调度中心 dashboard：
//    - HealthSummary 顶卡：drought / 总数 / 可用 / 冷却 / 封禁 / 最低 weekly%
//    - 池快照列表：每号显示 score / daily% / weekly% / inFlight / cooldown 状态
//

import SwiftUI
import Core
import Relay

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                summaryCard
                Divider().opacity(0.3)
                poolList
            }
            .padding(10)
        }
        .task {
            // 首次进入立即跑一次同步，保证最新
            await state.syncPoolOnce()
        }
    }

    private var summaryCard: some View {
        let h = state.poolHealth
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("调 度 中 心")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if h.drought {
                    Text("⚠️ 枯竭模式")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.18))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    Task { await state.syncPoolOnce() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("立即同步")
            }
            HStack(spacing: 8) {
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func statBig(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
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

    @ViewBuilder
    private var poolList: some View {
        if state.poolSnapshot.isEmpty {
            Text("（号池为空，等待同步…）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("号 池 快 照")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                LazyVStack(spacing: 4) {
                    ForEach(state.poolSnapshot, id: \.accountId) { entry in
                        PoolEntryRow(snap: entry)
                    }
                }
            }
        }
    }
}

private struct PoolEntryRow: View {
    let snap: EntrySnapshot

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            Text(snap.email ?? String(snap.accountId.prefix(8)))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
            // score
            Text("\(snap.score)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            // daily / weekly
            Text(quotaText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(quotaColor)
            // in_flight
            if snap.inFlight > 0 {
                Text("⇋\(snap.inFlight)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            // cooldown / banned
            if let reason = snap.unavailableReason {
                Text(reason)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
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
