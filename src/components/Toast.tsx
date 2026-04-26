import { CheckCircle2, AlertTriangle, XCircle } from "lucide-react";

export type ToastKind = "success" | "warn" | "error" | "info";

const cfg: Record<
  ToastKind,
  { color: string; icon: React.ComponentType<{ size?: number }> }
> = {
  success: { color: "border-emerald-500/40 text-emerald-200", icon: CheckCircle2 },
  warn: { color: "border-amber-500/40 text-amber-200", icon: AlertTriangle },
  error: { color: "border-rose-500/40 text-rose-200", icon: XCircle },
  info: { color: "border-sky-500/40 text-sky-200", icon: CheckCircle2 },
};

export function Toast({ kind, text }: { kind: ToastKind; text: string }) {
  const { color, icon: Icon } = cfg[kind];
  return (
    <div
      className={`pointer-events-none absolute bottom-9 left-1/2 z-40 flex max-w-[92%] -translate-x-1/2 items-center gap-1.5 rounded-md border bg-neutral-900/95 px-2.5 py-1.5 text-[11px] shadow-xl backdrop-blur ${color}`}
    >
      <Icon size={12} />
      <span className="break-all">{text}</span>
    </div>
  );
}
