//! Menubar tray icons matching the Raycast extension: task-focused (focused-project) and status-focused (focused-project-status).

use std::path::Path;
use std::sync::Mutex;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager};

use crate::pm_notes::{
    self, clear_undo_state, format_due_menubar, get_next_due_for_project, get_notes_path,
    get_project_code, get_undo_state, has_src_dir, record_recent_project, save_undo_state,
    FocusedProject, LinkEntry, ListProjectsResult, Todo,
};

/// State for menu action handlers: updated each time we refresh the tray menus.
pub struct TrayState {
    pub task_project_name: Option<String>,
    pub task_project_key: Option<String>,
    pub task_project_path: Option<std::path::PathBuf>,
    pub task_notes_path: Option<std::path::PathBuf>,
    pub task_next_todo: Option<(usize, usize, String)>,
    pub status_project_path: Option<std::path::PathBuf>,
    pub status_notes_path: Option<std::path::PathBuf>,
    pub status_has_src: bool,
    pub status_link_urls: Vec<String>,
    pub status_recent_keys: Vec<String>,
}

impl Default for TrayState {
    fn default() -> Self {
        Self {
            task_project_name: None,
            task_project_key: None,
            task_project_path: None,
            task_notes_path: None,
            task_next_todo: None,
            status_project_path: None,
            status_notes_path: None,
            status_has_src: false,
            status_link_urls: Vec::new(),
            status_recent_keys: Vec::new(),
        }
    }
}

const TRAY_TASK_ID: &str = "pm-task";
const TRAY_STATUS_ID: &str = "pm-status";

fn flatten_links(links: &[LinkEntry]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for l in links {
        if let Some(ref url) = l.url {
            if !url.trim().is_empty() {
                let label = l
                    .label
                    .as_deref()
                    .unwrap_or("")
                    .trim()
                    .to_string();
                out.push((if label.is_empty() { url.clone() } else { label }, url.clone()));
            }
        }
        if let Some(ref children) = l.children {
            for c in children {
                if let Some(ref url) = c.url {
                    if !url.trim().is_empty() {
                        let label = l
                            .label
                            .as_ref()
                            .map(|s| format!("{}: {}", s.trim(), url))
                            .unwrap_or_else(|| url.clone());
                        out.push((label, url.clone()));
                    }
                }
            }
        }
    }
    out
}

fn open_url_or_path(_app: &AppHandle, url_or_path: &str) {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open").arg(url_or_path).spawn();
    }
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("explorer").arg(url_or_path).spawn();
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let _ = std::process::Command::new("xdg-open").arg(url_or_path).spawn();
    }
}

fn open_in_cursor(_app: &AppHandle, path: &Path) {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open")
            .args(["-a", "Cursor", path.to_string_lossy().as_ref()])
            .spawn();
    }
    #[cfg(not(target_os = "macos"))]
    {
        open_url_or_path(app, path.to_string_lossy().as_ref());
    }
}

fn show_main_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

