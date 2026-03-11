mod pm_notes;
mod tray;
mod tray_icons;

use notify_debouncer_mini::{new_debouncer, notify::RecursiveMode, DebounceEventResult};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::Duration;
use tauri::Emitter;
use tauri::Manager;
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};
use tauri_plugin_window_state::{StateFlags, WindowExt};

/// Tracks whether the panel/shade window is currently visible. We use this instead of
/// win.is_visible() because is_visible() is unreliable on macOS (often returns false when shown).
struct PanelVisible(pub AtomicBool);

impl Default for PanelVisible {
    fn default() -> Self {
        Self(AtomicBool::new(true)) // setup shows the window, so initial state is visible
    }
}

const PROJECT_DATA_CHANGED_EVENT: &str = "pm:project-data-changed";
const DEBOUNCE_MS: u64 = 300;
/// Interval for checking display setup and repositioning the panel when monitors change.
const DISPLAY_CHECK_INTERVAL_SECS: u64 = 5;

fn run_project_watcher(handle: tauri::AppHandle) {
    std::thread::spawn(move || loop {
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
                    let h = handle.clone();
                    let _ = handle.run_on_main_thread(move || tray::refresh_trays(&h));
                }
                Err(_) => {
                    let _ = handle.emit(PROJECT_DATA_CHANGED_EVENT, ());
                    let h = handle.clone();
                    let _ = handle.run_on_main_thread(move || tray::refresh_trays(&h));
                }
            }
            if refresh_paths {
                break;
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

/// Default height of the shade when collapsed (bottom drawer).
const SHADE_COLLAPSED_HEIGHT: u32 = 420;

#[tauri::command]
fn shade_set_expanded(app: tauri::AppHandle, expanded: bool) -> Result<(), String> {
    let shade = app
        .get_webview_window("shade")
        .ok_or_else(|| "Shade window not found".to_string())?;
    let monitor = app
        .primary_monitor()
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "No primary monitor".to_string())?;
    let mon_size = monitor.size();
    let pos = monitor.position();

    if expanded {
        let _ = shade.set_position(tauri::Position::Physical(tauri::PhysicalPosition {
            x: pos.x,
            y: pos.y,
        }));
        let _ = shade.set_size(tauri::Size::Physical(tauri::PhysicalSize {
            width: mon_size.width,
            height: mon_size.height,
        }));
    } else {
        let height = SHADE_COLLAPSED_HEIGHT.min(mon_size.height).max(200);
        let y = pos.y + (mon_size.height as i32) - (height as i32);
        let _ = shade.set_position(tauri::Position::Physical(tauri::PhysicalPosition {
            x: pos.x,
            y,
        }));
        let _ = shade.set_size(tauri::Size::Physical(tauri::PhysicalSize {
            width: mon_size.width,
            height,
        }));
    }
    Ok(())
}

/// Repositions the visible panel so it stays on-screen when the display setup changes
/// (e.g. monitor unplugged, clamshell closed). Shade is always placed at bottom of primary;
/// main window is moved to primary if it would otherwise be off-screen.
pub(crate) fn reposition_panel_for_display_change(app: &tauri::AppHandle) {
    let visible = app.state::<PanelVisible>().0.load(Ordering::SeqCst);
    if !visible {
        return;
    }
    let is_shade = std::env::var("PM_PANEL_VIEW").as_deref() == Ok("shade");

    if is_shade {
        let Some(shade) = app.get_webview_window("shade") else { return };
        let Ok(Some(monitor)) = app.primary_monitor() else { return };
        let mon_size = monitor.size();
        let pos = monitor.position();
        let width = mon_size.width;
        let height = shade
            .inner_size()
            .map(|s| s.height.clamp(200, mon_size.height))
            .unwrap_or(420_u32.min(mon_size.height));
        let y = pos.y + (mon_size.height as i32) - (height as i32);
        let _ = shade.set_position(tauri::Position::Physical(tauri::PhysicalPosition {
            x: pos.x,
            y,
        }));
        let _ = shade.set_size(tauri::Size::Physical(tauri::PhysicalSize {
            width,
            height,
        }));
        return;
    }

    let Some(window) = app.get_webview_window("main") else { return };
    let Ok(win_pos) = window.outer_position() else { return };
    let x = win_pos.x as f64;
    let y = win_pos.y as f64;
    if app.monitor_from_point(x, y).ok().and_then(|m| m).is_some() {
        return;
    }
    let Ok(Some(monitor)) = app.primary_monitor() else { return };
    let pos = monitor.position();
    let padding = 32;
    let new_x = pos.x + padding;
    let new_y = pos.y + padding;
    let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition {
        x: new_x,
        y: new_y,
    }));
}

