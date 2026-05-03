//
//  AddTokenView.swift
//  App
//
//  添加 token 表单：备注 + token textarea + 提交按钮 + API 提示。
//  改为 inline 子页（不再用 .sheet），消除 menubar popover 失焦关闭问题。
//

import SwiftUI

struct AddTokenView: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    @State private var label: String = ""
    @State private var token: String = ""
    @State private var submitting = false
    @State private var showCurl = false

    private var port: UInt16 { state.relayConfig.apiBindPort }

    var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 备注
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("备注（可选）", icon: "tag")
                TextField("如：备用号 / 工作号", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            // Token
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("devin-session-token", icon: "key.fill")
                ZStack(alignment: .topLeading) {
                    if token.isEmpty {
                        Text("粘贴整段 cookie 值（可含 'devin-session-token$' 前缀）")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $token)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .disableAutocorrection(true)
                }
                .frame(height: 110)
                .background(Color.secondary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(token.isEmpty ? Color.secondary.opacity(0.25) : Color.cyan.opacity(0.45), lineWidth: 1)
                )
                .cornerRadius(6)
            }

            // 抓取教程
            tutorialCard

            // API 入号提示
            apiCard

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(action: submit) {
                    if submitting {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("保存中…")
                        }
                    } else {
                        Label("添加", systemImage: "plus.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSubmit)
            }
        }
        .padding(12)
    }

    // MARK: - cards

    private var tutorialCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.cyan)
                Text("怎么拿这个 token？")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 2) {
                stepRow(num: 1, text: "浏览器登录 windsurf.com")
                stepRow(num: 2, text: "F12 → Application → Cookies → windsurf.com")
                stepRow(num: 3, text: "复制 devin-session-token 的值粘贴上面")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.cyan.opacity(0.06))
        )
    }

    private var apiCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.indigo)
                Text("API 入号 · POST :\(port)/__relay/accounts")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                Button(showCurl ? "收起" : "curl 示例") {
                    withAnimation(.easeInOut(duration: 0.18)) { showCurl.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9))
            }
            if showCurl {
                Text(curlExample)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.indigo.opacity(0.08))
                    )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.indigo.opacity(0.05))
        )
    }

    private var curlExample: String {
        """
        curl -s -X POST http://127.0.0.1:\(port)/__relay/accounts \\
          -H 'content-type: application/json' \\
          -d '{"session_token":"<jwt>","label":"备用"}'
        """
    }

    // MARK: - helpers

    private func fieldLabel(_ s: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    private func stepRow(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("\(num)")
                .font(.system(size: 9, weight: .heavy))
                .frame(width: 13, height: 13)
                .background(Circle().fill(Color.cyan.opacity(0.20)))
                .foregroundStyle(.cyan)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func submit() {
        let t = token
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        Task {
            await state.addToken(t, label: l)
            await MainActor.run {
                submitting = false
                onClose()
            }
        }
    }
}
