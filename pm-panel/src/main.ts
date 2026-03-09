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
}

interface ListableProject {
  project_key: string;
  name: string;
}

interface ListProjectsResult {
  recent: ListableProject[];
  other: ListableProject[];
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

function linksSection(entries: LinkEntry[]): string {
  if (!entries.some((l) => l.label || l.url)) return "";
  const lines = entries
    .filter((l) => l.label || l.url)
    .map((l) => {
      const label = (l.label ?? "").trim();
      const url = (l.url ?? "").trim();
      const linkText = label || url || "";
      if (url && isSafeUrl(url)) {
        const display = escapeHtml(linkText || url);
        const href = escapeAttr(url);
        const anchor = `<a href="${href}" target="_blank" rel="noopener noreferrer">${display}</a>`;
        return label && linkText !== url ? `- ${escapeHtml(label)}: ${anchor}` : `- ${anchor}`;
      }
      if (label && url) return `- ${escapeHtml(label)}: ${escapeHtml(url)}`;
      if (url) return `- ${escapeHtml(url)}`;
      return `- ${escapeHtml(label)}`;
    });
  const body = lines.join("<br>");
  return `<h2 class="section-title">Links</h2><div class="section-body">${body}</div>`;
}

function renderContent(data: FocusedProject): void {
  lastProject = data;
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
  if (data.todos.length > 0) {
    bindTodoListeners(todosBlock);
  }
  bindTasksFilterToggle(todosBlock);

  contentEl.hidden = false;
}

const TODO_INDENT_EM = 1.25;

function renderTaskRow(t: Todo): string {
  const checked = t.checked ? ' checked' : '';
  return (
    `<div class="todo-row${t.is_focused ? " todo-row-focused" : ""}" data-session-index="${t.session_index}" data-line-index="${t.line_index}" style="padding-left: ${t.depth * TODO_INDENT_EM}em">` +
    `<input type="checkbox" class="todo-checkbox"${checked} aria-label="Toggle task">` +
    `<span class="todo-label" role="button" tabindex="0">${escapeHtml(t.text)}</span>` +
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

function bindTodoListeners(container: HTMLElement): void {
  container.addEventListener("change", async (e) => {
    const target = e.target as HTMLInputElement;
    if (target.type !== "checkbox" || !target.classList.contains("todo-checkbox")) return;
    const row = target.closest(".todo-row") as HTMLElement | null;
    if (!row) return;
    const si = Number(row.dataset.sessionIndex);
    const li = Number(row.dataset.lineIndex);
    if (Number.isNaN(si) || Number.isNaN(li)) return;
    try {
      await invoke("toggle_todo", { sessionIndex: si, lineIndex: li, checked: target.checked });
      await loadProject();
    } catch (err) {
      console.error(err);
    }
  });
  container.addEventListener("click", async (e) => {
    const target = e.target as HTMLElement;
    if (!target.classList.contains("todo-label")) return;
    const row = target.closest(".todo-row") as HTMLElement | null;
    if (!row) return;
    const si = Number(row.dataset.sessionIndex);
    const li = Number(row.dataset.lineIndex);
    if (Number.isNaN(si) || Number.isNaN(li)) return;
    e.preventDefault();
    try {
      await invoke("set_focus_to", { sessionIndex: si, lineIndex: li });
      await loadProject();
    } catch (err) {
      console.error(err);
    }
  });
}

function populateProjectPicker(data: ListProjectsResult, selectedKey: string): void {
  const picker = document.getElementById("project-picker") as HTMLSelectElement | null;
  if (!picker) return;
  picker.innerHTML = "";
  const empty = document.createElement("option");
  empty.value = "";
  empty.textContent = "—";
  picker.appendChild(empty);
  if (data.recent.length > 0) {
    const group = document.createElement("optgroup");
    group.label = "Recent";
    for (const p of data.recent) {
      const opt = document.createElement("option");
      opt.value = p.project_key;
      opt.textContent = p.name;
      group.appendChild(opt);
    }
    picker.appendChild(group);
  }
  if (data.other.length > 0) {
    const group = document.createElement("optgroup");
    group.label = "All projects";
    for (const p of data.other) {
      const opt = document.createElement("option");
      opt.value = p.project_key;
      opt.textContent = p.name;
      group.appendChild(opt);
    }
    picker.appendChild(group);
  }
  picker.value = selectedKey;
}

async function loadProject(): Promise<void> {
  const picker = document.getElementById("project-picker") as HTMLSelectElement | null;
  const errEl = document.getElementById("error");
  const contentEl = document.getElementById("content");
  if (!picker || !errEl) return;

  errEl.textContent = "";
  picker.disabled = true;
  if (contentEl) contentEl.hidden = true;

  let projectList: ListProjectsResult = { recent: [], other: [] };
  try {
    projectList = await invoke<ListProjectsResult>("list_projects");
  } catch {
    // list_projects can fail if config is missing; picker stays empty
  }

  try {
    const result = await invoke<FocusedProject>("get_focused_project");
    populateProjectPicker(projectList, result.project_key);
    picker.disabled = false;
    renderContent(result);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    populateProjectPicker(projectList, "");
    picker.disabled = false;
    if (
      msg.includes("No projectKey") ||
      msg.includes("focused.json") ||
      msg.includes("Invalid projectKey")
    ) {
      errEl.textContent =
        "No focused project. Choose one above or set from Raycast (List Projects / View Project).";
    } else {
      errEl.textContent = msg;
    }
  }
}

function bindProjectPicker(): void {
  const picker = document.getElementById("project-picker") as HTMLSelectElement | null;
  if (!picker) return;
  picker.addEventListener("change", async () => {
    const key = picker.value;
    if (!key) return;
    try {
      await invoke("set_focused_project", { project_key: key });
      await loadProject();
    } catch (e) {
      const errEl = document.getElementById("error");
      if (errEl) errEl.textContent = e instanceof Error ? e.message : String(e);
    }
  });
}

window.addEventListener("DOMContentLoaded", () => {
  bindProjectPicker();
  loadProject();
  listen("pm:project-data-changed", () => {
    loadProject();
  });
});
