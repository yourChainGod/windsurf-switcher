import { useState } from "react";
import {
  Pencil,
  RefreshCw,
  Trash2,
  Loader2,
  AlertCircle,
  CheckCircle2,
} from "lucide-react";
import type { AccountView } from "../lib/api";
import { compactCountdown, initials } from "../lib/format";

interface Props {
  account: AccountView;
  busy?: boolean;
  onSwitch: () => void;
  onRefresh: () => void;
  onDelete: () => void;
  onRename: (label: string) => void;
}

/// 单行紧凑卡片：
///   - 整张卡片可点击 = 切号（主操作直达，少一步）
///   - hover 时右上角浮出三枚小图标（刷新 / 重命名 / 删除），点击 stopPropagation
///   - 双击主区域 = 进入重命名编辑
///   - 不再有展开/折叠交互（消除 chevron click → blur 抖动 bug）
export function AccountCard({
  account,
  busy,
  onSwitch,
  onRefresh,
  onDelete,
  onRename,
}: Props) {
  const [renaming, setRenaming] = useState(false);
  const [labelDraft, setLabelDraft] = useState(account.label || "");
  const [confirmDelete, setConfirmDelete] = useState(false);

  const status = account.status;
  const jwt = account.jwtInfo;
  const hasError = !!account.lastError;
  const subtitle = jwt?.email ?? jwt?.sessionId ?? "";

  const cardClick = () => {
    if (renaming || busy || confirmDelete) return;
    onSwitch();
  };

  const stop = (e: React.SyntheticEvent) => e.stopPropagation();

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={cardClick}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          cardClick();
        }
      }}
      title="点击切号；双击名字改备注"
      className={`group relative flex cursor-pointer items-center gap-2.5 rounded-lg border p-2.5 transition ${
        busy
          ? "border-sky-500/60 bg-sky-500/10"
          : hasError
            ? "border-amber-500/40 bg-amber-500/5 hover:bg-amber-500/10"
            : "border-white/10 bg-white/[0.04] hover:border-white/20 hover:bg-white/[0.07]"
      }`}
    >
      <Avatar
        name={account.displayName}
        busy={busy}
        recently={!!account.lastSwitchedAt && fresh(account.lastSwitchedAt)}
      />

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <div className="min-w-0 flex-1">
            {renaming ? (
              <input
                autoFocus
                value={labelDraft}
                onClick={stop}
                onChange={(e) => setLabelDraft(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    onRename(labelDraft.trim());
                    setRenaming(false);
                  } else if (e.key === "Escape") {
                    e.stopPropagation();
                    setRenaming(false);
                    setLabelDraft(account.label || "");
                  }
                }}
                onBlur={() => {
                  onRename(labelDraft.trim());
                  setRenaming(false);
                }}
                placeholder={jwt?.email ?? "账号备注"}
                className="w-full rounded bg-white/10 px-1.5 py-0.5 text-[12.5px] font-medium outline-none ring-1 ring-sky-500/40"
              />
            ) : (
              <div
                onDoubleClick={(e) => {
                  e.stopPropagation();
                  setRenaming(true);
                }}
                className="flex items-center gap-1.5 truncate text-[12.5px] font-medium leading-tight"
              >
                <span className="truncate">{account.displayName}</span>
                {status?.planName && (
                  <span className="shrink-0 rounded bg-emerald-500/15 px-1 py-px text-[8.5px] font-semibold uppercase tracking-wide text-emerald-300">
                    {status.planName}
                  </span>
                )}
                {hasError && (
                  <span
                    className="shrink-0 text-amber-400"
                    title={account.lastError ?? undefined}
                  >
                    <AlertCircle size={10} />
                  </span>
                )}
              </div>
            )}
            {subtitle && (
              <div className="mt-0.5 truncate text-[10px] leading-tight text-zinc-400">
                {subtitle}
              </div>
            )}
          </div>
          <div className="shrink-0">
            {busy ? (
              <Loader2 size={14} className="animate-spin text-sky-400" />
            ) : (
              <span className="text-[10px] text-zinc-500 transition group-hover:text-sky-400">
                点击切号 →
              </span>
            )}
          </div>
        </div>

        {(status?.dailyPercent != null ||
          status?.weeklyPercent != null ||
          status?.promptLimit != null ||
          status?.flowLimit != null) && (
          <div className="mt-2 space-y-1">
            {status?.dailyPercent != null && (
              <PercentRow
                label="D"
                title="日配额"
                remainingPercent={status.dailyPercent}
                resetAt={status.dailyResetAt ?? status.planEnd}
              />
            )}
            {status?.weeklyPercent != null && (
              <PercentRow
                label="W"
                title="周配额"
                remainingPercent={status.weeklyPercent}
                resetAt={status.weeklyResetAt ?? status.planEnd}
              />
            )}
            {(status?.promptLimit != null || status?.flowLimit != null) && (
              <div className="flex gap-2 truncate pt-0.5 text-[9px] text-zinc-500">
                {status?.promptLimit != null && (
                  <span title="Prompt credits（提示词额度，月度）">
                    prompt{" "}
                    <span className="text-zinc-300">
                      {formatNumberCompact(status.promptUsed ?? 0)}/
                      {formatNumberCompact(status.promptLimit)}
                    </span>
                  </span>
                )}
                {status?.flowLimit != null && (
                  <span title="Flow credits（智能体额度，月度）">
                    flow{" "}
                    <span className="text-zinc-300">
                      {formatNumberCompact(status.flowUsed ?? 0)}/
                      {formatNumberCompact(status.flowLimit)}
                    </span>
                  </span>
                )}
              </div>
            )}
          </div>
        )}
      </div>

      <div className="absolute right-1 top-1 flex items-center gap-0.5 opacity-0 transition group-hover:opacity-100">
        <MiniBtn
          title="刷新用量"
          onClick={(e) => {
            stop(e);
            onRefresh();
          }}
        >
          <RefreshCw size={10} />
        </MiniBtn>
        <MiniBtn
          title="重命名"
          onClick={(e) => {
            stop(e);
            setRenaming(true);
          }}
        >
          <Pencil size={10} />
        </MiniBtn>
        {confirmDelete ? (
          <>
            <MiniBtn
              title="确认删除"
              variant="danger"
              onClick={(e) => {
                stop(e);
                onDelete();
              }}
            >
              <CheckCircle2 size={10} />
            </MiniBtn>
            <MiniBtn
              title="取消"
              onClick={(e) => {
                stop(e);
                setConfirmDelete(false);
              }}
            >
              ✕
            </MiniBtn>
          </>
        ) : (
          <MiniBtn
            title="删除账号"
            variant="danger"
            onClick={(e) => {
              stop(e);
              setConfirmDelete(true);
              window.setTimeout(() => setConfirmDelete(false), 4000);
            }}
          >
            <Trash2 size={10} />
          </MiniBtn>
        )}
      </div>
    </div>
  );
}

