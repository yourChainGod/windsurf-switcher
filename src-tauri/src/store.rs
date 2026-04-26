//! 账号持久化
//!
//! 数据文件路径：
//!   macOS: ~/Library/Application Support/com.windsurf.switcher/accounts.json
//!
//! 写入策略：写入 .tmp 后 rename，保证不会半截。

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};

use crate::windsurf::{JwtInfo, PlanStatus};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    /// 用户填的别名（可选；为空时显示 email 或 session_id 前缀）
    #[serde(default)]
    pub label: String,
    /// 真正的 cookie 值（JWT），切号 / 查询用量都靠它
    pub session_token: String,
    #[serde(default)]
    pub jwt_info: Option<JwtInfo>,
    #[serde(default)]
    pub status: Option<PlanStatus>,
    pub added_at: i64,
    #[serde(default)]
    pub last_switched_at: Option<i64>,
    #[serde(default)]
    pub last_error: Option<String>,
}

impl Account {
    pub fn new(session_token: String, label: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            label,
            jwt_info: Some(crate::windsurf::decode_jwt_info(&session_token)),
            session_token,
            status: None,
            added_at: chrono::Utc::now().timestamp(),
            last_switched_at: None,
            last_error: None,
        }
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct StoreFile {
    #[serde(default = "default_version")]
    version: u32,
    #[serde(default)]
    accounts: Vec<Account>,
}

fn default_version() -> u32 {
    1
}

pub struct Store {
    path: PathBuf,
    inner: Mutex<StoreFile>,
}

impl Store {
    pub fn open() -> Result<Self> {
        let dir = data_dir().context("locate data dir")?;
        fs::create_dir_all(&dir).with_context(|| format!("create {:?}", dir))?;
        let path = dir.join("accounts.json");
        let file = if path.exists() {
            let raw = fs::read_to_string(&path)
                .with_context(|| format!("read {:?}", path))?;
            serde_json::from_str::<StoreFile>(&raw).unwrap_or_default()
        } else {
            StoreFile::default()
        };
        Ok(Self {
            path,
            inner: Mutex::new(file),
        })
    }

    pub fn list(&self) -> Vec<Account> {
        self.inner.lock().unwrap().accounts.clone()
    }

    pub fn upsert(&self, account: Account) -> Result<()> {
        {
            let mut s = self.inner.lock().unwrap();
            if let Some(existing) = s.accounts.iter_mut().find(|a| a.id == account.id) {
                *existing = account;
            } else if let Some(existing) = s
                .accounts
                .iter_mut()
                .find(|a| a.session_token == account.session_token)
            {
                // 同一个 token 视作同一账号，复用 id
                let mut merged = account;
                merged.id = existing.id.clone();
                merged.added_at = existing.added_at;
                *existing = merged;
            } else {
                s.accounts.push(account);
            }
        }
        self.save()
    }

    pub fn get(&self, id: &str) -> Option<Account> {
        self.inner
            .lock()
            .unwrap()
            .accounts
            .iter()
            .find(|a| a.id == id)
            .cloned()
    }

    pub fn delete(&self, id: &str) -> Result<()> {
        {
            let mut s = self.inner.lock().unwrap();
            s.accounts.retain(|a| a.id != id);
        }
        self.save()
    }

    pub fn update<F>(&self, id: &str, f: F) -> Result<Option<Account>>
    where
        F: FnOnce(&mut Account),
    {
        let updated = {
            let mut s = self.inner.lock().unwrap();
            let account = s.accounts.iter_mut().find(|a| a.id == id);
            match account {
                None => None,
                Some(a) => {
                    f(a);
                    Some(a.clone())
                }
            }
        };
        if updated.is_some() {
            self.save()?;
        }
        Ok(updated)
    }

    fn save(&self) -> Result<()> {
        let snapshot = {
            let s = self.inner.lock().unwrap();
            serde_json::to_string_pretty(&*s).context("serialize store")?
        };
        atomic_write(&self.path, snapshot.as_bytes())
    }
}

fn atomic_write(target: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = target.with_extension("json.tmp");
    fs::write(&tmp, bytes).with_context(|| format!("write {:?}", tmp))?;
    fs::rename(&tmp, target).with_context(|| format!("rename {:?} -> {:?}", tmp, target))?;
    Ok(())
}

fn data_dir() -> Option<PathBuf> {
    // dirs::config_dir 在 macOS 上是 ~/Library/Application Support，足够。
    dirs::config_dir().map(|p| p.join("com.windsurf.switcher"))
}
