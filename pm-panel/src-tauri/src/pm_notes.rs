//! Focused project and notes via pm CLI. Config and focused.json are read directly;
//! notes read and task mutations go through `pm notes show` and `pm notes todo`.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Deserialize)]
struct FocusedFile {
    #[serde(rename = "projectKey")]
    project_key: Option<String>,
}

#[derive(Clone, Serialize)]
pub struct ListableProject {
    pub project_key: String,
    pub name: String,
}

#[derive(Clone, Serialize)]
pub struct ListProjectsResult {
    pub recent: Vec<ListableProject>,
    pub other: Vec<ListableProject>,
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct LinkEntry {
    pub label: Option<String>,
    pub url: Option<String>,
    #[serde(default)]
    pub children: Option<Vec<LinkEntry>>,
}

#[derive(Clone, serde::Serialize)]
pub struct Session {
    pub date: String,
    pub label: String,
}

#[derive(Clone, serde::Serialize)]
pub struct Todo {
    pub text: String,
    pub checked: bool,
    pub is_focused: bool,
    pub depth: u32,
    pub context: String,
    pub session_index: usize,
    pub line_index: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effective_due_date: Option<String>,
}

#[derive(Clone, serde::Serialize)]
pub struct FocusedProject {
    /// Project key (basePath:name) for the picker. Empty when no focused project.
    pub project_key: String,
    pub project_name: String,
    pub title: String,
    pub summary: String,
    pub problem: String,
    pub goals: Vec<String>,
    pub approach: String,
    pub links: Vec<LinkEntry>,
    pub learnings: Vec<String>,
    pub sessions: Vec<Session>,
    pub todos: Vec<Todo>,
}

const MAX_RECENT: usize = 10;
const RECENT_PROJECTS_FILE: &str = "recent-projects.json";
const UNDO_STATE_FILE: &str = "undo-state.json";
const TASK_TIMING_FILE: &str = "task-timing.json";

/// Run pm with args. Uses PM_CONFIG_HOME so CLI uses same config as panel. Returns stdout or stderr on failure.
fn run_pm(args: &[&str]) -> Result<String, String> {
    let dir = config_dir()?;
    let output = Command::new("pm")
        .args(args)
        .env("PM_CONFIG_HOME", dir.as_os_str())
        .output()
        .map_err(|e| format!("Failed to run pm: {}", e))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(if stderr.is_empty() {
            format!("pm exited with {}", output.status)
        } else {
            stderr.trim().to_string()
        })
    }
}

/// Parse project key "basePath:name" and return the name (folder name).
fn project_name_from_key(key: &str) -> Option<String> {
    let idx = key.find(':')?;
    let name = key[idx + 1..].trim();
    if name.is_empty() {
        return None;
    }
    Some(name.to_string())
}

// --- CLI JSON (pm notes show, pm config get) ---

#[derive(Deserialize)]
struct NotesShowNotes {
    title: Option<String>,
    summary: Option<String>,
    problem: Option<String>,
    goals: Option<Vec<String>>,
    approach: Option<String>,
    links: Option<Vec<LinkEntry>>,
    learnings: Option<Vec<String>>,
    #[serde(rename = "sessions")]
    sessions_json: Option<Vec<SessionJson>>,
}

#[derive(Deserialize)]
struct SessionJson {
    date: String,
    label: String,
}

#[derive(Deserialize)]
struct TodoJson {
    text: Option<String>,
    checked: Option<bool>,
    #[serde(rename = "isFocused")]
    is_focused: Option<bool>,
    depth: Option<u32>,
    context: Option<String>,
    #[serde(rename = "sessionIndex")]
    session_index: Option<usize>,
    #[serde(rename = "lineIndex")]
    line_index: Option<usize>,
    #[serde(rename = "dueDate")]
    due_date: Option<String>,
    #[serde(rename = "effectiveDueDate")]
    effective_due_date: Option<String>,
}

#[derive(Deserialize)]
struct NotesShowOutput {
    notes: Option<NotesShowNotes>,
    todos: Option<Vec<TodoJson>>,
}

#[derive(Deserialize)]
struct ConfigGetOutput {
    #[serde(rename = "activePath")]
    active_path: Option<String>,
    #[serde(rename = "archivePath")]
    archive_path: Option<String>,
}

fn config_dir() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set")?;
    Ok(PathBuf::from(&home).join(".config").join("pm"))
}