fn build_task_menu(app: &AppHandle, data: Option<&FocusedProject>) -> Result<tauri::menu::Menu<tauri::Wry>, tauri::Error> {
    let mut b = MenuBuilder::new(app);
    if let Some(d) = data {
        let open_todos: Vec<&Todo> = d.todos.iter().filter(|t| !t.checked).collect();
        let next_todo = open_todos.iter().find(|t| t.is_focused).or(open_todos.first());
        let notes_path = get_notes_path(&d.project_name);
        let _project_path = d
            .project_key
            .splitn(2, ':')
            .next()
            .map(|base| std::path::PathBuf::from(base).join(&d.project_name))
            .unwrap_or_else(|| std::path::PathBuf::from(&d.project_key.replace(':', "/")));

        if let Some(_t) = next_todo {
            let complete = MenuItemBuilder::with_id("task_complete", "Complete").build(app)?;
            b = b.item(&complete);
            if get_undo_state().is_some() {
                let undo = MenuItemBuilder::with_id("task_undo", "Undo").build(app)?;
                b = b.item(&undo);
            }
        } else {
            let _all_done = MenuItemBuilder::with_id("task_noop", "All Done").build(app)?;
            let _no_tasks = MenuItemBuilder::with_id("task_noop2", "No Tasks").build(app)?;
            b = b.item(&_all_done).item(&_no_tasks);
        }
        if notes_path.is_some() {
            let narrow = MenuItemBuilder::with_id("task_narrow_focus", "Narrow Focus").build(app)?;
            b = b.item(&narrow);
        }
        if next_todo.is_some() {
            let add_after = MenuItemBuilder::with_id("task_add_after", "Add After").build(app)?;
            let add_before = MenuItemBuilder::with_id("task_add_before", "Add Before").build(app)?;
            let edit = MenuItemBuilder::with_id("task_edit", "Edit").build(app)?;
            let wrap = MenuItemBuilder::with_id("task_wrap", "Wrap").build(app)?;
            b = b.item(&add_after).item(&add_before).item(&edit).item(&wrap);
        }
        b = b.separator();
        if notes_path.is_some() {
            let session = MenuItemBuilder::with_id("task_add_session_note", "Add Session Note").build(app)?;
            let link = MenuItemBuilder::with_id("task_add_link", "Add Link").build(app)?;
            let view = MenuItemBuilder::with_id("task_view_project", "View Project").build(app)?;
            let obsidian = MenuItemBuilder::with_id("task_open_obsidian", "Open in Obsidian").build(app)?;
            let finder = MenuItemBuilder::with_id("task_open_finder", "Open in Finder").build(app)?;
            b = b.item(&session).item(&link).item(&view).item(&obsidian).item(&finder);
        }
        b = b.separator();

        let by_context: std::collections::HashMap<String, Vec<&Todo>> = open_todos
            .into_iter()
            .fold(std::collections::HashMap::new(), |mut m, t| {
                m.entry(t.context.clone()).or_default().push(t);
                m
            });
        let mut context_order: Vec<String> = by_context.keys().cloned().collect();
        context_order.sort();
        for ctx in context_order {
            let todos = by_context.get(&ctx).unwrap();
            for t in todos {
                let si = t.session_index;
                let li = t.line_index;
                let indent = "  ".repeat(t.depth as usize);
                let due_suffix = t
                    .effective_due_date
                    .as_deref()
                    .or(t.due_date.as_deref())
                    .map(|d| format!(" ({})", format_due_menubar(d)))
                    .unwrap_or_default();
                let raw = format!("{}{}{}", indent, t.text, due_suffix);
                let text = truncate_menu_text(&raw, 50);
                let id_focus = format!("task_todo_f_{}_{}", si, li);
                let item = MenuItemBuilder::with_id(id_focus.clone(), text.as_str()).build(app)?;
                b = b.item(&item);
            }
        }
        b = b.separator();
    } else {
        // No focused project: only List Projects, New Project, Configure (match Raycast)
        let list = MenuItemBuilder::with_id("task_list_projects", "List Projects").build(app)?;
        let new_p = MenuItemBuilder::with_id("task_new_project", "New Project").build(app)?;
        let config = MenuItemBuilder::with_id("task_configure", "Configure").build(app)?;
        b = b.item(&list).item(&new_p).item(&config);
    }
    b.build()
}

fn truncate_menu_text(s: &str, max: usize) -> String {
    let t = s.trim();
    if t.len() <= max {
        t.to_string()
    } else {
        format!("{}…", t.chars().take(max).collect::<String>().trim_end())
    }
}

