/** Format a Date for storage (YYYY-MM-DD or YYYY-MM-DD HH:mm). Uses local date/time. */
export function formatDueForStorage(d: Date): string {
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  const dateStr = `${y}-${mo}-${day}`;
  const hours = d.getHours();
  const mins = d.getMinutes();
  if (hours === 12 && mins === 0) return dateStr;
  const h = String(hours).padStart(2, "0");
  const m = String(mins).padStart(2, "0");
  return `${dateStr} ${h}:${m}`;
}

export function parseDueDate(s: string): Date | null {
  const iso = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (iso) {
    const timePart = s.match(/\s+(\d{1,2}):(\d{2})(?::(\d{2}))?/);
    if (timePart) {
      const h = timePart[1].padStart(2, "0");
      const m = timePart[2];
      const sec = (timePart[3] ?? "00").padStart(2, "0");
      return new Date(`${iso[0]}T${h}:${m}:${sec}`);
    }
    return new Date(`${iso[0]}T12:00:00`);
  }
  const dmy = s.match(/^(\d{1,2})-(\d{1,2})-(\d{4})/);
  if (dmy) {
    const [_, d, m, y] = dmy;
    const timePart = s.match(/\s+(\d{1,2}):(\d{2})/);
    if (timePart) {
      return new Date(`${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}T${timePart[1].padStart(2, "0")}:${timePart[2]}:00`);
    }
    return new Date(`${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}T12:00:00`);
  }
  return null;
}

/** Format date for display: "Mar 15" or "Mar 15, 2026" if different year. */
function formatDatePrecise(d: Date, includeYear?: boolean): string {
  const now = new Date();
  if (includeYear ?? d.getFullYear() !== now.getFullYear()) {
    return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  }
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export function formatRelativeDue(dueDate: string): string {
  const date = parseDueDate(dueDate);
  if (!date) return dueDate;
  const now = new Date();
  const diffMs = date.getTime() - now.getTime();
  const diffSec = Math.round(diffMs / 1000);
  const diffMin = Math.round(diffMs / (60 * 1000));
  const diffHours = Math.round(diffMs / (60 * 60 * 1000));
  const diffDays = Math.round(diffMs / (24 * 60 * 60 * 1000));

  const rtf = new Intl.RelativeTimeFormat("en", { numeric: "auto" });

  if (Math.abs(diffSec) < 60) return rtf.format(diffSec, "second");
  if (Math.abs(diffMin) < 60) return rtf.format(diffMin, "minute");
  if (Math.abs(diffHours) < 24) return rtf.format(diffHours, "hour");
  if (diffDays === 1) return "tomorrow";
  if (diffDays === -1) return "yesterday";
  if (diffDays > 0 && diffDays < 7) return rtf.format(diffDays, "day");
  if (diffDays < 0 && diffDays > -7) return rtf.format(diffDays, "day");
  if (Math.abs(diffDays) < 14) return formatDatePrecise(date);
  if (Math.abs(diffDays) < 365) return formatDatePrecise(date, true);
  return formatDatePrecise(date, true);
}

/** Short format for menubar: "2d", "tomorrow", "3/15", etc. Relative only, no time. */
export function formatRelativeDueShort(dueDate: string): string {
  const date = parseDueDate(dueDate);
  if (!date) return dueDate.slice(0, 8);
  const now = new Date();
  const diffMs = date.getTime() - now.getTime();
  const diffDays = Math.round(diffMs / (24 * 60 * 60 * 1000));

  if (diffDays === 0) return "today";
  if (diffDays === 1) return "tomorrow";
  if (diffDays === -1) return "yesterday";
  if (diffDays > 0 && diffDays < 7) return `${diffDays}d`;
  if (diffDays < 0 && diffDays > -7) return `${diffDays}d`;
  if (diffDays >= 7 && diffDays < 30) return `${Math.round(diffDays / 7)}w`;
  if (diffDays <= -7 && diffDays > -30) return `${Math.round(diffDays / 7)}w`;
  if (Math.abs(diffDays) < 365) {
    const m = date.getMonth() + 1;
    const d = date.getDate();
    return `${m}/${d}`;
  }
  const y = date.getFullYear();
  const m = date.getMonth() + 1;
  const d = date.getDate();
  return `${m}/${d}/${y.toString().slice(-2)}`;
}

/**
 * Schedule-extension-style relative time for menubar: "in 15m", "in 2h", "tomorrow", "in 2d".
 * Compact units (m/h/d/w) with "in " prefix for future; "X ago" for past.
 */
export function formatDueForMenubar(dueDate: string): string {
  const date = parseDueDate(dueDate);
  if (!date) return dueDate.slice(0, 8);
  const now = new Date();
  const diffMs = date.getTime() - now.getTime();
  const minutes = Math.floor(diffMs / 60000);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (minutes > -60 && minutes < 60) {
    if (minutes >= 0) return minutes === 0 ? "now" : `in ${minutes}m`;
    return `${-minutes}m ago`;
  }
  if (hours > -24 && hours < 24) {
    const m = Math.abs(minutes % 60);
    const h = Math.abs(hours);
    if (hours >= 0) return m !== 0 ? `in ${h}h ${m}m` : `in ${h}h`;
    return m !== 0 ? `${h}h ${m}m ago` : `${h}h ago`;
  }
  if (days === 1) return "tomorrow";
  if (days === -1) return "yesterday";
  if (days > 0 && days < 7) return `in ${days}d`;
  if (days < 0 && days > -7) return `${-days}d ago`;
  if (days >= 7 && days < 30) return `in ${Math.round(days / 7)}w`;
  if (days <= -7 && days > -30) return `${Math.round(-days / 7)}w ago`;
  if (Math.abs(days) < 365) {
    const m = date.getMonth() + 1;
    const d = date.getDate();
    return days >= 0 ? `in ${m}/${d}` : `${m}/${d}`;
  }
  const y = date.getFullYear();
  const month = date.getMonth() + 1;
  const day = date.getDate();
  return days >= 0 ? `in ${month}/${day}/${y.toString().slice(-2)}` : `${month}/${day}/${y.toString().slice(-2)}`;
}
