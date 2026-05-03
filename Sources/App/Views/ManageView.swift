//
//  ManageView.swift
//  App
//
//  账号管理页面：状态统计 + API 入口提示 + 卡片列表。
//

import SwiftUI
import Core

struct ManageView: View {
    @EnvironmentObject var state: AppState
    let onAddTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SummaryStrip()
            APIHintBar()
            Divider().opacity(0.3)
            if state.accounts.isEmpty {
                EmptyState(onAddTap: onAddTap)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.accounts) { acc in
                            AccountCardView(account: acc)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

// MARK: - 状态统计条

private struct SummaryStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.summary
        let total = state.accounts.count
        HStack(spacing: 6) {
            statTile(label: "可用", value: "\(s.active)", color: .green, icon: "checkmark.circle.fill")
            statTile(label: "冷却", value: "\(s.cooled)", color: .orange, icon: "snowflake")
            statTile(label: "封禁", value: "\(s.banned)", color: .red, icon: "exclamationmark.octagon.fill")
            statTile(label: "总计", value: "\(total)", color: .blue, icon: "person.2.fill")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func statTile(label: String, value: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 13, weight: .heavy)).foregroundStyle(color)
                Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(
                    colors: [color.opacity(0.10), color.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(color.opacity(0.20), lineWidth: 0.6)
        )
    }
}

// MARK: - API 入口提示

/// 单行折叠/展开的 API 提示——告诉用户外部 curl 也能入号。
private struct APIHintBar: View {
    @EnvironmentObject var state: AppState
    @State private var expanded = false

    private var port: UInt16 { state.relayConfig.apiBindPort }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(.indigo)
                Text("API 入号")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.indigo)
                Text("POST :\(port)/__relay/accounts")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(expanded ? "收起" : "示例") {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9))
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text(curlExample)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.08))
                        )
                    Text("响应 200：{\"ok\":true,\"accountId\":\"<uuid>\",\"added\":true}")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.indigo.opacity(0.04))
    }

    private var curlExample: String {
        """
        curl -s -X POST http://127.0.0.1:\(port)/__relay/accounts \\
          -H 'content-type: application/json' \\
          -d '{"session_token":"<jwt>","label":"备用"}'
        """
    }
}

// MARK: - 空状态

private struct EmptyState: View {
    @EnvironmentObject var state: AppState
    let onAddTap: () -> Void

    private var port: UInt16 { state.relayConfig.apiBindPort }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Spacer(minLength: 16)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(LinearGradient(
                        colors: [.cyan, .indigo],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                Text("还没有账号")
                    .font(.system(size: 14, weight: .semibold))
                Text("两种方式入号：")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    optionCard(
                        icon: "doc.on.clipboard",
                        title: "手动粘贴",
                        subtitle: "浏览器登录 windsurf.com → F12 → Cookies → devin-session-token",
                        accent: .cyan
                    ) {
                        Button("打开添加表单") { onAddTap() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    optionCard(
                        icon: "terminal",
                        title: "API 入号",
                        subtitle: "POST 127.0.0.1:\(port)/__relay/accounts",
                        accent: .indigo
                    ) {
                        Text("body: {\"session_token\":\"<jwt>\"}")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func optionCard<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        accent: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(accent.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: icon)
                    .foregroundStyle(accent)
                    .font(.system(size: 12, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                trailing()
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.08), accent.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.18), lineWidth: 0.7)
        )
    }
}
