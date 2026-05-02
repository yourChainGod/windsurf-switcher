//
//  ContentView.swift
//  App
//
//  根视图：顶部头条 + 三 tab 切换（Manage / Settings）。
//

import SwiftUI

enum AppTab: String, CaseIterable {
    case manage
    case settings
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: AppTab = .manage
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(tab: $tab, showAdd: $showAdd)
            Divider()
            Group {
                switch tab {
                case .manage:
                    ManageView(showAdd: $showAdd)
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let toast = state.toast {
                ToastBar(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showAdd) {
            AddTokenView(isPresented: $showAdd)
                .environmentObject(state)
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @Binding var tab: AppTab
    @Binding var showAdd: Bool

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
                Text(tab == .manage ? "账号" : "设置")
                    .font(.system(size: 13, weight: .semibold))
                Text(tab == .manage ? "Stable + Next 共享池" : "preferences")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if tab == .manage {
                Button(action: { showAdd = true }) {
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

            Button { tab = (tab == .settings ? .manage : .settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(tab == .settings ? "返回账号" : "设置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            // 仅在 toast 仍是当前那条时清掉
        }
    }
}
