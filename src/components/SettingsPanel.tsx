import { useEffect, useState } from "react";
import { ArrowLeft, FolderOpen, ExternalLink } from "lucide-react";
import { openUrl, openPath } from "@tauri-apps/plugin-opener";
import { api } from "../lib/api";

interface Props {
  onClose: () => void;
}

export function SettingsPanel({ onClose }: Props) {
  const [dataDir, setDataDir] = useState<string>("");

  useEffect(() => {
    api.dataDir().then(setDataDir).catch(() => setDataDir(""));
  }, []);

  return (
    <div className="space-y-3 px-2 pt-2">
      <button
        type="button"
        onClick={onClose}
        className="flex items-center gap-1 text-[11px] text-zinc-400 hover:text-white"
      >
        <ArrowLeft size={11} /> 返回
      </button>

      <Section title="数据目录">
        <div className="break-all rounded-md border border-white/10 bg-white/5 p-2 font-mono text-[10px] text-zinc-300">
          {dataDir || "(加载中…)"}
        </div>
        <div className="flex items-center gap-1.5">
          <button
            type="button"
            onClick={() => dataDir && openPath(dataDir)}
            disabled={!dataDir}
            className="flex items-center gap-1 rounded-md border border-white/10 bg-white/5 px-2 py-1 text-[11px] hover:bg-white/10 disabled:opacity-40"
          >
            <FolderOpen size={11} /> 在 Finder 中打开
          </button>
        </div>
      </Section>

      <Section title="关于">
        <div className="text-[11px] leading-relaxed text-zinc-400">
          Windsurf Switcher · 0.1.0
          <br />
          基于 Tauri + React + Tailwind 构建。
          <br />
          通过 GetOneTimeAuthToken 拿一次性 OTT，再用 deep link 触发 Windsurf
          IDE 切号。
        </div>
        <div className="flex flex-col gap-1">
          <LinkItem
            href="https://github.com/dwgx/WindsurfAPI"
            label="参考实现：dwgx/WindsurfAPI"
          />
          <LinkItem
            href="https://windsurf.com"
            label="windsurf.com"
          />
        </div>
      </Section>

      <Section title="安全提示">
        <div className="rounded-md border border-amber-500/20 bg-amber-500/10 p-2 text-[10.5px] leading-relaxed text-amber-100/90">
          devin-session-token 等同于网页登录态，泄露即可被他人冒充。
          所有 token 仅保存在本地 JSON 文件，不会上传任何服务器。
        </div>
      </Section>
    </div>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-1.5">
      <div className="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
        {title}
      </div>
      <div className="space-y-2">{children}</div>
    </div>
  );
}

function LinkItem({ href, label }: { href: string; label: string }) {
  return (
    <button
      type="button"
      onClick={() => openUrl(href)}
      className="flex w-full items-center justify-between rounded-md border border-white/5 bg-white/[0.025] px-2 py-1.5 text-[11px] text-zinc-300 hover:bg-white/10"
    >
      <span className="truncate">{label}</span>
      <ExternalLink size={11} className="shrink-0 text-zinc-500" />
    </button>
  );
}
