/** Format a Date for storage (YYYY-MM-DD or YYYY-MM-DD HH:mm). */
export function formatDueForStorage(d: Date): string {
  const dateStr = d.toISOString().slice(0, 10);
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
  if (Math.abs(diffDays) < 30) return rtf.format(diffDays, "day");
  if (Math.abs(diffDays) < 365) return rtf.format(Math.round(diffDays / 30), "month");
  return rtf.format(Math.round(diffDays / 365), "year");
}