fn recent_projects_path() -> Result<PathBuf, String> {
    Ok(config_dir()?.join(RECENT_PROJECTS_FILE))
}

/// Read recent project keys (most recent first). Returns empty vec on missing/invalid file.
fn read_recent_project_keys() -> Vec<String> {
    let path = match recent_projects_path() {
        Ok(p) => p,
        Err(_) => return vec![],
    };
    let raw = match fs::read_to_string(&path) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    match serde_json::from_str::<Vec<String>>(&raw) {
        Ok(keys) => keys.into_iter().filter(|k| !k.trim().is_empty()).collect(),
        Err(_) => vec![],
    }
}

/// Record a project as recently used (prepend, dedupe, keep at most MAX_RECENT). Same logic as Raycast menubar.
pub fn record_recent_project(project_key: &str) {
    let path = match recent_projects_path() {
        Ok(p) => p,
        Err(_) => return,
    };
    let _ = path.parent().map(fs::create_dir_all);
    let mut recent = read_recent_project_keys();
    recent.retain(|k| k != project_key);
    recent.insert(0, project_key.to_string());
    recent.truncate(MAX_RECENT);
    if let Ok(contents) = serde_json::to_string(&recent) {
        let _ = fs::write(&path, contents);
    }
}

impl Default for LinkEntry {
    fn default() -> Self {
        Self {
            label: None,
            url: None,
            children: None,
        }
    }
}

/// Paths to watch for focus/notes changes: (config_dir containing focused.json, optional notes file path).
pub fn get_watch_paths() -> Result<(PathBuf, Option<PathBuf>), String> {
    let dir = config_dir()?;
    let notes_path = get_current_project_key()
        .and_then(|k| project_name_from_key(&k))
        .and_then(|name| run_pm(&["notes", "path", &name]).ok())
        .map(|s| PathBuf::from(s.trim().to_string()));
    Ok((dir, notes_path))
}

/// Complete or undo the task at (session_index, line_index) via CLI. checked = true → complete; false → undo.
pub fn toggle_todo(session_index: usize, line_index: usize, checked: bool) -> Result<(), String> {
    let project_key = get_current_project_key().ok_or("No focused project")?;
    let project_name = project_name_from_key(&project_key).ok_or("Invalid projectKey format")?;
    let args = if checked {
        [
            "notes",
            "todo",
            "complete",
            project_name.as_str(),
            &session_index.to_string(),
            &line_index.to_string(),
        ]
    } else {
        [
            "notes",
            "todo",
            "undo",
            project_name.as_str(),
            &session_index.to_string(),
            &line_index.to_string(),
        ]
    };
    run_pm(&args)?;
    Ok(())
}

/// Move focus ( @) to the task at (session_index, line_index) via CLI.
pub fn set_focus_to(session_index: usize, line_index: usize) -> Result<(), String> {
    let project_key = get_current_project_key().ok_or("No focused project")?;
    let project_name = project_name_from_key(&project_key).ok_or("Invalid projectKey format")?;
    run_pm(&[
        "notes",
        "todo",
        "focus",
        &project_name,
        &session_index.to_string(),
        &line_index.to_string(),
    ])?;
    Ok(())
}

fn get_current_project_key() -> Option<String> {
    let dir = config_dir().ok()?;
    let raw = fs::read_to_string(dir.join("focused.json")).ok()?;
    let data: FocusedFile = serde_json::from_str(&raw).ok()?;
    data.project_key
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_string())
}