fn build_status_menu(
    app: &AppHandle,
    data: Option<&FocusedProject>,
    list: &ListProjectsResult,
) -> Result<tauri::menu::Menu<tauri::Wry>, tauri::Error> {
    let mut b = MenuBuilder::new(app);
    if let Some(d) = data {
        let _done = d.todos.iter().filter(|t| t.checked).count();
        let _total = d.todos.len();
        let view = MenuItemBuilder::with_id("status_view_project", "View Project").build(app)?;
        b = b.item(&view);
        let notes_path = get_notes_path(&d.project_name);
        let project_path = d
            .project_key
            .splitn(2, ':')
            .next()
            .map(|base| std::path::PathBuf::from(base).join(&d.project_name))
            .unwrap_or_else(|| std::path::PathBuf::from(&d.project_key.replace(':', "/")));
        if notes_path.is_some() {
            let obsidian = MenuItemBuilder::with_id("status_open_obsidian", "Open in Obsidian").build(app)?;
            let finder = MenuItemBuilder::with_id("status_open_finder", "Open in Finder").build(app)?;
            b = b.item(&obsidian).item(&finder);
        } else {
            let finder = MenuItemBuilder::with_id("status_open_finder", "Open in Finder").build(app)?;
            b = b.item(&finder);
        }
        if has_src_dir(&project_path) {
            let cursor = MenuItemBuilder::with_id("status_open_cursor", "Open in Cursor").build(app)?;
            b = b.item(&cursor);
        }
        b = b.separator();

        let links = flatten_links(&d.links);
        for (i, (label, _url)) in links.iter().enumerate() {
            let text = truncate_menu_text(label, 50);
            let id = format!("status_link_{}", i);
            let item = MenuItemBuilder::with_id(id, text.as_str()).build(app)?;
            b = b.item(&item);
        }
        if !links.is_empty() || notes_path.is_some() {
            let add_link = MenuItemBuilder::with_id("status_add_link", "Add Link").build(app)?;
            b = b.item(&add_link);
        }
        if !list.recent.is_empty() {
            b = b.separator();
            for (i, p) in list.recent.iter().enumerate() {
                let title = truncate_menu_text(&p.name, 50);
                let id = format!("status_recent_{}", i);
                let item = MenuItemBuilder::with_id(id, title.as_str()).build(app)?;
                b = b.item(&item);
            }
        }
        b = b.separator();
    }

    let list_p = MenuItemBuilder::with_id("status_list_projects", "List Projects").build(app)?;
    let new_p = MenuItemBuilder::with_id("status_new_project", "New Project").build(app)?;
    let config = MenuItemBuilder::with_id("status_configure", "Configure").build(app)?;
    b = b.item(&list_p).item(&new_p).item(&config);
    b.build()
}

fn update_tray_state(
    state: &Mutex<TrayState>,
    data: Option<&FocusedProject>,
    list: &ListProjectsResult,
) {
    let mut s = state.lock().unwrap();
    if let Some(d) = data {
        let notes_path = get_notes_path(&d.project_name);
        let project_path = {
            let base = d.project_key.split(':').next().unwrap_or("");
            std::path::PathBuf::from(base).join(&d.project_name)
        };
        s.task_project_name = Some(d.project_name.clone());
        s.task_project_key = Some(d.project_key.clone());
        s.task_project_path = Some(project_path.clone());
        s.task_notes_path = notes_path.clone();
        let open_todos: Vec<&Todo> = d.todos.iter().filter(|t| !t.checked).collect();
        let next = open_todos.iter().find(|t| t.is_focused).or(open_todos.first());
        s.task_next_todo = next.map(|t| (t.session_index, t.line_index, t.text.clone()));

        s.status_project_path = Some(project_path.clone());
        s.status_notes_path = notes_path;
        s.status_has_src = has_src_dir(&project_path);
        s.status_link_urls = flatten_links(&d.links).into_iter().map(|(_, u)| u).collect();
        s.status_recent_keys = list.recent.iter().map(|p| p.project_key.clone()).collect();
    } else {
        *s = TrayState::default();
    }
}

