//
//  AddTokenView.swift
//  App
//
//  添加 token 表单：备注 + token textarea + 提交按钮。
//  改为 inline 子页（不再用 .sheet），消除 menubar popover 失焦关闭问题。
//

import SwiftUI

struct AddTokenView: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    @State private var label: String = ""
    @State private var token: String = ""
    @State private var submitting = false

    var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("备注（可选）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("如：备用号 / 工作号", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("devin-session-token")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextEditor(text: $token)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 130)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
                    .disableAutocorrection(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("怎么拿这个 token？")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("1. 浏览器登录 windsurf.com\n2. F12 → Application → Cookies → windsurf.com\n3. 复制 devin-session-token 的值粘贴进来")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

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
                        Text("添加")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSubmit)
            }
        }
        .padding(12)
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