pub fn get_focused_project() -> Result<FocusedProject, String> {
    let project_key = get_current_project_key()
        .filter(|k| !k.is_empty())
        .ok_or("No projectKey in focused.json")?;
    let project_name = project_name_from_key(&project_key).ok_or("Invalid projectKey format")?;
    let stdout = run_pm(&["notes", "show", &project_name])?;
    let out: NotesShowOutput =
        serde_json::from_str(&stdout).map_err(|e| format!("Invalid notes show output: {}", e))?;
    let notes = out.notes.ok_or("notes show missing notes")?;
    let todos_json = out.todos.unwrap_or_default();
    let sessions: Vec<Session> = notes
        .sessions_json
        .unwrap_or_default()
        .into_iter()
        .map(|s| Session {
            date: s.date,
            label: s.label,
        })
        .collect();
    let todos: Vec<Todo> = todos_json
        .into_iter()
        .map(|t| Todo {
            text: t.text.unwrap_or_default(),
            checked: t.checked.unwrap_or(false),
            is_focused: t.is_focused.unwrap_or(false),
            depth: t.depth.unwrap_or(0),
            context: t.context.unwrap_or_default(),
            session_index: t.session_index.unwrap_or(0),
            line_index: t.line_index.unwrap_or(0),
            due_date: t.due_date.filter(|s| !s.is_empty()),
            effective_due_date: t.effective_due_date.filter(|s| !s.is_empty()),
        })
        .collect();
    let title = notes
        .title
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| project_name.clone());
    Ok(FocusedProject {
        project_key: project_key.clone(),
        project_name: project_name.clone(),
        title,
        summary: notes.summary.unwrap_or_default(),
        problem: notes.problem.unwrap_or_default(),
        goals: notes.goals.unwrap_or_else(|| vec!["".to_string(); 3]),
        approach: notes.approach.unwrap_or_default(),
        links: notes.links.unwrap_or_default(),
        learnings: notes.learnings.unwrap_or_else(|| vec!["".to_string()]),
        sessions,
        todos,
    })
}

/// Parse "Active:" / "Archive:" lines from `pm list --all` output.
fn parse_list_all(stdout: &str) -> (Vec<String>, Vec<String>) {
    let mut active = Vec::new();
    let mut archive = Vec::new();
    let mut in_archive = false;
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed == "Archive:" {
            in_archive = true;
            continue;
        }
        if trimmed == "Active:" {
            continue;
        }
        if trimmed == "(none)" {
            continue;
        }
        if line.starts_with(' ') && !trimmed.is_empty() {
            if in_archive {
                archive.push(trimmed.to_string());
            } else {
                active.push(trimmed.to_string());
            }
        }
    }
    (active, archive)
}

/// List projects in two sections: recent (up to 10) then other. Uses `pm list --all` and `pm config get`.
pub fn list_projects() -> Result<ListProjectsResult, String> {
    let list_stdout = run_pm(&["list", "--all"])?;
    let config_stdout = run_pm(&["config", "get"])?;
    let config: ConfigGetOutput = serde_json::from_str(&config_stdout)
        .map_err(|e| format!("Invalid config get output: {}", e))?;
    let active_path = config
        .active_path
        .filter(|s| !s.trim().is_empty())
        .ok_or("config missing activePath")?;
    let archive_path = config
        .archive_path
        .filter(|s| !s.trim().is_empty())
        .ok_or("config missing archivePath")?;
    let (active_names, archive_names) = parse_list_all(&list_stdout);
    let all: Vec<ListableProject> = active_names
        .into_iter()
        .map(|name| ListableProject {
            project_key: format!("{}:{}", active_path.trim(), name),
            name,
        })
        .chain(archive_names.into_iter().map(|name| ListableProject {
            project_key: format!("{}:{}", archive_path.trim(), name),
            name,
        }))
        .collect();
    let recent_ordered: Vec<String> = read_recent_project_keys()
        .into_iter()
        .take(MAX_RECENT)
        .collect();
    let recent_set: std::collections::HashSet<&str> =
        recent_ordered.iter().map(String::as_str).collect();
    let recent: Vec<ListableProject> = recent_ordered
        .iter()
        .filter_map(|key| all.iter().find(|p| p.project_key == *key).cloned())
        .collect();
    let other: Vec<ListableProject> = all
        .into_iter()
        .filter(|p| !recent_set.contains(p.project_key.as_str()))
        .collect();
    Ok(ListProjectsResult { recent, other })
}

/// Set the focused project by writing focused.json. Does not validate that the project exists.
/// Records the project as recently used for the picker ordering.
pub fn set_focused_project(project_key: &str) -> Result<(), String> {
    let dir = config_dir()?;
    fs::create_dir_all(&dir).map_err(|e| format!("Cannot create config dir: {}", e))?;
    let focused_path = dir.join("focused.json");
    let contents = format!(
        "{{\"projectKey\":\"{}\"}}\n",
        escape_json_string(project_key)
    );
    fs::write(&focused_path, contents).map_err(|e| format!("Cannot write focused.json: {}", e))?;
    record_recent_project(project_key);
    Ok(())
}

fn escape_json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out
}

// --- Tray / menubar helpers ---

