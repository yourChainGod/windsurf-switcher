// 防止 macOS release 弹出额外的命令行窗口
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    windsurf_switcher_lib::run();
}
