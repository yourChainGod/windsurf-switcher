import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  Plus,
  RefreshCw,
  Power,
  Settings as SettingsIcon,
  CheckCircle2,
  AlertTriangle,
  X,
} from "lucide-react";
import { api, type AccountView } from "./lib/api";
import { AccountCard } from "./components/AccountCard";
import { AddTokenDialog } from "./components/AddTokenDialog";
import { SettingsPanel } from "./components/SettingsPanel";
import { Toast, type ToastKind } from "./components/Toast";

type View = "list" | "settings";

export default function App() {
  const [accounts, setAccounts] = useState<AccountView[]>([]);
  const [view, setView] = useState<View>("list");
  const [adding, setAdding] = useState(false);
  const [refreshingAll, setRefreshingAll] = useState(false);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [toast, setToast] = useState<{ kind: ToastKind; text: string } | null>(
    null,
  );
  const toastTimer = useRef<number | undefined>(undefined);

  const showToast = useCallback((kind: ToastKind, text: string) => {
    setToast({ kind, text });
    window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 2200);
  }, []);

  const reload = useCallback(async () => {
    try {
      const items = await api.list();
      setAccounts(items);
    } catch (e) {
      showToast("error", `读取账号失败：${e}`);
    }
  }, [showToast]);

  useEffect(() => {
    reload();
  }, [reload]);

  // 后端事件：账号变化
  useEffect(() => {
    const un = listen("accounts-changed", () => reload());
    return () => {
      un.then((f) => f());
    };
  }, [reload]);

  // Tray 菜单：刷新所有
  useEffect(() => {
    const un = listen("refresh-all", () => {
      void refreshAll();
    });
    return () => {
      un.then((f) => f());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Tray 菜单：关于（暂用 Settings 页代替）
  useEffect(() => {
    const un = listen("show-about", () => setView("settings"));
    return () => {
      un.then((f) => f());
    };
  }, []);

  const handleAdd = useCallback(
    async (token: string, label: string) => {
      try {
        const acc = await api.add(token, label || undefined);
        showToast("success", `已添加：${acc.displayName}`);
        setAdding(false);
        return true;
      } catch (e) {
        showToast("error", `添加失败：${e}`);
        return false;
      }
    },
    [showToast],
  );

  const handleSwitch = useCallback(
    async (id: string) => {
      setActiveId(id);
      try {
        const r = await api.switch(id);
        showToast(
          "success",
          `已触发切号：OTT ${r.ottPreview} → 已发送至 Windsurf`,
        );
      } catch (e) {
        showToast("error", `切号失败：${e}`);
      } finally {
        setActiveId(null);
      }
    },
    [showToast],
  );

  const handleRefresh = useCallback(
    async (id: string) => {
      try {
        const acc = await api.refresh(id);
        if (acc.lastError) showToast("warn", `刷新有错误：${acc.lastError}`);
        else showToast("success", `已刷新：${acc.displayName}`);
      } catch (e) {
        showToast("error", `刷新失败：${e}`);
      }
    },
    [showToast],
  );

  const handleDelete = useCallback(
    async (id: string) => {
      try {
        await api.remove(id);
      } catch (e) {
        showToast("error", `删除失败：${e}`);
      }
    },
    [showToast],
  );

  const handleRename = useCallback(
    async (id: string, label: string) => {
      try {
        await api.rename(id, label);
        showToast("success", `已更新备注`);
      } catch (e) {
        showToast("error", `更新失败：${e}`);
      }
    },
    [showToast],
  );

  const refreshAll = useCallback(async () => {
    setRefreshingAll(true);
    try {
      const list = await api.list();
      // 串行刷新而非 Promise.all：5 个账号同时打 web-backend.windsurf.com
      // 会触发服务端限流 → 大半数 timeout / 403。串行 + 微小 gap 反而更快拿到全数据。
      let okCount = 0;
      let failCount = 0;
      for (const a of list) {
        try {
          await api.refresh(a.id);
          okCount++;
        } catch (e) {
          failCount++;
          console.warn("refresh", a.id, e);
        }
      }
      if (failCount === 0) {
        showToast("success", `已刷新 ${okCount} 个账号`);
      } else {
        showToast(
          "warn",
          `刷新完成：成功 ${okCount}，失败 ${failCount}（详情见账号卡片）`,
        );
      }
    } finally {
      setRefreshingAll(false);
    }
  }, [showToast]);

  const sorted = useMemo(
    () =>
      [...accounts].sort((a, b) => {
        const at = a.lastSwitchedAt ?? a.addedAt;
        const bt = b.lastSwitchedAt ?? b.addedAt;
        return bt - at;
      }),
    [accounts],
  );

  return (
    <div className="relative flex h-full flex-col overflow-hidden rounded-[14px] border border-white/10 bg-neutral-900/95 text-zinc-100 shadow-2xl backdrop-blur-xl dark:bg-neutral-900/95">
      <div className="tray-arrow" />

      <Header
        view={view}
        onAdd={() => setAdding(true)}
        onRefreshAll={() => refreshAll()}
        onToggleSettings={() => setView(view === "settings" ? "list" : "settings")}
        onHide={() => api.hideWindow().catch(() => {})}
        refreshingAll={refreshingAll}
      />

      <main className="flex-1 overflow-y-auto px-2 pb-2">
        {view === "list" ? (
          sorted.length === 0 ? (
            <EmptyState onAdd={() => setAdding(true)} />
          ) : (
            <ul className="flex flex-col gap-1.5">
              {sorted.map((a) => (
                <li key={a.id}>
                  <AccountCard
                    account={a}
                    busy={activeId === a.id}
                    onSwitch={() => handleSwitch(a.id)}
                    onRefresh={() => handleRefresh(a.id)}
                    onDelete={() => handleDelete(a.id)}
                    onRename={(label) => handleRename(a.id, label)}
                  />
                </li>
              ))}
            </ul>
          )
        ) : (
          <SettingsPanel onClose={() => setView("list")} />
        )}
      </main>

      <Footer accountCount={sorted.length} />

      <AddTokenDialog
        open={adding}
        onClose={() => setAdding(false)}
        onSubmit={handleAdd}
      />

      {toast && <Toast kind={toast.kind} text={toast.text} />}
    </div>
  );
}

function Header({
  view,
  onAdd,
  onRefreshAll,
  onToggleSettings,
  onHide,
  refreshingAll,
}: {
  view: View;
  onAdd: () => void;
  onRefreshAll: () => void;
  onToggleSettings: () => void;
  onHide: () => void;
  refreshingAll: boolean;
}) {
  return (
    <header className="drag-region flex items-center justify-between gap-2 border-b border-white/10 px-3 pt-3 pb-2">
      <div className="flex items-center gap-2">
        <div className="flex h-7 w-7 items-center justify-center rounded-md bg-gradient-to-br from-sky-500 to-indigo-500 text-[11px] font-bold tracking-tight text-white shadow">
          WS
        </div>
        <div className="leading-tight">
          <div className="text-[13px] font-semibold">Windsurf Switcher</div>
          <div className="text-[10px] text-zinc-400">menubar · multi-account</div>
        </div>
      </div>
      <div className="no-drag flex items-center gap-1">
        <IconBtn
          title="添加账号"
          onClick={onAdd}
          disabled={view === "settings"}
        >
          <Plus size={15} />
        </IconBtn>
        <IconBtn
          title="刷新全部"
          onClick={onRefreshAll}
          disabled={refreshingAll || view === "settings"}
        >
          <RefreshCw
            size={14}
            className={refreshingAll ? "animate-spin" : ""}
          />
        </IconBtn>
        <IconBtn
          title="设置"
          onClick={onToggleSettings}
          active={view === "settings"}
        >
          <SettingsIcon size={14} />
        </IconBtn>
        <IconBtn title="收起窗口 (Esc)" onClick={onHide}>
          <X size={14} />
        </IconBtn>
      </div>
    </header>
  );
}

function IconBtn({
  children,
  title,
  onClick,
  disabled,
  active,
}: {
  children: React.ReactNode;
  title: string;
  onClick?: () => void;
  disabled?: boolean;
  active?: boolean;
}) {
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      disabled={disabled}
      className={`flex h-7 w-7 items-center justify-center rounded-md border border-transparent text-zinc-300 transition hover:bg-white/10 hover:text-white disabled:cursor-not-allowed disabled:opacity-40 ${
        active ? "border-white/15 bg-white/10 text-white" : ""
      }`}
    >
      {children}
    </button>
  );
}

function Footer({ accountCount }: { accountCount: number }) {
  const onQuit = () => api.quit();
  return (
    <footer className="flex items-center justify-between border-t border-white/10 bg-neutral-950/40 px-3 py-1.5 text-[10px] text-zinc-400">
      <div className="flex items-center gap-1.5">
        {accountCount > 0 ? (
          <CheckCircle2 size={11} className="text-emerald-400" />
        ) : (
          <AlertTriangle size={11} className="text-amber-400" />
        )}
        <span>{accountCount} 个账号</span>
      </div>
      <button
        type="button"
        onClick={onQuit}
        className="flex items-center gap-1 rounded px-1.5 py-0.5 hover:bg-white/10 hover:text-white"
        title="退出应用"
      >
        <Power size={10} /> 退出
      </button>
    </footer>
  );
}

function EmptyState({ onAdd }: { onAdd: () => void }) {
  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-2.5 py-12 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full border border-white/10 bg-white/5">
        <Plus size={20} className="text-zinc-300" />
      </div>
      <div className="text-[13px] font-medium">还没有账号</div>
      <div className="px-6 text-[11px] leading-relaxed text-zinc-400">
        粘贴 Windsurf 网页登录后从浏览器抓到的
        <br />
        <code className="rounded bg-white/5 px-1 py-0.5 text-[10px]">
          devin-session-token
        </code>
        ，即可一键切号
      </div>
      <button
        type="button"
        onClick={onAdd}
        className="mt-1 rounded-md bg-sky-500 px-3 py-1 text-[12px] font-medium text-white shadow hover:bg-sky-400"
      >
        + 添加 Token
      </button>
    </div>
  );
}