fn handle_task_menu_event(app: &AppHandle, id: &str, state: &Mutex<TrayState>) {
    let s = state.lock().unwrap();
    match id {
        "task_complete" => {
            if let Some((si, li, text)) = s.task_next_todo.clone() {
                let project_name = s.task_project_name.clone().unwrap_or_default();
                drop(s);
                save_undo_state(&project_name, si, li, &text);
                if pm_notes::toggle_todo(si, li, true).is_ok() {
                    let _ = app.emit("pm:project-data-changed", ());
                }
            }
        }
        "task_undo" => {
            if let Some((name, si, li)) = get_undo_state() {
                drop(s);
                if pm_notes::run_undo(&name, si, li).is_ok() {
                    clear_undo_state();
                    let _ = app.emit("pm:project-data-changed", ());
                }
            }
        }
        "task_view_project" | "task_narrow_focus" | "task_add_after" | "task_add_before"
        | "task_edit" | "task_wrap" | "task_add_session_note" | "task_add_link" => show_main_window(app),
        "task_open_obsidian" => {
            if let Some(ref path) = s.status_notes_path {
                if let Some(ref key) = s.task_project_key {
                    record_recent_project(key);
                }
                let uri = format!(
                    "obsidian://open?path={}",
                    urlencoding::encode(path.to_string_lossy().as_ref())
                );
                drop(s);
                open_url_or_path(app, &uri);
            }
        }
        "task_open_finder" => {
            if let Some(path) = s.task_project_path.clone() {
                if let Some(ref key) = s.task_project_key {
                    record_recent_project(key);
                }
                drop(s);
                open_url_or_path(app, path.to_string_lossy().as_ref());
            }
        }
        id if id.starts_with("task_todo_f_") => {
            let parts: Vec<&str> = id.trim_start_matches("task_todo_f_").splitn(2, '_').collect();
            if parts.len() == 2 {
                if let (Ok(si), Ok(li)) = (parts[0].parse::<usize>(), parts[1].parse::<usize>()) {
                    let is_focused = s
                        .task_next_todo
                        .as_ref()
                        .map(|(sx, lx, _)| *sx == si && *lx == li)
                        .unwrap_or(false);
                    let project_name = s.task_project_name.clone().unwrap_or_default();
                    let text = s.task_next_todo.as_ref().map(|(_, _, t)| t.clone()).unwrap_or_default();
                    drop(s);
                    let ok = if is_focused {
                        save_undo_state(&project_name, si, li, &text);
                        pm_notes::toggle_todo(si, li, true).is_ok()
                    } else {
                        pm_notes::set_focus_to(si, li).is_ok()
                    };
                    if ok {
                        let _ = app.emit("pm:project-data-changed", ());
                    }
                }
            }
        }
        id if id.starts_with("task_todo_d_") => {
            let parts: Vec<&str> = id.trim_start_matches("task_todo_d_").splitn(2, '_').collect();
            if parts.len() == 2 {
                if let (Ok(si), Ok(li)) = (parts[0].parse::<usize>(), parts[1].parse::<usize>()) {
                    drop(s);
                    if pm_notes::toggle_todo(si, li, true).is_ok() {
                        let _ = app.emit("pm:project-data-changed", ());
                    }
                }
            }
        }
        "task_list_projects" | "task_new_project" | "task_configure" => show_main_window(app),
        _ => {}
    }
}

