//! Tauri 命令：前端通过 invoke 调用
//!
//! 命名一律 snake_case，前端直接 invoke('list_accounts') 之类。

use serde::Serialize;
use std::sync::Arc;
use tauri::{Emitter, Manager, State};
use tauri_plugin_opener::OpenerExt;

use crate::{
    store::{Account, Store},
    windsurf,
};

/// 把 anyhow::Error 转为前端能展示的字符串
fn err_to_string(e: anyhow::Error) -> String {
    format!("{:#}", e)
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AccountView {
    #[serde(flatten)]
    account: Account,
    /// 优先 label > email > session_id 前 8 位 > id 前 8 位
    display_name: String,
}

impl AccountView {
    pub fn from(account: Account) -> Self {
        let display_name = if !account.label.is_empty() {
            account.label.clone()
        } else if let Some(info) = &account.jwt_info {
            info.email
                .clone()
                .or_else(|| info.session_id.clone().map(|s| short(&s, 12)))
                .unwrap_or_else(|| short(&account.id, 8))
        } else {
            short(&account.id, 8)
        };
        Self {
            account,
            display_name,
        }
    }
}

fn short(s: &str, n: usize) -> String {
    if s.len() <= n {
        s.to_string()
    } else {
        format!("{}…", &s[..n])
    }
}

pub type StoreState<'a> = State<'a, Arc<Store>>;

#[tauri::command]
pub fn list_accounts(store: StoreState<'_>) -> Vec<AccountView> {
    store.list().into_iter().map(AccountView::from).collect()
}

#[tauri::command]
pub async fn add_account(
    store: StoreState<'_>,
    session_token: String,
    label: Option<String>,
    app: tauri::AppHandle,
) -> Result<AccountView, String> {
    let token = session_token.trim().to_string();
    if token.is_empty() {
        return Err("session_token 为空".into());
    }
    let mut account = Account::new(token.clone(), label.unwrap_or_default());

    // 先 upsert 一次，UI 立刻可见
    store.upsert(account.clone()).map_err(err_to_string)?;
    let _ = app.emit("accounts-changed", ());

    // 再异步拉一次用量；失败也保存，标记 last_error
    match windsurf::get_plan_status(&token).await {
        Ok(status) => {
            account.status = Some(status);
            account.last_error = None;
        }
        Err(e) => {
            account.last_error = Some(format!("{:#}", e));
        }
    }
    store.upsert(account.clone()).map_err(err_to_string)?;
    let _ = app.emit("accounts-changed", ());
    Ok(AccountView::from(account))
}

#[tauri::command]
pub async fn refresh_account(
    store: StoreState<'_>,
    id: String,
    app: tauri::AppHandle,
) -> Result<AccountView, String> {
    let account = store.get(&id).ok_or_else(|| "账号不存在".to_string())?;
    let result = windsurf::get_plan_status(&account.session_token).await;
    let updated = store
        .update(&id, |a| match result {
            Ok(status) => {
                a.status = Some(status);
                a.last_error = None;
                a.jwt_info = Some(windsurf::decode_jwt_info(&a.session_token));
            }
            Err(e) => {
                a.last_error = Some(format!("{:#}", e));
            }
        })
        .map_err(err_to_string)?
        .ok_or_else(|| "账号不存在".to_string())?;
    let _ = app.emit("accounts-changed", ());
    Ok(AccountView::from(updated))
}

#[tauri::command]
pub fn delete_account(
    store: StoreState<'_>,
    id: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    store.delete(&id).map_err(err_to_string)?;
    let _ = app.emit("accounts-changed", ());
    Ok(())
}

#[tauri::command]
pub fn update_label(
    store: StoreState<'_>,
    id: String,
    label: String,
    app: tauri::AppHandle,
) -> Result<AccountView, String> {
    let updated = store
        .update(&id, |a| {
            a.label = label;
        })
        .map_err(err_to_string)?
        .ok_or_else(|| "账号不存在".to_string())?;
    let _ = app.emit("accounts-changed", ());
    Ok(AccountView::from(updated))
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SwitchResult {
    pub deep_link: String,
    pub ott_preview: String,
}

#[tauri::command]
pub async fn switch_account(
    store: StoreState<'_>,
    id: String,
    app: tauri::AppHandle,
) -> Result<SwitchResult, String> {
    let account = store.get(&id).ok_or_else(|| "账号不存在".to_string())?;
    let ott = windsurf::get_one_time_auth_token(&account.session_token)
        .await
        .map_err(err_to_string)?;

    // URL-encode OTT（RFC 3986 unreserved 之外都转义）
    let encoded: String = url::form_urlencoded::byte_serialize(ott.as_bytes()).collect();
    let deep_link = format!(
        "windsurf://codeium.windsurf#state=switch&access_token={}",
        encoded
    );

    app.opener()
        .open_url(&deep_link, None::<&str>)
        .map_err(|e| format!("open deep link: {}", e))?;

    let _ = store.update(&id, |a| {
        a.last_switched_at = Some(chrono::Utc::now().timestamp());
    });
    let _ = app.emit("accounts-changed", ());

    Ok(SwitchResult {
        deep_link,
        ott_preview: short(&ott, 12),
    })
}

#[tauri::command]
pub fn data_dir_path(app: tauri::AppHandle) -> Result<String, String> {
    let path = app
        .path()
        .config_dir()
        .map_err(|e| e.to_string())?
        .join("com.windsurf.switcher");
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
pub fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

#[tauri::command]
pub fn hide_window(app: tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.hide();
    }
}
