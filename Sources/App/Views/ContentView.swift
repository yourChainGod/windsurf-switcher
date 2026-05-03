//
//  ContentView.swift
//  App
//
//  根视图：顶部头条 + 当前激活号条带 + 三 tab 切换（Manage / Dashboard / Settings）。
//  关键：菜单栏 popover 内绝不用 .sheet —— sheet 触发 NSWindow 创建，
//  会让 MenuBarExtra popover 失焦秒关。一律改 inline 视图栈。
//

import SwiftUI

enum AppTab: String, CaseIterable {
    case manage
    case dashboard
    case settings
    case addToken
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    /// 默认进调度中心——它是核心：池快照 / 健康 / 实时 RPC。
    /// 账号管理是次级（管理操作才需要切过去）。
    @State private var tab: AppTab = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(tab: $tab)
            ActiveAccountStrip()
            Divider().opacity(0.4)
            Group {
                switch tab {
                case .manage:
                    ManageView(onAddTap: { tab = .addToken })
                case .dashboard:
                    DashboardView()
                case .settings:
                    SettingsView()
                case .addToken:
                    AddTokenView(onClose: { tab = .manage })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let toast = state.toast {
                ToastBar(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            LinearGradient(
                colors: [Color(.windowBackgroundColor), Color(.windowBackgroundColor).opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

// MARK: - HeaderBar

private struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 10) {
            // 左：图标 + 标题
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(
                        colors: [.cyan, .indigo],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                    .shadow(color: .indigo.opacity(0.35), radius: 3, x: 0, y: 1)
                Text("WS").font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(tabTitle).font(.system(size: 13, weight: .semibold))
                Text(tabSubtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Spacer()

            // addToken 子页：只显示返回按钮
            if tab == .addToken {
                IconButton(systemName: "chevron.left", help: "返回账号列表") { tab = .manage }
            } else {
                if tab == .manage {
                    IconButton(systemName: "plus", help: "添加 token") { tab = .addToken }
                    IconButton(
                        systemName: state.loading ? "" : "arrow.clockwise",
                        help: "刷新全部",
                        progress: state.loading,
                        disabled: state.loading
                    ) {
                        Task { await state.refreshAllAccounts() }
                    }
                }

                if tab == .dashboard {
                    IconButton(systemName: "arrow.triangle.2.circlepath", help: "立即同步号池") {
                        Task { await state.syncPoolOnce() }
                    }
                }

                IconButton(
                    systemName: tab == .dashboard ? "person.2" : "chart.line.uptrend.xyaxis",
                    help: tab == .dashboard ? "账号管理" : "调度中心"
                ) {
                    tab = (tab == .dashboard ? .manage : .dashboard)
                }

                IconButton(
                    systemName: "gearshape",
                    help: tab == .settings ? "返回调度中心" : "设置"
                ) {
                    tab = (tab == .settings ? .dashboard : .settings)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var tabTitle: String {
        switch tab {
        case .manage: return "账号管理"
        case .dashboard: return "调度中心"
        case .settings: return "设置"
        case .addToken: return "添加 Token"
        }
    }

    private var tabSubtitle: String {
        switch tab {
        case .manage: return "添加 / 删除 / 重命名 / 切号"
        case .dashboard: return "号池 · 健康 · 实时 RPC"
        case .settings: return "preferences"
        case .addToken: return "粘贴 devin-session-token"
        }
    }
}

// MARK: - 当前激活号条带

/// HeaderBar 下方常驻条：实时显示"当前激活号"——
/// 优先最近 RPC 落到的账号；否则池里 score 最高的可用号。
private struct ActiveAccountStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            if let info = state.activeAccount {
                statusDot(for: info)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(info.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        sourceBadge(info.source)
                    }
                    HStack(spacing: 6) {
                        if let w = info.weeklyPercent {
                            Text("W \(w)%").foregroundStyle(quotaColor(w))
                        }
                        if let d = info.dailyPercent {
                            Text("D \(d)%").foregroundStyle(quotaColor(d))
                        }
                        Text("score \(info.score)").foregroundStyle(.secondary)
                        if info.inFlight > 0 {
                            Text("⇋\(info.inFlight)").foregroundStyle(.blue)
                        }
                    }
                    .font(.system(size: 9, design: .monospaced))
                }
                Spacer()
                if let status = info.lastRPCStatus, let at = info.lastRPCAt {
                    rpcPill(status: status, at: at)
                }
            } else {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text("待 LS 调用 · 号池就绪后自动激活")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LinearGradient(
                colors: stripColors(),
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    private func stripColors() -> [Color] {
        guard let info = state.activeAccount else {
            return [Color.secondary.opacity(0.06), Color.secondary.opacity(0.03)]
        }
        if let s = info.lastRPCStatus {
            switch s {
            case 200..<300: return [Color.green.opacity(0.10), Color.green.opacity(0.03)]
            case 401, 403: return [Color.red.opacity(0.12), Color.red.opacity(0.03)]
            case 429: return [Color.orange.opacity(0.12), Color.orange.opacity(0.03)]
            case 400..<600: return [Color.orange.opacity(0.10), Color.orange.opacity(0.03)]
            default: break
            }
        }
        return [Color.cyan.opacity(0.08), Color.indigo.opacity(0.04)]
    }

    private func statusDot(for info: ActiveAccountInfo) -> some View {
        let color: Color = {
            if let s = info.lastRPCStatus {
                switch s {
                case 200..<300: return .green
                case 401, 403: return .red
                case 429: return .orange
                default: return .yellow
                }
            }
            return .blue
        }()
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 2.5).blur(radius: 1))
    }

    private func sourceBadge(_ src: ActiveAccountInfo.Source) -> some View {
        let label = src == .recentRPC ? "活跃" : "待命"
        let bg: Color = src == .recentRPC ? .green : .blue
        return Text(label)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(bg.opacity(0.18))
            .foregroundStyle(bg)
            .clipShape(Capsule())
    }

    private func rpcPill(status: Int, at: Date) -> some View {
        let color: Color = {
            switch status {
            case 200..<300: return .green
            case 401, 403: return .red
            case 429: return .orange
            default: return .secondary
            }
        }()
        let secsAgo = Int(-at.timeIntervalSinceNow)
        let ago = secsAgo < 60 ? "\(secsAgo)s" : "\(secsAgo / 60)m"
        return HStack(spacing: 3) {
            Text("\(status)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(ago)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func quotaColor(_ p: Int) -> Color {
        switch p {
        case ..<5: return .red
        case 5..<20: return .orange
        default: return .primary
        }
    }
}

// MARK: - IconButton（统一样式）

private struct IconButton: View {
    let systemName: String
    let help: String
    var progress: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if progress {
                    ProgressView().controlSize(.small)
                } else if !systemName.isEmpty {
                    Image(systemName: systemName).font(.system(size: 12))
                }
            }
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - Toast

private struct ToastBar: View {
    let toast: Toast

    var color: Color {
        switch toast.kind {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info: return .blue
        }
    }

    var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(toast.text).font(.system(size: 11))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .id(toast.id)
        .task(id: toast.id) {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
    }
}
