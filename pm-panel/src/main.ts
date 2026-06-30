import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

interface LinkEntry {
  label?: string | null;
  url?: string | null;
}

interface Session {
  date: string;
  label: string;
}

interface Todo {
  text: string;
  checked: boolean;
  is_focused: boolean;
  depth: number;
  context: string;
  session_index: number;
  line_index: number;
  due_date?: string | null;
  effective_due_date?: string | null;
}

interface FocusedProject {
  project_key: string;
  project_name: string;
  title: string;
  summary: string;
  problem: string;
  goals: string[];
  approach: string;
  links: LinkEntry[];
  learnings: string[];
  sessions: Session[];
  todos: Todo[];
}

let lastProject: FocusedProject | null = null;
let showIncompleteOnly = false;

function section(title: string, body: string): string {
  if (!body.trim()) return "";
  return `<h2 class="section-title">${escapeHtml(title)}</h2><div class="section-body">${escapeHtml(body).replace(/\n/g, "<br>")}</div>`;
}

function escapeHtml(s: string): string {
  const div = document.createElement("div");
  div.textContent = s;
  return div.innerHTML;
}

function escapeAttr(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function isSafeUrl(url: string): boolean {
  const t = url.trim().toLowerCase();
  return t.startsWith("http://") || t.startsWith("https://");
}

/** Strip the scheme and a trailing slash so a bare URL reads as a clean domain/path. */
function prettyUrl(url: string): string {
  return url.replace(/^https?:\/\//i, "").replace(/\/$/, "");
}

function linksSection(entries: LinkEntry[]): string {
  if (!entries.some((l) => l.label || l.url)) return "";
  const items = entries
    .filter((l) => l.label || l.url)
    .map((l) => {
      const label = (l.label ?? "").trim();
      const url = (l.url ?? "").trim();
      if (url && isSafeUrl(url)) {
        const href = escapeAttr(url);
        const text = label || prettyUrl(url);
        const sub =
          label && prettyUrl(url) !== label
            ? `<span class="link-host">${escapeHtml(prettyUrl(url))}</span>`
            : "";
        return `<li class="link-item"><a class="link-anchor" href="${href}" target="_blank" rel="noopener noreferrer">${escapeHtml(text)}</a>${sub}</li>`;
      }
      const text = label && url ? `${label}: ${url}` : label || url;
      return `<li class="link-item"><span class="link-plain">${escapeHtml(text)}</span></li>`;
    });
  return `<h2 class="section-title">Links</h2><ul class="link-list">${items.join("")}</ul>`;
}

function setTitle(text: string): void {
  const titleEl = document.getElementById("project-title");
  if (titleEl) titleEl.textContent = text;
}

function renderContent(data: FocusedProject): void {
  lastProject = data;
  setTitle(data.title.trim() || data.project_name.trim() || "Untitled project");
  const contentEl = document.getElementById("content");
  if (!contentEl) return;

  const blocks: Record<string, string> = {};

  if (data.summary.trim()) {
    blocks.summary = section("Summary", data.summary);
  }
  if (data.problem.trim()) {
    blocks.problem = section("Problem", data.problem);
  }
  if (data.goals.some((g) => g.trim())) {
    blocks.goals = section(
      "Goals",
      data.goals.map((g, i) => `${i + 1}. ${g}`).join("\n"),
    );
  }
  if (data.approach.trim()) {
    blocks.approach = section("Approach", data.approach);
  }
  if (data.links.some((l) => l.label || l.url)) {
    blocks.links = linksSection(data.links);
  }
  if (data.learnings.some((l) => l.trim())) {
    blocks.learnings = section(
      "Learnings",
      data.learnings.filter(Boolean).map((l) => `- ${l}`).join("\n"),
    );
  }
  const filteredTodos = showIncompleteOnly
    ? data.todos.filter((t) => !t.checked)
    : data.todos;
  blocks.todos = renderTasksSection(filteredTodos, data.sessions, showIncompleteOnly);

  (contentEl.querySelector("#summary-block") as HTMLElement).innerHTML =
    blocks.summary ?? "";
  (contentEl.querySelector("#problem-block") as HTMLElement).innerHTML =
    blocks.problem ?? "";
  (contentEl.querySelector("#goals-block") as HTMLElement).innerHTML =
    blocks.goals ?? "";
  (contentEl.querySelector("#approach-block") as HTMLElement).innerHTML =
    blocks.approach ?? "";
  (contentEl.querySelector("#links-block") as HTMLElement).innerHTML =
    blocks.links ?? "";
  (contentEl.querySelector("#learnings-block") as HTMLElement).innerHTML =
    blocks.learnings ?? "";
  const todosBlock = contentEl.querySelector("#todos-block") as HTMLElement;
  todosBlock.innerHTML = blocks.todos ?? "";
  bindTodoListeners(todosBlock);
  bindTasksFilterToggle(todosBlock);

  contentEl.hidden = false;
}

const TODO_INDENT_EM = 1.25;

/** First 10 chars when they look like YYYY-MM-DD, for a <input type="date"> value. */
function dueInputValue(due: string | null | undefined): string {
  if (!due) return "";
  const m = due.match(/^(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : "";
}

function dueChip(t: Todo): string {
  const own = t.due_date ?? null;
  const eff = t.effective_due_date ?? null;
  const seed = dueInputValue(own ?? eff);
  if (own) {
    return `<button type="button" class="todo-due-chip has-due" data-due="${escapeAttr(seed)}" title="Edit due date">${escapeHtml(own.slice(0, 10))}</button>`;
  }
  if (eff) {
    return `<button type="button" class="todo-due-chip inherited" data-due="${escapeAttr(seed)}" title="Inherited due — click to set this task's own">${escapeHtml(eff.slice(0, 10))}</button>`;
  }
  return `<button type="button" class="todo-due-chip empty" data-due="" title="Set due date" aria-label="Set due date">＋date</button>`;
}

function renderTaskRow(t: Todo): string {
  const checked = t.checked ? ' checked' : '';
  return (
    `<div class="todo-row${t.is_focused ? " todo-row-focused" : ""}" data-session-index="${t.session_index}" data-line-index="${t.line_index}" style="padding-left: ${t.depth * TODO_INDENT_EM}em">` +
    `<input type="checkbox" class="todo-checkbox"${checked} aria-label="Toggle task">` +
    `<span class="todo-label" role="button" tabindex="0">${escapeHtml(t.text)}</span>` +
    `<span class="todo-actions">${dueChip(t)}<button type="button" class="todo-add" title="Add task here" aria-label="Add task here">+</button></span>` +
    `</div>`
  );
}

function buildAddEditor(): string {
  return (
    `<div class="todo-editor add-editor">` +
    `<div class="seg" role="group" aria-label="Where to add">` +
    `<button type="button" class="seg-btn" data-pos="before">Before</button>` +
    `<button type="button" class="seg-btn active" data-pos="child">Subtask</button>` +
    `<button type="button" class="seg-btn" data-pos="after">After</button>` +
    `</div>` +
    `<input class="editor-text" type="text" placeholder="Task text" aria-label="Task text">` +
    `<div class="editor-actions">` +
    `<input class="editor-due" type="date" aria-label="Due date">` +
    `<button type="button" class="editor-add">Add</button>` +
    `<button type="button" class="editor-cancel">Cancel</button>` +
    `</div>` +
    `</div>`
  );
}

function buildDueEditor(current: string): string {
  return (
    `<div class="todo-editor due-editor">` +
    `<input class="editor-due" type="date" value="${escapeAttr(current)}" aria-label="Due date">` +
    `<button type="button" class="due-set">Set</button>` +
    `<button type="button" class="due-clear">Clear</button>` +
    `<button type="button" class="editor-cancel">Cancel</button>` +
    `</div>`
  );
}

function renderTasksSection(todos: Todo[], sessions: Session[], incompleteOnly: boolean): string {
  const toggle = `<label class="tasks-filter"><input type="checkbox" class="tasks-filter-incomplete" ${incompleteOnly ? " checked" : ""} aria-label="Show incomplete tasks only"> Incomplete only</label>`;
  const header = `<div class="tasks-section-header"><h2 class="section-title">Tasks</h2>${toggle}</div>`;
  if (todos.length === 0) {
    return `${header}<div class="todo-list"></div>`;
  }
  const bySession = new Map<number, Todo[]>();
  for (const t of todos) {
    const list = bySession.get(t.session_index) ?? [];
    list.push(t);
    bySession.set(t.session_index, list);
  }
  const sessionOrder = [...new Set(todos.map((t) => t.session_index))];
  const parts = sessionOrder.map((sessionIndex) => {
    const sessionTodos = bySession.get(sessionIndex) ?? [];
    const session = sessions[sessionIndex];
    const context = session ? (session.label ? `${session.date} · ${session.label}` : session.date) : "";
    const rows = sessionTodos.map(renderTaskRow).join("");
    const heading = context
      ? `<div class="todo-session-header" aria-hidden="true">${escapeHtml(context)}</div>`
      : "";
    return `${heading}<div class="todo-session-list">${rows}</div>`;
  });
  return `${header}<div class="todo-list">${parts.join("")}</div>`;
}

function bindTasksFilterToggle(container: HTMLElement): void {
  const checkbox = container.querySelector(".tasks-filter-incomplete") as HTMLInputElement | null;
  if (!checkbox) return;
  checkbox.addEventListener("change", () => {
    showIncompleteOnly = checkbox.checked;
    if (lastProject) renderContent(lastProject);
  });
}

function rowPos(el: HTMLElement): { si: number; li: number } | null {
  const row = el.closest(".todo-row") as HTMLElement | null;
  if (!row) return null;
  const si = Number(row.dataset.sessionIndex);
  const li = Number(row.dataset.lineIndex);
  if (Number.isNaN(si) || Number.isNaN(li)) return null;
  return { si, li };
}

function showError(err: unknown): void {
  const errEl = document.getElementById("error");
  if (errEl) errEl.textContent = err instanceof Error ? err.message : String(err);
}

function closeEditors(container: HTMLElement): void {
  container.querySelectorAll(".todo-editor").forEach((e) => e.remove());
}

function bindTodoListeners(container: HTMLElement): void {
  // Handlers are delegated and read the current DOM, so bind once — renderContent reuses the
  // same #todos-block element on every reload, and re-adding would stack duplicate handlers.
  if (container.dataset.bound === "1") return;
  container.dataset.bound = "1";

  container.addEventListener("change", async (e) => {
    const target = e.target as HTMLInputElement;
    if (target.type !== "checkbox" || !target.classList.contains("todo-checkbox")) return;
    const pos = rowPos(target);
    if (!pos) return;
    try {
      await invoke("toggle_todo", { sessionIndex: pos.si, lineIndex: pos.li, checked: target.checked });
      await loadProject();
    } catch (err) {
      showError(err);
    }
  });

  container.addEventListener("keydown", (e) => {
    const target = e.target as HTMLElement;
    if ((e as KeyboardEvent).key === "Enter" && target.classList.contains("editor-text")) {
      e.preventDefault();
      (target.closest(".add-editor")?.querySelector(".editor-add") as HTMLElement | null)?.click();
    }
  });

  container.addEventListener("click", async (e) => {
    const target = e.target as HTMLElement;

    // Move focus by clicking a task's label.
    if (target.classList.contains("todo-label")) {
      const pos = rowPos(target);
      if (!pos) return;
      e.preventDefault();
      try {
        await invoke("set_focus_to", { sessionIndex: pos.si, lineIndex: pos.li });
        await loadProject();
      } catch (err) {
        showError(err);
      }
      return;
    }

    // Open the positional add editor under the row.
    if (target.classList.contains("todo-add")) {
      const row = target.closest(".todo-row") as HTMLElement | null;
      if (!row) return;
      const wasOpen = (row.nextElementSibling as HTMLElement | null)?.classList.contains("add-editor");
      closeEditors(container);
      if (wasOpen) return;
      row.insertAdjacentHTML("afterend", buildAddEditor());
      (row.nextElementSibling?.querySelector(".editor-text") as HTMLInputElement | null)?.focus();
      return;
    }

    // Open the due-date editor under the row.
    if (target.classList.contains("todo-due-chip")) {
      const row = target.closest(".todo-row") as HTMLElement | null;
      if (!row) return;
      const wasOpen = (row.nextElementSibling as HTMLElement | null)?.classList.contains("due-editor");
      closeEditors(container);
      if (wasOpen) return;
      row.insertAdjacentHTML("afterend", buildDueEditor(target.dataset.due ?? ""));
      (row.nextElementSibling?.querySelector(".editor-due") as HTMLInputElement | null)?.focus();
      return;
    }

    // Segmented position selector.
    if (target.classList.contains("seg-btn")) {
      target.closest(".seg")?.querySelectorAll(".seg-btn").forEach((b) => b.classList.remove("active"));
      target.classList.add("active");
      return;
    }

    if (target.classList.contains("editor-cancel")) {
      closeEditors(container);
      return;
    }

    // Submit a positional add.
    if (target.classList.contains("editor-add")) {
      const editor = target.closest(".add-editor") as HTMLElement | null;
      const row = editor?.previousElementSibling as HTMLElement | null;
      const pos = row ? rowPos(row) : null;
      if (!editor || !pos) return;
      const text = (editor.querySelector(".editor-text") as HTMLInputElement).value.trim();
      if (!text) return;
      const due = (editor.querySelector(".editor-due") as HTMLInputElement).value || null;
      const kind = (editor.querySelector(".seg-btn.active") as HTMLElement | null)?.dataset.pos ?? "child";
      try {
        await invoke("add_todo", {
          text,
          due,
          position: { kind, sessionIndex: pos.si, lineIndex: pos.li },
        });
        await loadProject();
      } catch (err) {
        showError(err);
      }
      return;
    }

    // Set or clear a due date.
    if (target.classList.contains("due-set") || target.classList.contains("due-clear")) {
      const editor = target.closest(".due-editor") as HTMLElement | null;
      const row = editor?.previousElementSibling as HTMLElement | null;
      const pos = row ? rowPos(row) : null;
      if (!editor || !pos) return;
      const due = target.classList.contains("due-clear")
        ? null
        : (editor.querySelector(".editor-due") as HTMLInputElement).value || null;
      try {
        await invoke("set_due", { sessionIndex: pos.si, lineIndex: pos.li, due });
        await loadProject();
      } catch (err) {
        showError(err);
      }
      return;
    }
  });
}

async function loadProject(): Promise<void> {
  const errEl = document.getElementById("error");
  const contentEl = document.getElementById("content");
  if (!errEl) return;

  // Only blank the panel on the very first load. On reloads (which fire on every cloud-sync
  // touch of the notes file) we keep the last render painted and swap it in place once the new
  // data arrives — no flash to empty while `pm notes show` round-trips over Google Drive.
  const firstLoad = lastProject === null;
  if (firstLoad && contentEl) contentEl.hidden = true;

  try {
    const result = await invoke<FocusedProject>("get_focused_project");
    errEl.textContent = "";
    renderContent(result);
  } catch (e) {
    // Ride out transient reload failures (a cloud-sync blip mid-read) by keeping the last good
    // render; only surface the empty state when there's nothing shown yet.
    if (!firstLoad) return;
    const msg = e instanceof Error ? e.message : String(e);
    setTitle("No project");
    if (
      msg.includes("No projectKey") ||
      msg.includes("focused.json") ||
      msg.includes("Invalid projectKey")
    ) {
      errEl.textContent =
        "No focused project. Set one from Raycast (List Projects / View Project).";
    } else {
      errEl.textContent = msg;
    }
  }
}

/** Resize the window's height to fit the rendered content (width stays fixed). */
async function fitToContent(): Promise<void> {
  const panel = document.querySelector(".panel") as HTMLElement | null;
  if (!panel) return;
  const desired = Math.ceil(panel.scrollHeight) + 2;
  const max = Math.floor(window.screen.availHeight * 0.95);
  const height = Math.min(desired, max);
  try {
    await invoke("set_panel_height", { height });
  } catch (err) {
    showError(err);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  loadProject();
  document
    .getElementById("resize-grip")
    ?.addEventListener("dblclick", () => void fitToContent());
  listen("pm:project-data-changed", () => {
    loadProject();
  });
  // Escape closes an open inline editor first, otherwise dismisses the panel.
  window.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    const openEditor = document.querySelector(".todo-editor");
    if (openEditor) {
      openEditor.remove();
      return;
    }
    invoke("hide_panel").catch(() => {});
  });
});