/// Project code for menubar display: "M-123" style prefix or full name.
pub fn get_project_code(name: &str) -> String {
    if let Some(m) = regex::Regex::new(r"^((?:M|DE|P|I)-\d+)")
        .ok()
        .and_then(|re| re.find(name))
    {
        return m.as_str().to_string();
    }
    name.to_string()
}

/// Notes file path for the project, if it exists. Uses `pm notes path`.
pub fn get_notes_path(project_name: &str) -> Option<PathBuf> {
    let s = run_pm(&["notes", "path", project_name]).ok()?;
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(PathBuf::from(trimmed))
}

/// Earliest effective due among open (unchecked) todos. For project-level "next due" in menubar.
pub fn get_next_due_for_project(todos: &[Todo]) -> Option<String> {
    let open_todos: Vec<&Todo> = todos.iter().filter(|t| !t.checked).collect();
    let mut earliest: Option<&str> = None;
    for t in open_todos {
        let due = t.effective_due_date.as_deref().or(t.due_date.as_deref())?;
        if let Some(e) = earliest {
            if due_date_sort_key(due) < due_date_sort_key(e) {
                earliest = Some(due);
            }
        } else {
            earliest = Some(due);
        }
    }
    earliest.map(String::from)
}

fn due_date_sort_key(s: &str) -> String {
    let prefix = s.get(0..10).unwrap_or("");
    if prefix.len() == 10 && s.chars().take(10).all(|c| c.is_ascii_digit() || c == '-') {
        return prefix.to_string();
    }
    "9999-12-31".to_string()
}

/// Short due format for menubar: "in 15m", "tomorrow", "2d", etc.
pub fn format_due_menubar(due: &str) -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let parse_ymd = |s: &str| -> Option<(i32, u32, u32)> {
        let parts: Vec<&str> = s.split('-').collect();
        if parts.len() >= 3 {
            let y: i32 = parts[0].parse().ok()?;
            let m: u32 = parts[1].parse().ok()?;
            let d: u32 = parts[2].parse().ok()?;
            Some((y, m, d))
        } else {
            None
        }
    };
    let date_sec = if let Some(ymd) = due.get(0..10) {
        if let Some((y, m, d)) = parse_ymd(ymd) {
            let hour = due
                .get(11..13)
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(12);
            let min = due
                .get(14..16)
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(0);
            let dt = chrono_parse(y, m, d, hour, min);
            dt.map(|t| t.and_utc().timestamp()).unwrap_or(0)
        } else {
            0
        }
    } else {
        0
    };
    if date_sec == 0 {
        return due.get(0..8).unwrap_or(due).to_string();
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let diff_sec = date_sec - now;
    let diff_min = diff_sec / 60;
    let diff_hours = diff_min / 60;
    let diff_days = diff_hours / 24;

    if diff_min > -60 && diff_min < 60 {
        if diff_min >= 0 {
            return if diff_min == 0 {
                "now".to_string()
            } else {
                format!("in {}m", diff_min)
            };
        }
        return format!("{}m ago", -diff_min);
    }
    if diff_hours > -24 && diff_hours < 24 {
        let h = diff_hours.abs();
        let m = (diff_min.abs() % 60) as i64;
        if diff_hours >= 0 {
            return if m != 0 {
                format!("in {}h {}m", h, m)
            } else {
                format!("in {}h", h)
            };
        }
        return if m != 0 {
            format!("{}h {}m ago", h, m)
        } else {
            format!("{}h ago", h)
        };
    }
    if diff_days == 1 {
        return "tomorrow".to_string();
    }
    if diff_days == -1 {
        return "yesterday".to_string();
    }
    if diff_days > 0 && diff_days < 7 {
        return format!("in {}d", diff_days);
    }
    if diff_days < 0 && diff_days > -7 {
        return format!("{}d ago", -diff_days);
    }
    if diff_days >= 7 && diff_days < 30 {
        return format!("in {}w", (diff_days as f64 / 7.0).round());
    }
    if diff_days <= -7 && diff_days > -30 {
        return format!("{}w ago", (-diff_days as f64 / 7.0).round());
    }
    if let Some(ymd) = due.get(0..10) {
        if let Some((_, m, d)) = parse_ymd(ymd) {
            return format!("{}/{}", m, d);
        }
    }
    due.get(0..10).unwrap_or(due).to_string()
}

