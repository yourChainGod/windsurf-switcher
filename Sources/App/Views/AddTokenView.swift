//
//  AddTokenView.swift
//  App
//
//  添加 token 表单：备注 + token textarea + 提交按钮 + API 提示。
//  改为 inline 子页（不再用 .sheet），消除 menubar popover 失焦关闭问题。
//
//  支持批量：textarea 可一行一个 token，也可粘贴含多个 token 的大段文本，
//  自动用 JWT 正则识别 + 去重 + 与已有账号比对，再批量入号。
//

import SwiftUI

/// 从一段任意文本里解析出 token 列表（裸 JWT 优先；无 JWT 时降级为按行）。
/// 在文件作用域定义，方便在 body 计算属性里用，且便于将来加单测。
fileprivate enum TokenParser {
    /// JWT 三段：`eyJ<header>.<payload>.<sig>`。base64url 字符集 + 必须以 eyJ 开头。
    /// 注意：第三段允许为空（少数实现 unsigned JWT），但我们要求至少 1 个字符以减少误匹配。
    private static let jwtPattern = #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#

    /// 解析输入文本，返回去重后的 token 列表（保持出现顺序）。
    static func parse(_ input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 优先：用 JWT 正则从大文本里抠出所有 JWT。
        if let regex = try? NSRegularExpression(pattern: jwtPattern) {
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var seen = Set<String>()
                var out: [String] = []
                for m in matches {
                    let s = ns.substring(with: m.range)
                    if seen.insert(s).inserted { out.append(s) }
                }
                return out
            }
        }

        // 降级：按行/分隔符切，每个非空段当作一个 token（兼容 cookie 完整值粘贴）。
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ","))
        let pieces = trimmed.components(separatedBy: separators)
        var seen = Set<String>()
        var out: [String] = []
        for raw in pieces {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}

struct AddTokenView: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    @State private var label: String = ""
    @State private var token: String = ""
    @State private var submitting = false
    @State private var showCurl = false

    private var port: UInt16 { state.relayConfig.apiBindPort }

    /// 当前输入解析出的去重 token 列表。
    private var parsedTokens: [String] { TokenParser.parse(token) }

    var canSubmit: Bool {
        !parsedTokens.isEmpty && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 备注
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("备注（可选）", icon: "tag")
                TextField("如：备用号 / 工作号（批量入号时所有新号共用此备注）", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            // Token
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    fieldLabel("devin-session-token", icon: "key.fill")
                    Spacer()
                    tokenCountBadge
                }
                ZStack(alignment: .topLeading) {
                    if token.isEmpty {
                        Text("一行一个 token；或粘贴含多个 token 的大段文本，自动识别去重")
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
                .frame(height: 130)
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
                        let n = parsedTokens.count
                        Label(n > 1 ? "添加 \(n) 个" : "添加", systemImage: "plus.circle.fill")
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

    /// 右上角小徽标：实时显示解析到几个 token。无内容时隐藏。
    @ViewBuilder
    private var tokenCountBadge: some View {
        let n = parsedTokens.count
        if n > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 9))
                Text("识别到 \(n) 个 token")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.green)
        } else if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("未识别到 token")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.orange)
        } else {
            EmptyView()
        }
    }

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
                stepRow(num: 3, text: "复制 devin-session-token 的值粘贴上面（多账号一行一个）")
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
        let tokens = parsedTokens
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokens.isEmpty else { return }
        submitting = true
        Task {
            // 单 token 走旧路径（toast 显示 displayName）；多 token 走批量路径（toast 显示汇总）。
            if tokens.count == 1 {
                await state.addToken(tokens[0], label: l)
            } else {
                await state.addTokens(tokens, label: l)
            }
            await MainActor.run {
                submitting = false
                onClose()
            }
        }
    }
}
