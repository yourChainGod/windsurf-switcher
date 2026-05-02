//
//  SettingsView.swift
//  App
//
//  设置面板：数据目录 / 旧 binary 状态 / Wrapper 状态（占位 phase 2 接通）/ 关于。
//

import SwiftUI
import Core
import External
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

                section("Wrapper（待 Phase 2）") {
                    Text("LS binary 替换 + cascade-relay 三端口将在 Phase 2 接通。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Stable: \(WindsurfApp.stable.isInstalled ? "已安装" : "未安装")")
                        .font(.system(size: 11))
                    Text("Next:   \(WindsurfApp.next.isInstalled ? "已安装" : "未安装")")
                        .font(.system(size: 11))
                }

                section("关于") {
                    Text("WindsurfSwitcher Native · Phase 1-B")
                        .font(.system(size: 11, weight: .medium))
                    Text("原生 Swift 重铸，替代 rust+tauri 旧版。Stable + Next 双 app 共享池。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button("退出 App") { state.quit() }
                        .controlSize(.small)
                }
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
        }
    }

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