fn chrono_parse(y: i32, m: u32, d: u32, hour: u32, min: u32) -> Option<chrono::NaiveDateTime> {
    let date = chrono::NaiveDate::from_ymd_opt(y, m, d)?;
    let time = chrono::NaiveTime::from_hms_opt(hour, min, 0)?;
    Some(chrono::NaiveDateTime::new(date, time))
}

/// Whether the project directory has a `src` subdirectory (for "Open in Cursor").
pub fn has_src_dir(project_path: &std::path::Path) -> bool {
    std::fs::metadata(project_path.join("src")).is_ok()
}

// --- Undo state (for "Undo" after Complete in tray) ---

#[derive(serde::Serialize, serde::Deserialize)]
struct UndoState {
    project_name: String,
    session_index: usize,
    line_index: usize,
    text: String,
}

fn undo_state_path() -> Result<PathBuf, String> {
    Ok(config_dir()?.join(UNDO_STATE_FILE))
}

/// Save state before completing a task so we can offer Undo.
pub fn save_undo_state(project_name: &str, session_index: usize, line_index: usize, text: &str) {
    let path = match undo_state_path() {
        Ok(p) => p,
        Err(_) => return,
    };
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    let state = UndoState {
        project_name: project_name.to_string(),
        session_index,
        line_index,
        text: text.to_string(),
    };
    if let Ok(contents) = serde_json::to_string(&state) {
        let _ = std::fs::write(path, contents);
    }
}

/// Load undo state if any.
pub fn get_undo_state() -> Option<(String, usize, usize)> {
    let path = undo_state_path().ok()?;
    let raw = std::fs::read_to_string(path).ok()?;
    let state: UndoState = serde_json::from_str(&raw).ok()?;
    Some((state.project_name, state.session_index, state.line_index))
}

/// Clear undo state after undo or when no longer relevant.
pub fn clear_undo_state() {
    let _ = undo_state_path().map(|p| std::fs::remove_file(p));
}

/// Run undo for the given project (uses saved project from undo state, not current focused).
pub fn run_undo(project_name: &str, session_index: usize, line_index: usize) -> Result<(), String> {
    run_pm(&[
        "notes",
        "todo",
        "undo",
        project_name,
        &session_index.to_string(),
        &line_index.to_string(),
    ])?;
    Ok(())
}

// --- Task timing (1h yellow, 2h red tray icon) ---

#[derive(serde::Serialize, serde::Deserialize)]
struct TaskTimingState {
    task_key: String,
    seen_at: u64,
}

fn task_timing_path() -> Result<PathBuf, String> {
    Ok(config_dir()?.join(TASK_TIMING_FILE))
}

fn get_task_timing() -> Option<TaskTimingState> {
    let path = task_timing_path().ok()?;
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

fn set_task_timing(task_key: &str) {
    if let Ok(path) = task_timing_path() {
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        let state = TaskTimingState {
            task_key: task_key.to_string(),
            seen_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis() as u64,
        };
        if let Ok(contents) = serde_json::to_string(&state) {
            let _ = fs::write(path, contents);
        }
    }
}

/// Clear stored task timing (call when there is no focused task).
pub fn clear_task_timing() {
    let _ = task_timing_path().map(fs::remove_file);
}

/// Stable key for the focused task (matches Raycast task-timing key concept).
pub fn task_timing_key(notes_path: &Path, session_index: usize, line_index: usize) -> String {
    format!(
        "{}::{}:{}",
        notes_path.display(),
        session_index,
        line_index
    )
}

/// Icon color for task tray when focused task has been sitting 1h+ (yellow) or 2h+ (red).
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum TaskIconColor {
    Yellow,
    Red,
}

/// Returns Yellow/Red if the current focused task (notes_path, si, li) has been focused >= 1h or >= 2h.
/// Side effect: if key doesn't match stored (or no stored), updates timing to now.
pub fn get_task_icon_color(
    notes_path: &Path,
    session_index: usize,
    line_index: usize,
) -> Option<TaskIconColor> {
    let key = task_timing_key(notes_path, session_index, line_index);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    let stored = get_task_timing();
    if let Some(ref s) = stored {
        if s.task_key == key {
            let elapsed_hours = (now_ms.saturating_sub(s.seen_at)) as f64 / 3_600_000.0;
            if elapsed_hours >= 2.0 {
                return Some(TaskIconColor::Red);
            }
            if elapsed_hours >= 1.0 {
                return Some(TaskIconColor::Yellow);
            }
            return None;
        }
    }
    set_task_timing(&key);
    None
}
