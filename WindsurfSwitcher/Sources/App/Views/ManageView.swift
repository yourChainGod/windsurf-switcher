//
//  ManageView.swift
//  App
//
//  账号列表：顶部 segment 过滤 [全部 / Windsurf / Next] + 滚动列表。
//

import SwiftUI
import Core

struct ManageView: View {
    @EnvironmentObject var state: AppState
    let onAddTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            SummaryStrip()
            Divider().opacity(0.3)
            if state.filteredAccounts.isEmpty {
                EmptyState(onAddTap: onAddTap)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.filteredAccounts) { acc in
                            AccountCardView(account: acc)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

private struct FilterBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Picker("App", selection: $state.filter) {
            ForEach(AppFilter.allCases) { f in
                Text(f.displayName).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

private struct SummaryStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.summary
        HStack(spacing: 10) {
            statChip(label: "可用", value: s.active, color: .green)
            statChip(label: "冷却", value: s.cooled, color: .orange)
            statChip(label: "封禁", value: s.banned, color: .red)
            Spacer()
            Text("共 \(state.filteredAccounts.count)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func statChip(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(value) \(label)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyState: View {
    let onAddTap: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("还没有账号")
                .font(.system(size: 13, weight: .medium))
            Text("粘贴 windsurf.com 登录后从浏览器抓到的\ndevin-session-token 即可开始切号")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("+ 添加 Token") { onAddTap() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