function Avatar({
  name,
  busy,
  recently,
}: {
  name: string;
  busy?: boolean;
  recently?: boolean;
}) {
  return (
    <div className="relative shrink-0">
      <div
        className={`flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-fuchsia-500 text-[11px] font-bold text-white shadow ring-1 ring-white/20 ${
          busy ? "scale-95 opacity-60" : ""
        }`}
        title={name}
      >
        {initials(name)}
      </div>
      {recently && !busy && (
        <span
          className="absolute -bottom-0.5 -right-0.5 block h-2.5 w-2.5 rounded-full bg-emerald-400 ring-2 ring-neutral-900"
          title="最近使用"
        />
      )}
    </div>
  );
}

/// 用量行（语义：bar 长度 = 已用百分比，越长越告急）。
///
/// 入参 `remainingPercent` 是 Windsurf 后端原始的"剩余百分比"（0-100），
/// UI 内部转换为"已用 = 100 - remaining"，文字也直接显示已用值——
/// 这样 0% 一眼就是"没用过"、98% 一眼就是"快耗尽"，跟 prompt/flow credit
/// 的 used/limit 展示语义一致，避免"100% 看起来像满额上限"的歧义。
function PercentRow({
  label,
  title,
  remainingPercent,
  resetAt,
}: {
  label: string;
  title?: string;
  remainingPercent: number;
  resetAt?: number | null;
}) {
  const remaining = Math.min(100, Math.max(0, remainingPercent));
  const used = 100 - remaining;
  const color =
    used >= 90
      ? "bg-rose-400"
      : used >= 70
        ? "bg-amber-400"
        : "bg-emerald-400";
  return (
    <div
      className="flex items-center gap-1.5 text-[10px] leading-none"
      title={title ? `${title}（已用 ${used}% / 剩余 ${remaining}%）` : undefined}
    >
      <span className="w-3 shrink-0 font-semibold uppercase tracking-wide text-zinc-500">
        {label}
      </span>
      <div className="relative h-1.5 flex-1 overflow-hidden rounded-full bg-white/10">
        <div
          className={`absolute inset-y-0 left-0 ${color} transition-all`}
          style={{ width: `${used}%` }}
        />
      </div>
      <span className="w-10 shrink-0 text-right font-medium tabular-nums text-zinc-200">
        {used}%
      </span>
      <span
        className="w-9 shrink-0 text-right tabular-nums text-zinc-500"
        title={
          resetAt
            ? `重置于 ${new Date(resetAt * 1000).toLocaleString()}`
            : undefined
        }
      >
        ↻ {compactCountdown(resetAt)}
      </span>
    </div>
  );
}

/// 大数字压缩：12345 → 12.3k；999 → 999
function formatNumberCompact(n: number): string {
  if (n < 1000) return String(n);
  if (n < 1000_000) {
    const k = n / 1000;
    return k >= 100 ? `${Math.round(k)}k` : `${k.toFixed(1).replace(/\.0$/, "")}k`;
  }
  const m = n / 1000_000;
  return `${m.toFixed(1).replace(/\.0$/, "")}M`;
}

function MiniBtn({
  children,
  title,
  onClick,
  variant,
}: {
  children: React.ReactNode;
  title: string;
  onClick: (e: React.MouseEvent) => void;
  variant?: "danger";
}) {
  const cls =
    variant === "danger"
      ? "text-rose-300 hover:bg-rose-500/30 hover:text-rose-100"
      : "text-zinc-300 hover:bg-white/15 hover:text-white";
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      className={`flex h-5 w-5 items-center justify-center rounded text-[10px] ${cls}`}
    >
      {children}
    </button>
  );
}

/// 1 分钟内切过号视为"刚使用"
function fresh(unix: number): boolean {
  return Date.now() / 1000 - unix < 60;
}
