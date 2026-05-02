//
//  ContentView.swift
//  App
//
//  根视图：顶部头条 + 三 tab 切换（Manage / Dashboard / Settings）。
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
    @State private var tab: AppTab = .manage

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(tab: $tab)
            Divider()
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
    }
}

private struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 8) {
            // 左：图标 + 标题
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [.cyan, .indigo],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                Text("WS").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(tabTitle).font(.system(size: 13, weight: .semibold))
                Text(tabSubtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Spacer()

            // addToken 子页：只显示返回按钮
            if tab == .addToken {
                Button {
                    tab = .manage
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("返回账号列表")
            } else {
                if tab == .manage {
                    Button {
                        tab = .addToken
                    } label: {
                        Image(systemName: "plus").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("添加 token")

                    Button {
                        Task { await state.refreshAllVisible() }
                    } label: {
                        if state.loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 13))
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("刷新全部")
                    .disabled(state.loading)
                }

                Button {
                    tab = (tab == .dashboard ? .manage : .dashboard)
                } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help(tab == .dashboard ? "返回账号" : "调度中心")

                Button { tab = (tab == .settings ? .manage : .settings) } label: {
                    Image(systemName: "gearshape").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help(tab == .settings ? "返回账号" : "设置")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tabTitle: String {
        switch tab {
        case .manage: return "账号"
        case .dashboard: return "调度中心"
        case .settings: return "设置"
        case .addToken: return "添加 Token"
        }
    }

    private var tabSubtitle: String {
        switch tab {
        case .manage: return "Stable + Next 共享池"
        case .dashboard: return "Pool · Health · Snapshot"
        case .settings: return "preferences"
        case .addToken: return "粘贴 devin-session-token"
        }
    }
}

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
