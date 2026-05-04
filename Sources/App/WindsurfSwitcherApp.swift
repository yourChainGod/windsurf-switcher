//
//  WindsurfSwitcherApp.swift
//  App
//
//  @main 入口：用 macOS 13+ 原生 MenuBarExtra 装载 SwiftUI 视图。
//  MenuBarExtra(style: .window) 负责点击切换、失焦关闭和跨 Space 显示。
//

import SwiftUI
import AppKit

@main
struct WindsurfSwitcherApp: App {
    @StateObject private var state = AppState()

    init() {
        // 第一步：启用持久化日志（dup2 stdout/stderr → 文件，bootstrap swift-log）。
        // 必须在所有 print / Logger / FileHandle.standardError 之前；幂等。
        AppLogging.bootstrap()

        // 关键修复：SwiftPM 裸 binary 默认 activationPolicy=.prohibited，
        // 导致 MenuBarExtra 创建的 NSStatusItem 不显示。强制设 .accessory
        // 让进程成为合法的菜单栏 app（无 dock 图标，但可显示菜单栏 + 弹窗）。
        NSApplication.shared.setActivationPolicy(.accessory)
        FileHandle.standardError.write(Data("[wss] WindsurfSwitcherApp init; activationPolicy=accessory\n".utf8))
        // 注意：bootstrap 不在这里跑！App.init() 会被 SwiftUI 多次调用。
        // 启动侧由菜单栏 label 的 .task 触发，ContentView.task 再做兜底；
        // AppState.bootstrap 自带幂等守卫。
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
                .frame(width: 380, height: 520)
                .task {
                    await state.bootstrap()
                    FileHandle.standardError.write(Data("[wss] bootstrap done (via ContentView.task); accounts=\(state.accounts.count)\n".utf8))
                }
        } label: {
            // MenuBarExtra 的 label 用 systemImage 做模板图，自动跟随浅深色反色。
            // 用 "wind" + 圆形外框，确保在 macOS 菜单栏中可见性高。
            Image(systemName: "wind.circle.fill")
                .task {
                    await state.bootstrap()
                    FileHandle.standardError.write(Data("[wss] bootstrap done (via MenuBarExtra.label.task); accounts=\(state.accounts.count)\n".utf8))
                }
        }
        .menuBarExtraStyle(.window)
    }
}