fn handle_status_menu_event(app: &AppHandle, id: &str, state: &Mutex<TrayState>) {
    let s = state.lock().unwrap();
    match id {
        "status_view_project" => {
            drop(s);
            show_main_window(app);
        }
        "status_open_obsidian" => {
            if let Some(path) = s.status_notes_path.clone() {
                if let Some(ref key) = s.task_project_key {
                    record_recent_project(key);
                }
                let uri = format!(
                    "obsidian://open?path={}",
                    urlencoding::encode(path.to_string_lossy().as_ref())
                );
                drop(s);
                open_url_or_path(app, &uri);
            }
        }
        "status_open_finder" => {
            if let Some(path) = s.status_project_path.clone() {
                if let Some(ref key) = s.task_project_key {
                    record_recent_project(key);
                }
                drop(s);
                open_url_or_path(app, path.to_string_lossy().as_ref());
            }
        }
        "status_open_cursor" => {
            if let Some(path) = s.status_project_path.clone() {
                if let Some(ref key) = s.task_project_key {
                    record_recent_project(key);
                }
                drop(s);
                open_in_cursor(app, &path);
            }
        }
        id if id.starts_with("status_link_") => {
            if let Ok(i) = id.trim_start_matches("status_link_").parse::<usize>() {
                if i < s.status_link_urls.len() {
                    let url = s.status_link_urls[i].clone();
                    drop(s);
                    open_url_or_path(app, &url);
                }
            }
        }
        "status_add_link" => {
            drop(s);
            show_main_window(app);
        }
        id if id.starts_with("status_recent_") => {
            if let Ok(i) = id.trim_start_matches("status_recent_").parse::<usize>() {
                if i < s.status_recent_keys.len() {
                    let key = s.status_recent_keys[i].clone();
                    drop(s);
                    if pm_notes::set_focused_project(&key).is_ok() {
                        let _ = app.emit("pm:project-data-changed", ());
                    }
                }
            }
        }
        "status_new_project" | "status_list_projects" | "status_configure" => {
            drop(s);
            show_main_window(app);
        }
        _ => {}
    }
}

pub fn setup_trays(app: &AppHandle) -> Result<(), String> {
    let state = Mutex::new(TrayState::default());
    app.manage(state);

    let data = pm_notes::get_focused_project().ok();
    let list = pm_notes::list_projects().unwrap_or_else(|_| ListProjectsResult {
        recent: vec![],
        other: vec![],
    });
    let state_guard = app.state::<Mutex<TrayState>>();
    update_tray_state(state_guard.inner(), data.as_ref(), &list);

    let task_menu = build_task_menu(app, data.as_ref()).map_err(|e| e.to_string())?;
    let task_title = data
        .as_ref()
        .and_then(|d| {
            let open: Vec<&Todo> = d.todos.iter().filter(|t| !t.checked).collect();
            let next = open.iter().find(|t| t.is_focused).or(open.first())?;
            let text = truncate_menu_text(&next.text, 40);
            let due_str = next
                .effective_due_date
                .as_deref()
                .or(next.due_date.as_deref())
                .map(|due| format_due_menubar(due))
                .filter(|s| !s.is_empty());
            Some(match due_str {
                Some(d) => format!("{} • {}", text, d),
                None => text,
            })
        })
        .unwrap_or_else(|| "No Tasks".to_string());
    let task_tooltip = data
        .as_ref()
        .map(|d| d.project_name.clone())
        .unwrap_or_else(|| "No Focused Project".to_string());

    let icon = app.default_window_icon().cloned();

    let task_tray = TrayIconBuilder::with_id(TRAY_TASK_ID)
        .menu(&task_menu)
        .title(&task_title)
        .tooltip(&task_tooltip)
        .show_menu_on_left_click(true)
        .on_menu_event(move |app, event| {
            let id = event.id().as_ref();
            if let Some(state) = app.try_state::<Mutex<TrayState>>() {
                handle_task_menu_event(app, id, state.inner());
            }
        });
    let task_tray = if let Some(ref icon) = icon {
        task_tray.icon(icon.clone()).icon_as_template(true)
    } else {
        task_tray
    };
    let _task_tray = task_tray.build(app).map_err(|e| e.to_string())?;

    let status_menu = build_status_menu(app, data.as_ref(), &list).map_err(|e| e.to_string())?;
    let menubar_label = data
        .as_ref()
        .map(|d| get_project_code(&d.project_name))
        .unwrap_or_else(|| "—".to_string());
    let next_due_str = data
        .as_ref()
        .and_then(|d| get_next_due_for_project(&d.todos))
        .map(|d| format_due_menubar(&d))
        .unwrap_or_default();
    let status_title = if next_due_str.is_empty() {
        menubar_label.clone()
    } else {
        format!("{} · {}", menubar_label, next_due_str)
    };
    let status_tooltip = data
        .as_ref()
        .map(|d| {
            let done = d.todos.iter().filter(|t| t.checked).count();
            let total = d.todos.len();
            format!("{}: {}/{} done", d.project_name, done, total)
        })
        .unwrap_or_else(|| "No Focused Project".to_string());

    let status_tray = TrayIconBuilder::with_id(TRAY_STATUS_ID)
        .menu(&status_menu)
        .title(&status_title)
        .tooltip(&status_tooltip)
        .show_menu_on_left_click(true)
        .on_menu_event(move |app, event| {
            let id = event.id().as_ref();
            if let Some(state) = app.try_state::<Mutex<TrayState>>() {
                handle_status_menu_event(app, id, state.inner());
            }
        });
    let status_tray = if let Some(ref icon) = icon {
        status_tray.icon(icon.clone()).icon_as_template(true)
    } else {
        status_tray
    };
    let _status_tray = status_tray.build(app).map_err(|e| e.to_string())?;

    Ok(())
}

