//
//  WindsurfSwitcherApp.swift
//  App
//
//  @main 入口：用 macOS 13+ 原生 MenuBarExtra 装载 SwiftUI 视图。
//
//  彻底告别 Tauri 那套 NSStatusItem + NSPopover + orderFrontRegardless +
//  show-guard + debounce 的脆弱组合——MenuBarExtra(style: .window) 自动
//  处理点击 toggle / 失焦自动关闭 / 跨 Space 显示 / Accessory 激活策略。
//

import SwiftUI
import AppKit

@main
struct WindsurfSwitcherApp: App {
    @StateObject private var state = AppState()

    init() {
        // 关键修复：SwiftPM 裸 binary 默认 activationPolicy=.prohibited，
        // 导致 MenuBarExtra 创建的 NSStatusItem 不显示。强制设 .accessory
        // 让吾成为合法的菜单栏 app（无 dock 图标，但可显示菜单栏 + 弹窗）。
        NSApplication.shared.setActivationPolicy(.accessory)
        FileHandle.standardError.write(Data("[wss] WindsurfSwitcherApp init; activationPolicy=accessory\n".utf8))
        Task { @MainActor [state] in
            await state.bootstrap()
            FileHandle.standardError.write(Data("[wss] bootstrap done; accounts=\(state.accounts.count)\n".utf8))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
                .frame(width: 380, height: 520)
        } label: {
            // MenuBarExtra 的 label 用 systemImage 做模板图，自动跟随浅深色反色。
            // 用 "wind" + 圆形外框，确保在 macOS 菜单栏中可见性高。
            Image(systemName: "wind.circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
