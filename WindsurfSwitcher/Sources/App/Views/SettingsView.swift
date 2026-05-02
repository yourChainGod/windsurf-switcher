//
//  SettingsView.swift
//  App
//
//  设置面板 (Phase 2-A)：
//    - 数据目录 + 迁移
//    - Relay 端口监听状态（api / inference / cascade）
//    - Wrapper 双 app 安装状态 + 安装/卸载按钮
//    - 旧 binary 状态
//    - 关于
//

import SwiftUI
import Core
import External
import Wrapper
import Relay
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var legacyPids: [Int32] = []
    @State private var legacyDaemonLoaded: Bool = false
    @State private var dataDirString: String = ""
    @State private var legacyDirString: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                relaySection
                wrapperSection
                dataSection
                legacySection
                aboutSection
            }
            .padding(12)
        }
        .task {
            do {
                dataDirString = try defaultDataDirectory().path
                legacyDirString = (try? legacyDataDirectory().path) ?? "n/a"
            } catch {
                state.toast = Toast(kind: .error, text: "数据目录不可用：\(error)")
            }
            refreshLegacy()
            await state.refreshRelayStatus()
        }
    }

    // MARK: - Sections

    private var relaySection: some View {
        section("RELAY") {
            relayLine(name: "api", running: state.relayStatus.apiRunning,
                      bound: state.relayStatus.apiBoundDescription,
                      upstream: state.relayConfig.apiUpstreamBase)
            relayLine(name: "inference", running: state.relayStatus.inferenceRunning,
                      bound: state.relayStatus.inferenceBoundDescription,
                      upstream: state.relayConfig.inferenceUpstreamBase)
            relayLine(name: "cascade [TLS]", running: state.relayStatus.cascadeRunning,
                      bound: nil,
                      upstream: state.relayConfig.cascadeUpstreamBase,
                      pendingNote: "Phase 2-B（含 swift-certificates 自签 + ALPN h2/h1.1 + :443 forwarder）")
            HStack {
                Button("刷新状态") {
                    Task { await state.refreshRelayStatus() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func relayLine(
        name: String,
        running: Bool,
        bound: String?,
        upstream: String,
        pendingNote: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            statusDot(running)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 11, weight: .medium))
                    if let b = bound {
                        Text(b).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("→ \(upstream)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let note = pendingNote {
                    Text(note).font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
        }
    }

    private var wrapperSection: some View {
        section("WRAPPER（LS BINARY 替换）") {
            ForEach(WindsurfApp.allCases, id: \.self) { app in
                wrapperLine(app: app)
            }
            HStack {
                Button("一键安装两个 app") {
                    Task { await state.installAllWrappers() }
                }
                .controlSize(.small)
                .disabled(state.wrapperBusy)
                Button("重新检测") {
                    state.refreshWrapperStatuses()
                }
                .controlSize(.small)
            }
            Text("安装会向系统申请管理员密码（osascript），同时替换两个 app 的 LS binary 为 sh wrapper。卸载会还原原 binary。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func wrapperLine(app: WindsurfApp) -> some View {
        let st = state.wrapperStatuses[app]
        HStack(alignment: .center, spacing: 6) {
            statusDot(st?.state == .installedMatching)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName).font(.system(size: 11, weight: .medium))
                Text(stateDescription(st))
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor(st))
            }
            Spacer()
            if let st = st, st.state == .installedMatching || st.state == .installedStale {
                Button("卸载") { Task { await state.uninstallWrapper(app) } }
                    .controlSize(.small)
                    .disabled(state.wrapperBusy)
            }
        }
    }

    private func stateDescription(_ st: WrapperStatus?) -> String {
        guard let st = st else { return "未检测" }
        switch st.state {
        case .missing: return "应用未安装"
        case .pristine: return "未安装 wrapper（可一键安装）"
        case .installedMatching: return "已安装（端口 \(st.relayPort)/\(st.inferencePort) 一致）"
        case .installedStale: return "已安装但端口陈旧（需刷新）"
        case .foreign: return "⚠️ 文件被第三方修改，拒绝覆盖"
        }
    }

    private func stateColor(_ st: WrapperStatus?) -> Color {
        guard let st = st else { return .secondary }
        switch st.state {
        case .installedMatching: return .green
        case .pristine, .missing: return .secondary
        case .installedStale: return .orange
        case .foreign: return .red
        }
    }

    private var dataSection: some View {
        section("数据目录") {
            pathRow(label: "新", path: dataDirString)
            pathRow(label: "旧", path: legacyDirString, dim: true)
            HStack {
                Button("在 Finder 中显示") { revealInFinder(dataDirString) }
                    .controlSize(.small)
                Button("迁移旧数据") {
                    Task {
                        do {
                            let r = try DataMigration.migrateLegacy(force: false)
                            if r.alreadyMigrated {
                                state.toast = Toast(kind: .info, text: "已经迁移过；强制覆盖请用 CLI --force")
                            } else if r.importedCount > 0 {
                                state.toast = Toast(kind: .success, text: "已导入 \(r.importedCount) 个账号")
                                await state.reload()
                            } else {
                                state.toast = Toast(kind: .info, text: "无可迁移数据")
                            }
                        } catch {
                            state.toast = Toast(kind: .error, text: "迁移失败：\(error)")
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var legacySection: some View {
        section("旧版本清理") {
            HStack(spacing: 6) {
                statusDot(legacyPids.isEmpty && !legacyDaemonLoaded)
                Text(legacyPids.isEmpty
                     ? "旧 windsurf-switcher 未运行"
                     : "旧 binary 在跑（PID \(legacyPids.map(String.init).joined(separator: ", "))）")
                    .font(.system(size: 11))
            }
            HStack(spacing: 6) {
                statusDot(!legacyDaemonLoaded)
                Text(legacyDaemonLoaded
                     ? "旧 LaunchDaemon 已加载（cascade-port-forward）"
                     : "旧 LaunchDaemon 未加载")
                    .font(.system(size: 11))
            }
            HStack {
                Button("重新检测") { refreshLegacy() }
                    .controlSize(.small)
                if !legacyPids.isEmpty {
                    Button("终止旧 binary") {
                        _ = LegacyCleanup.terminateLegacyBinaries()
                        refreshLegacy()
                        state.toast = Toast(kind: .success, text: "已发送 SIGTERM")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var aboutSection: some View {
        section("关于") {
            Text("WindsurfSwitcher Native · Phase 2-A")
                .font(.system(size: 11, weight: .medium))
            Text("原生 Swift 重铸；Stable + Next 双 app 共享池。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button("退出 App") { state.quit() }
                .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func refreshLegacy() {
        legacyPids = LegacyCleanup.findLegacyPids()
        legacyDaemonLoaded = LegacyCleanup.legacyLaunchDaemonLoaded()
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func pathRow(label: String, path: String, dim: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(dim ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func statusDot(_ ok: Bool) -> some View {
        Circle()
            .fill(ok ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
    }

    private func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