pub fn refresh_trays(app: &AppHandle) {
    let data = pm_notes::get_focused_project().ok();
    let list = pm_notes::list_projects().unwrap_or_else(|_| ListProjectsResult {
        recent: vec![],
        other: vec![],
    });
    if let Some(state) = app.try_state::<Mutex<TrayState>>() {
        update_tray_state(state.inner(), data.as_ref(), &list);
    }

    let task_menu = build_task_menu(app, data.as_ref()).map_err(|e| e.to_string());
    let status_menu = build_status_menu(app, data.as_ref(), &list).map_err(|e| e.to_string());
    if let (Ok(task_menu), Ok(status_menu)) = (task_menu, status_menu) {
        if let Some(tray) = app.tray_by_id(TRAY_TASK_ID) {
            let _ = tray.set_menu(Some(task_menu));
            let task_title = data
                .as_ref()
                .and_then(|d| {
                    let open: Vec<&Todo> = d.todos.iter().filter(|t| !t.checked).collect();
                    let next = open.iter().find(|t| t.is_focused).or(open.first())?;
                    let text = truncate_menu_text(&next.text, 40);
                    let due_str = next
                        .effective_due_date
                        .as_deref()
                        .or(next.due_date.as_deref())
                        .map(|due| format_due_menubar(due))
                        .filter(|s| !s.is_empty());
                    Some(match due_str {
                        Some(d) => format!("{} • {}", text, d),
                        None => text,
                    })
                })
                .unwrap_or_else(|| "No Tasks".to_string());
            let task_tooltip = data
                .as_ref()
                .map(|d| d.project_name.clone())
                .unwrap_or_else(|| "No Focused Project".to_string());
            let _ = tray.set_title(Some(task_title));
            let _ = tray.set_tooltip(Some(task_tooltip));
        }
        if let Some(tray) = app.tray_by_id(TRAY_STATUS_ID) {
            let _ = tray.set_menu(Some(status_menu));
            let menubar_label = data
                .as_ref()
                .map(|d| get_project_code(&d.project_name))
                .unwrap_or_else(|| "—".to_string());
            let next_due_str = data
                .as_ref()
                .and_then(|d| get_next_due_for_project(&d.todos))
                .map(|d| format_due_menubar(&d))
                .unwrap_or_default();
            let status_title = if next_due_str.is_empty() {
                menubar_label
            } else {
                format!("{} · {}", menubar_label, next_due_str)
            };
            let status_tooltip = data
                .as_ref()
                .map(|d| {
                    let done = d.todos.iter().filter(|t| t.checked).count();
                    let total = d.todos.len();
                    format!("{}: {}/{} done", d.project_name, done, total)
                })
                .unwrap_or_else(|| "No Focused Project".to_string());
            let _ = tray.set_title(Some(status_title));
            let _ = tray.set_tooltip(Some(status_tooltip));
        }
    }
}
