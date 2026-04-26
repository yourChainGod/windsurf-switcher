import { invoke } from "@tauri-apps/api/core";

export interface JwtInfo {
  sessionId?: string | null;
  email?: string | null;
  userId?: string | null;
  expiresAt?: number | null;
  issuedAt?: number | null;
}

/// 对应 Rust 端 PlanStatus（GetPlanStatus protobuf 解析后的标准化结构）
///
/// 同时承载两套度量：
///   1. 百分比配额（dailyPercent / weeklyPercent）：面向 IDE 内 Cascade chat 等高频调用
///   2. 月度 credits（prompt / flow / flex）：面向 Codex agent 调用
export interface PlanStatus {
  planName?: string | null;
  planStart?: number | null;
  planEnd?: number | null;

  /// 日配额剩余百分比（0-100）
  dailyPercent?: number | null;
  /// 周配额剩余百分比（0-100）
  weeklyPercent?: number | null;
  dailyResetAt?: number | null;
  weeklyResetAt?: number | null;

  promptUsed?: number | null;
  promptLimit?: number | null;
  promptRemaining?: number | null;

  flowUsed?: number | null;
  flowLimit?: number | null;
  flowRemaining?: number | null;

  flexUsed?: number | null;
  flexRemaining?: number | null;

  fetchedAt?: number;
}

export interface Account {
  id: string;
  label: string;
  sessionToken: string;
  jwtInfo?: JwtInfo | null;
  status?: PlanStatus | null;
  addedAt: number;
  lastSwitchedAt?: number | null;
  lastError?: string | null;
}

export interface AccountView extends Account {
  displayName: string;
}

export interface SwitchResult {
  deepLink: string;
  ottPreview: string;
}

export const api = {
  list: () => invoke<AccountView[]>("list_accounts"),
  add: (sessionToken: string, label?: string) =>
    invoke<AccountView>("add_account", { sessionToken, label }),
  refresh: (id: string) => invoke<AccountView>("refresh_account", { id }),
  remove: (id: string) => invoke<void>("delete_account", { id }),
  rename: (id: string, label: string) =>
    invoke<AccountView>("update_label", { id, label }),
  switch: (id: string) => invoke<SwitchResult>("switch_account", { id }),
  dataDir: () => invoke<string>("data_dir_path"),
  quit: () => invoke<void>("quit_app"),
  hideWindow: () => invoke<void>("hide_window"),
};
