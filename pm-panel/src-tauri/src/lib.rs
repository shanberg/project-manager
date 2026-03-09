mod pm_notes;

use notify_debouncer_mini::{new_debouncer, notify::RecursiveMode, DebounceEventResult};
use std::sync::mpsc;
use std::time::Duration;
use tauri::Emitter;
use tauri::Manager;
use tauri_plugin_window_state::{StateFlags, WindowExt};

const PROJECT_DATA_CHANGED_EVENT: &str = "pm:project-data-changed";
const DEBOUNCE_MS: u64 = 300;

fn run_project_watcher(handle: tauri::AppHandle) {
    std::thread::spawn(move || {
        loop {
            let (config_dir, notes_path_opt) = match pm_notes::get_watch_paths() {
                Ok((dir, notes)) => (dir, notes),
                Err(_) => {
                    std::thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };

            let (tx, rx) = mpsc::channel::<DebounceEventResult>();

            let mut debouncer = match new_debouncer(Duration::from_millis(DEBOUNCE_MS), move |res| {
                let _ = tx.send(res);
            }) {
                Ok(d) => d,
                Err(_) => {
                    std::thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };

            if debouncer
                .watcher()
                .watch(&config_dir, RecursiveMode::NonRecursive)
                .is_err()
            {
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }

            if let Some(ref notes_path) = notes_path_opt {
                let _ = debouncer
                    .watcher()
                    .watch(notes_path.as_path(), RecursiveMode::NonRecursive);
            }

            let mut refresh_paths = false;
            while let Ok(res) = rx.recv() {
                match res {
                    Ok(events) => {
                        for e in events {
                            if e.path.starts_with(&config_dir) {
                                refresh_paths = true;
                            }
                        }
                        let _ = handle.emit(PROJECT_DATA_CHANGED_EVENT, ());
                    }
                    Err(_) => {
                        let _ = handle.emit(PROJECT_DATA_CHANGED_EVENT, ());
                    }
                }
                if refresh_paths {
                    break;
                }
            }
        }
    });
}

#[tauri::command]
fn get_focused_project() -> Result<pm_notes::FocusedProject, String> {
    pm_notes::get_focused_project()
}

#[tauri::command]
fn list_projects() -> Result<pm_notes::ListProjectsResult, String> {
    pm_notes::list_projects()
}

#[tauri::command]
fn set_focused_project(project_key: String) -> Result<(), String> {
    pm_notes::set_focused_project(&project_key)
}

#[tauri::command]
fn toggle_todo(session_index: usize, line_index: usize, checked: bool) -> Result<(), String> {
    pm_notes::toggle_todo(session_index, line_index, checked)
}

#[tauri::command]
fn set_focus_to(session_index: usize, line_index: usize) -> Result<(), String> {
    pm_notes::set_focus_to(session_index, line_index)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .invoke_handler(tauri::generate_handler![
        get_focused_project,
        list_projects,
        set_focused_project,
        toggle_todo,
        set_focus_to,
    ])
        .setup(|app| {
            run_project_watcher(app.handle().clone());
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.restore_state(StateFlags::all());
                let _ = window.show();
                #[cfg(target_os = "macos")]
                {
                    use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial};
                    let _ = apply_vibrancy(&window, NSVisualEffectMaterial::HudWindow, None, None);
                }
                #[cfg(target_os = "windows")]
                {
                    use window_vibrancy::apply_blur;
                    let _ = apply_blur(&window, Some((18, 18, 18, 125)));
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
