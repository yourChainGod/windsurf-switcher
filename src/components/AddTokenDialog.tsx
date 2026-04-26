import { useEffect, useRef, useState } from "react";
import { Loader2, Cookie, X } from "lucide-react";

interface Props {
  open: boolean;
  onClose: () => void;
  onSubmit: (token: string, label: string) => Promise<boolean>;
}

export function AddTokenDialog({ open, onClose, onSubmit }: Props) {
  const [token, setToken] = useState("");
  const [label, setLabel] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    if (open) {
      setToken("");
      setLabel("");
      setSubmitting(false);
      // 等动画结束再 focus
      setTimeout(() => inputRef.current?.focus(), 80);
    }
  }, [open]);

  if (!open) return null;

  const handleSubmit = async () => {
    const trimmed = token.trim();
    if (!trimmed) return;
    setSubmitting(true);
    const ok = await onSubmit(trimmed, label.trim());
    setSubmitting(false);
    if (ok) {
      setToken("");
      setLabel("");
    }
  };

  return (
    <div className="absolute inset-0 z-30 flex items-stretch justify-center bg-black/55 backdrop-blur-sm">
      <div className="m-3 flex w-full flex-col rounded-xl border border-white/15 bg-neutral-900 p-3 shadow-2xl">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-1.5 text-[12.5px] font-semibold">
            <Cookie size={14} className="text-amber-400" />
            添加 devin-session-token
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded p-1 text-zinc-400 hover:bg-white/10 hover:text-white"
          >
            <X size={14} />
          </button>
        </div>

        <div className="mt-2 space-y-2">
          <label className="block">
            <span className="mb-0.5 block text-[10.5px] text-zinc-400">
              备注（可选）
            </span>
            <input
              type="text"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              placeholder="如：备用号 / 工作号"
              className="w-full rounded-md border border-white/10 bg-white/5 px-2 py-1.5 text-[12px] outline-none focus:border-sky-500/60 focus:ring-1 focus:ring-sky-500/30"
            />
          </label>

          <label className="block">
            <span className="mb-0.5 block text-[10.5px] text-zinc-400">
              devin-session-token（JWT）
            </span>
            <textarea
              ref={inputRef}
              value={token}
              onChange={(e) => setToken(e.target.value)}
              rows={6}
              spellCheck={false}
              placeholder="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...."
              className="w-full resize-none rounded-md border border-white/10 bg-white/5 px-2 py-1.5 font-mono text-[10.5px] leading-relaxed outline-none focus:border-sky-500/60 focus:ring-1 focus:ring-sky-500/30"
            />
          </label>

          <div className="rounded-md border border-white/5 bg-white/[0.025] p-2 text-[10.5px] leading-relaxed text-zinc-400">
            <div className="font-medium text-zinc-300">怎么拿这个 token？</div>
            <ol className="mt-0.5 list-decimal pl-4">
              <li>浏览器登录 windsurf.com</li>
              <li>F12 → Application → Cookies → windsurf.com</li>
              <li>
                复制 <code className="text-amber-300">devin-session-token</code>{" "}
                的值粘贴进来
              </li>
            </ol>
          </div>
        </div>

        <div className="mt-3 flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md px-2.5 py-1.5 text-[11.5px] text-zinc-300 hover:bg-white/10"
          >
            取消
          </button>
          <button
            type="button"
            disabled={submitting || !token.trim()}
            onClick={handleSubmit}
            className="flex items-center gap-1 rounded-md bg-sky-500 px-3 py-1.5 text-[11.5px] font-medium text-white shadow hover:bg-sky-400 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {submitting && <Loader2 size={11} className="animate-spin" />}
            {submitting ? "正在拉取用量…" : "添加并验证"}
          </button>
        </div>
      </div>
    </div>
  );
}