fn run_display_check_loop(handle: tauri::AppHandle) {
    std::thread::spawn(move || {
        let interval = Duration::from_secs(DISPLAY_CHECK_INTERVAL_SECS);
        loop {
            std::thread::sleep(interval);
            let h = handle.clone();
            let _ = handle.run_on_main_thread(move || reposition_panel_for_display_change(&h));
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(PanelVisible::default())
        .plugin({
            let shortcut =
                Shortcut::new(Some(Modifiers::SUPER | Modifiers::SHIFT), Code::KeyP);
            tauri_plugin_global_shortcut::Builder::new()
                .with_shortcut(shortcut)
                .expect("PM Panel global shortcut")
                .with_handler(
                    move |app: &tauri::AppHandle, _shortcut, event| {
                        // Global shortcut fires on both key press and key release; only act on press
                        // so we don't hide then immediately show when the key is released.
                        if event.state != ShortcutState::Pressed {
                            return;
                        }
                        let is_shade =
                            std::env::var("PM_PANEL_VIEW").as_deref() == Ok("shade");
                        let label = if is_shade { "shade" } else { "main" };
                        if app.get_webview_window(label).is_some() {
                            let state = app.state::<PanelVisible>();
                            let visible = state.0.load(Ordering::SeqCst);
                            let app_handle = app.clone();
                            let label_owned = label.to_string();
                            let _ = app.run_on_main_thread(move || {
                                if let Some(win) = app_handle.get_webview_window(&label_owned) {
                                    if visible {
                                        let _ = win.hide();
                                        app_handle.state::<PanelVisible>().0.store(false, Ordering::SeqCst);
                                    } else {
                                        let _ = win.show();
                                        let _ = win.set_focus();
                                        app_handle.state::<PanelVisible>().0.store(true, Ordering::SeqCst);
                                        reposition_panel_for_display_change(&app_handle);
                                    }
                                }
                            });
                        }
                    },
                )
                .build()
        })
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
            shade_set_expanded,
        ])
        .setup(|app| {
            run_project_watcher(app.handle().clone());
            run_display_check_loop(app.handle().clone());
            if let Err(e) = tray::setup_trays(app.handle()) {
                eprintln!("Tray setup failed: {}", e);
            }
            let is_shade = std::env::var("PM_PANEL_VIEW").as_deref() == Ok("shade");

            if is_shade {
                if let Some(shade) = app.get_webview_window("shade") {
                    let _ = shade.restore_state(StateFlags::all());
                    if let Ok(Some(monitor)) = app.handle().primary_monitor() {
                        let mon_size = monitor.size();
                        let pos = monitor.position();
                        let width = mon_size.width;
                        let height = shade
                            .inner_size()
                            .map(|s| s.height.clamp(200, mon_size.height))
                            .unwrap_or(420_u32.min(mon_size.height));
                        let y = pos.y + (mon_size.height as i32) - (height as i32);
                        let _ = shade.set_position(tauri::Position::Physical(
                            tauri::PhysicalPosition { x: pos.x, y },
                        ));
                        let _ = shade.set_size(tauri::Size::Physical(tauri::PhysicalSize {
                            width,
                            height,
                        }));
                    }
                    #[cfg(target_os = "macos")]
                    {
                        use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial};
                        let _ =
                            apply_vibrancy(&shade, NSVisualEffectMaterial::HudWindow, None, None);
                    }
                    #[cfg(target_os = "windows")]
                    {
                        use window_vibrancy::apply_blur;
                        let _ = apply_blur(&shade, Some((18, 18, 18, 125)));
                    }
                    let _ = shade.show();
                    app.state::<PanelVisible>().0.store(true, Ordering::SeqCst);
                }
            } else if let Some(window) = app.get_webview_window("main") {
                let _ = window.restore_state(StateFlags::all());
                let _ = window.show();
                app.state::<PanelVisible>().0.store(true, Ordering::SeqCst);
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
                reposition_panel_for_display_change(app.handle());
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
