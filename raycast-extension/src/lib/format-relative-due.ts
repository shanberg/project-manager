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
  const raw = s.trim();
  const cleaned = raw.replace(/^due:\s*/i, "");
  const iso = cleaned.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (iso) {
    const timePart = cleaned.match(/\s+(\d{1,2}):(\d{2})(?::(\d{2}))?/);
    if (timePart) {
      const h = timePart[1].padStart(2, "0");
      const m = timePart[2];
      const sec = (timePart[3] ?? "00").padStart(2, "0");
      return new Date(`${iso[0]}T${h}:${m}:${sec}`);
    }
    return new Date(`${iso[0]}T12:00:00`);
  }
  const dmy = cleaned.match(/^(\d{1,2})-(\d{1,2})-(\d{4})/);
  if (dmy) {
    const [, d, m, y] = dmy;
    const timePart = cleaned.match(/\s+(\d{1,2}):(\d{2})/);
    if (timePart) {
      return new Date(
        `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}T${timePart[1].padStart(2, "0")}:${timePart[2]}:00`,
      );
    }
    return new Date(
      `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}T12:00:00`,
    );
  }
  return null;
}

/**
 * Whole calendar days from `from` to `to`, counting date boundaries rather than elapsed milliseconds.
 *
 * `Math.floor(ms / 86400000)` is the obvious version and it is wrong twice a year: an hour gained or
 * lost to daylight saving moves a boundary, so a date exactly seven days out reports six. Swift's
 * `Calendar.dateComponents` counts boundaries, so this has to as well or the two drift for a fortnight
 * every spring.
 */
function calendarDaysBetween(from: Date, to: Date): number {
  const a = Date.UTC(from.getFullYear(), from.getMonth(), from.getDate());
  const b = Date.UTC(to.getFullYear(), to.getMonth(), to.getDate());
  return Math.round((b - a) / 86400000);
}

export function formatRelativeDueShort(dueDate: string): string {
  const date = parseDueDate(dueDate);
  if (!date) return dueDate.slice(0, 10);

  const days = calendarDaysBetween(new Date(), date);
  if (days === 0) return "today";
  if (days === 1) return "tomorrow";
  if (days === -1) return "yesterday";
  if (days >= 2 && days < 7) return `in ${days}d`;
  if (days <= -2 && days > -7) return `${-days}d ago`;
  if (days >= 7 && days < 30) return `in ${Math.trunc(days / 7)}w`;
  if (days <= -7 && days >= -29) return `${Math.trunc(-days / 7)}w ago`;
  if (days >= 30 && days < 365) return `in ${Math.trunc(days / 30)}mo`;
  if (days <= -30 && days >= -364) return `${Math.trunc(-days / 30)}mo ago`;
  if (days >= 365) return `in ${Math.trunc(days / 365)}y`;
  return `${Math.trunc(-days / 365)}y ago`;
}

/** True when the due date is in the past (overdue). Invalid/unparseable dates are not overdue. */
export function isDueOverdue(dueDate: string): boolean {
  const date = parseDueDate(dueDate);
  if (!date) return false;
  return date.getTime() < Date.now();
}
