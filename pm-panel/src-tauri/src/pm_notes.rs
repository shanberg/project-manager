//! Focused project and notes via pm CLI. Config and focused.json are read directly;
//! notes read and task mutations go through `pm notes show` and `pm notes todo`.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
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
    /// Inline `due:` on this task line, if any (verbatim, e.g. "2026-07-15").
    pub due_date: Option<String>,
    /// Due used for display: own due, else nearest ancestor due. Computed by `pm notes show`.
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
pub const PANEL_SETTINGS_FILE: &str = "panel-settings.json";

/// Window behavior toggles shared between the panel's tray menu and the Raycast extension via
/// `panel-settings.json` in the config dir. Both default off (normal menubar-utility behavior).
#[derive(Clone, Copy, Default, Serialize, Deserialize)]
pub struct PanelSettings {
    /// Keep the panel visible when it loses focus instead of auto-hiding.
    #[serde(default)]
    pub pinned: bool,
    /// Float the panel above all other windows (always-on-top).
    #[serde(default)]
    pub floating: bool,
}

fn panel_settings_path() -> Result<PathBuf, String> {
    Ok(config_dir()?.join(PANEL_SETTINGS_FILE))
}

/// Read panel settings; returns defaults (all off) when the file is missing or unparseable.
pub fn read_panel_settings() -> PanelSettings {
    panel_settings_path()
        .ok()
        .and_then(|p| fs::read_to_string(p).ok())
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

/// Persist panel settings to the config dir so the choice survives restarts and is visible to Raycast.
pub fn write_panel_settings(settings: PanelSettings) -> Result<(), String> {
    let dir = config_dir()?;
    fs::create_dir_all(&dir).map_err(|e| format!("Cannot create config dir: {}", e))?;
    let contents = serde_json::to_string_pretty(&settings)
        .map_err(|e| format!("Cannot serialize panel settings: {}", e))?;
    fs::write(dir.join(PANEL_SETTINGS_FILE), contents)
        .map_err(|e| format!("Cannot write {}: {}", PANEL_SETTINGS_FILE, e))
}

/// Resolve the `pm` binary. A GUI app (especially a launched .app bundle) may not inherit the
/// shell PATH, so prefer an explicit override and known install locations before bare PATH lookup.
fn pm_binary() -> String {
    if let Ok(p) = std::env::var("PM_CLI_PATH") {
        if !p.trim().is_empty() {
            return p;
        }
    }
    for candidate in ["/opt/homebrew/bin/pm", "/usr/local/bin/pm"] {
        if std::path::Path::new(candidate).exists() {
            return candidate.to_string();
        }
    }
    "pm".to_string()
}

/// Run pm with args. Uses PM_CONFIG_HOME so CLI uses same config as panel. Returns stdout or stderr on failure.
fn run_pm(args: &[&str]) -> Result<String, String> {
    let dir = config_dir()?;
    let output = Command::new(pm_binary())
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
fn record_recent_project(project_key: &str) {
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

/// Where a new task is inserted relative to an anchor task. Omitted for a quick-add to today's session.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddPosition {
    /// "child" | "before" | "after".
    pub kind: String,
    pub session_index: usize,
    pub line_index: usize,
}

/// Add a task to the focused project via `pm notes todo add`. No position → quick-add to today's
/// session (and take focus). Optional `due` is stored inline on the task line.
pub fn add_todo(text: String, due: Option<String>, position: Option<AddPosition>) -> Result<(), String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err("Task text is required".to_string());
    }
    let project_key = get_current_project_key().ok_or("No focused project")?;
    let project_name = project_name_from_key(&project_key).ok_or("Invalid projectKey format")?;
    let mut args: Vec<String> = vec![
        "notes".into(),
        "todo".into(),
        "add".into(),
        project_name,
        trimmed.to_string(),
    ];
    if let Some(d) = due {
        if !d.trim().is_empty() {
            args.push("--due".into());
            args.push(d);
        }
    }
    if let Some(pos) = position {
        let flag = match pos.kind.as_str() {
            "child" => "--child",
            "before" => "--before",
            "after" => "--after",
            other => return Err(format!("Invalid position: {}", other)),
        };
        args.push(flag.into());
        args.push(pos.session_index.to_string());
        args.push(pos.line_index.to_string());
    }
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    run_pm(&arg_refs)?;
    Ok(())
}

/// Set or clear the inline due date on the task at (session_index, line_index) via `pm notes todo due`.
/// A None or empty `due` clears it.
pub fn set_due(session_index: usize, line_index: usize, due: Option<String>) -> Result<(), String> {
    let project_key = get_current_project_key().ok_or("No focused project")?;
    let project_name = project_name_from_key(&project_key).ok_or("Invalid projectKey format")?;
    let due_arg = match due {
        Some(d) if !d.trim().is_empty() => d,
        _ => "--clear".to_string(),
    };
    let si = session_index.to_string();
    let li = line_index.to_string();
    let args = [
        "notes",
        "todo",
        "due",
        project_name.as_str(),
        &si,
        &li,
        &due_arg,
    ];
    run_pm(&args)?;
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
    let out: NotesShowOutput = serde_json::from_str(&stdout)
        .map_err(|e| format!("Invalid notes show output: {}", e))?;
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
            due_date: t.due_date,
            effective_due_date: t.effective_due_date,
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
        .chain(
            archive_names
                .into_iter()
                .map(|name| ListableProject {
                    project_key: format!("{}:{}", archive_path.trim(), name),
                    name,
                }),
        )
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
    let contents = format!("{{\"projectKey\":\"{}\"}}\n", escape_json_string(project_key));
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
