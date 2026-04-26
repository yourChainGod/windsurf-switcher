//! Windsurf Switcher 主入口
//!
//! macOS 菜单栏小窗模式：
//!   - Dock 图标隐藏（ActivationPolicy::Accessory）
//!   - 主窗口默认 hidden，点击 Tray 在图标下方弹出
//!   - 窗口失焦自动隐藏
//!   - 右键 Tray 弹原生菜单（刷新 / 设置 / 关于 / 退出）

mod commands;
mod proto;
mod store;
mod windsurf;

use std::sync::Arc;
use tauri::{
    image::Image,
    menu::{Menu, MenuEvent, MenuItemBuilder, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager, WebviewWindow,
};

const TRAY_ID: &str = "main-tray";
const MAIN_WINDOW: &str = "main";

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let store = Arc::new(store::Store::open().expect("init store"));

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            // 第二实例启动时，把第一个实例的窗口弹出来
            if let Some(win) = app.get_webview_window(MAIN_WINDOW) {
                show_window(&win);
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_positioner::init())
        .manage(store)
        .invoke_handler(tauri::generate_handler![
            commands::list_accounts,
            commands::add_account,
            commands::refresh_account,
            commands::delete_account,
            commands::update_label,
            commands::switch_account,
            commands::data_dir_path,
            commands::quit_app,
            commands::hide_window,
        ])
        // 注意：失焦自动隐藏的判定权放在前端（src/App.tsx 的 blur + debounce
        // + document.hasFocus() 二次校验）。这里不监听 WindowEvent::Focused，
        // 避免 webview 内部 UI 抖动（如 chevron 重渲染）误触发隐藏。
        .setup(|app| {
            // macOS：当作 Accessory，Dock 不出图标
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            build_tray(app)?;

            // 启动时不弹出窗口；保持 hidden 状态。
            if let Some(win) = app.get_webview_window(MAIN_WINDOW) {
                let _ = win.hide();
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error running windsurf-switcher");
}

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let handle = app.handle();

    // 原生菜单（右键弹）：显示窗口、刷新、退出
    let show = MenuItemBuilder::new("打开 Windsurf Switcher")
        .id("show")
        .build(handle)?;
    let refresh = MenuItemBuilder::new("刷新所有账号")
        .id("refresh-all")
        .build(handle)?;
    let separator = PredefinedMenuItem::separator(handle)?;
    let about = MenuItemBuilder::new("关于").id("about").build(handle)?;
    let quit = MenuItemBuilder::new("退出").id("quit").build(handle)?;

    let menu = Menu::with_items(
        handle,
        &[&show, &refresh, &separator, &about, &quit],
    )?;

    let icon = tray_template_icon();

    let _tray = TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .icon_as_template(true)
        .tooltip("Windsurf Switcher")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(handle_menu_event)
        .on_tray_icon_event(|tray, event| {
            // 让 positioner 记录 Tray 矩形（macOS 菜单栏定位用）
            tauri_plugin_positioner::on_tray_event(tray.app_handle(), &event);

            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if let Some(win) = tray.app_handle().get_webview_window(MAIN_WINDOW) {
                    toggle_window(&win);
                }
            }
        })
        .build(handle)?;

    Ok(())
}

fn handle_menu_event(handle: &tauri::AppHandle, event: MenuEvent) {
    match event.id.as_ref() {
        "show" => {
            if let Some(win) = handle.get_webview_window(MAIN_WINDOW) {
                show_window(&win);
            }
        }
        "refresh-all" => {
            let _ = handle.emit("refresh-all", ());
            if let Some(win) = handle.get_webview_window(MAIN_WINDOW) {
                show_window(&win);
            }
        }
        "about" => {
            let _ = handle.emit("show-about", ());
            if let Some(win) = handle.get_webview_window(MAIN_WINDOW) {
                show_window(&win);
            }
        }
        "quit" => handle.exit(0),
        _ => {}
    }
}

fn toggle_window(win: &WebviewWindow) {
    match win.is_visible() {
        Ok(true) => {
            let _ = win.hide();
        }
        _ => show_window(win),
    }
}

fn show_window(win: &WebviewWindow) {
    use tauri_plugin_positioner::{Position, WindowExt};
    // 定位到 Tray 图标下方居中（macOS）；其他平台 fallback 到右下
    #[cfg(target_os = "macos")]
    let _ = win.move_window(Position::TrayCenter);
    #[cfg(not(target_os = "macos"))]
    let _ = win.move_window(Position::TrayBottomCenter);

    let _ = win.show();
    let _ = win.set_focus();
}

/// 嵌入的 Tray 模板图标（黑色 + alpha，macOS 自动反色）
fn tray_template_icon() -> Image<'static> {
    static BYTES: &[u8] = include_bytes!("../icons/tray.png");
    Image::from_bytes(BYTES).expect("decode tray.png")
}



