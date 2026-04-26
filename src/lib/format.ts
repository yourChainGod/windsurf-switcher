export function formatPercent(v?: number | null): string {
  if (v == null || Number.isNaN(v)) return "-";
  return `${v.toFixed(1)}%`;
}

export function formatNumber(v?: number | null, digits = 1): string {
  if (v == null || Number.isNaN(v)) return "-";
  return v.toLocaleString(undefined, {
    maximumFractionDigits: digits,
  });
}

export function formatTimeFromUnix(ts?: number | null): string {
  if (!ts) return "-";
  const date = new Date(ts * 1000);
  return date.toLocaleString();
}

export function formatRelative(ts?: number | null): string {
  if (!ts) return "-";
  const now = Date.now() / 1000;
  const diff = ts - now;
  const abs = Math.abs(diff);

  if (abs < 60) return diff > 0 ? "即将" : "刚刚";
  const minutes = Math.round(abs / 60);
  if (abs < 3600)
    return diff > 0 ? `${minutes} 分钟后` : `${minutes} 分钟前`;
  const hours = Math.round(abs / 3600);
  if (abs < 86400) return diff > 0 ? `${hours} 小时后` : `${hours} 小时前`;
  const days = Math.round(abs / 86400);
  return diff > 0 ? `${days} 天后` : `${days} 天前`;
}

export function shortToken(token: string, head = 6, tail = 6): string {
  if (token.length <= head + tail + 1) return token;
  return `${token.slice(0, head)}…${token.slice(-tail)}`;
}

/// 紧凑的重置倒计时：12m / 3h / 5d
export function compactCountdown(ts?: number | null): string {
  if (!ts) return "-";
  const diff = ts - Date.now() / 1000;
  if (diff <= 0) return "已到期";
  const m = Math.floor(diff / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  return `${d}d`;
}

export function initials(name: string): string {
  if (!name) return "·";
  const trimmed = name.trim();
  if (trimmed.length === 0) return "·";
  // 邮箱 -> 取 @ 前
  const base = trimmed.includes("@") ? trimmed.split("@")[0] : trimmed;
  const parts = base.split(/[\s._-]+/).filter(Boolean);
  if (parts.length === 0) return base[0].toUpperCase();
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}
