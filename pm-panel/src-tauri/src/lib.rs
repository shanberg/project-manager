mod pm_notes;

use notify_debouncer_mini::{new_debouncer, notify::RecursiveMode, DebounceEventResult};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Emitter;
use tauri::Manager;
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
use tauri_plugin_window_state::{StateFlags, WindowExt};

const PROJECT_DATA_CHANGED_EVENT: &str = "pm:project-data-changed";
const DEBOUNCE_MS: u64 = 300;

/// Grace period before a blurred panel hides. Long enough to ride out transient focus blips
/// (native date-picker popover, a quick app switch and back, the summon shortcut itself), short
/// enough that clicking away to another app still dismisses it promptly. Only the release blur
/// handler hides on blur, so this is unused in debug builds.
#[cfg_attr(debug_assertions, allow(dead_code))]
const BLUR_HIDE_DELAY_MS: u64 = 200;

/// Fixed panel width (matches min/max in tauri.conf.json); only height auto-fits.
const PANEL_WIDTH: f64 = 380.0;

/// Settings file (in the pm config dir) shared with Raycast; an external write triggers a live re-apply.
const PANEL_SETTINGS_FILE: &str = pm_notes::PANEL_SETTINGS_FILE;

/// Live handles for applying window-behavior settings. `pinned` is read by the blur handler; the
/// tray check items are kept in sync when settings change (from the menu or an external Raycast write).
struct PanelState {
    pinned: Arc<AtomicBool>,
    pin_item: CheckMenuItem<tauri::Wry>,
    float_item: CheckMenuItem<tauri::Wry>,
    autostart_item: CheckMenuItem<tauri::Wry>,
}

/// Apply settings to the live window, the shared pin flag, and the tray check items. Idempotent, so
/// it's safe to call from startup, the tray menu handler, and the config-dir watcher alike.
fn apply_panel_settings(app: &tauri::AppHandle, settings: pm_notes::PanelSettings) {
    let state = app.state::<PanelState>();
    state.pinned.store(settings.pinned, Ordering::Relaxed);
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.set_always_on_top(settings.floating);
    }
    let _ = state.pin_item.set_checked(settings.pinned);
    let _ = state.float_item.set_checked(settings.floating);
}

/// Global shortcut that summons / dismisses the panel. Ctrl+Alt+P avoids the common Cmd-based
/// system and app shortcuts on macOS.
fn toggle_shortcut() -> Shortcut {
    Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyP)
}

/// CLI flag (from Raycast or another launcher) that toggles the panel rather than just raising it.
const TOGGLE_FLAG: &str = "--toggle";

/// Show the panel (and focus it) if hidden, hide it if visible.
fn toggle_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
        } else {
            show_window(app);
        }
    }
}

/// Bring the panel to the front (show + focus), regardless of current state.
fn show_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

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
                        let mut settings_changed = false;
                        for e in events {
                            if e.path.starts_with(&config_dir) {
                                refresh_paths = true;
                            }
                            if e.path.file_name().and_then(|n| n.to_str()) == Some(PANEL_SETTINGS_FILE) {
                                settings_changed = true;
                            }
                        }
                        // A Raycast (or other external) write to panel-settings.json re-applies live.
                        if settings_changed {
                            let h = handle.clone();
                            let _ = handle.run_on_main_thread(move || {
                                apply_panel_settings(&h, pm_notes::read_panel_settings());
                            });
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

#[tauri::command]
fn add_todo(
    text: String,
    due: Option<String>,
    position: Option<pm_notes::AddPosition>,
) -> Result<(), String> {
    pm_notes::add_todo(text, due, position)
}

#[tauri::command]
fn set_due(session_index: usize, line_index: usize, due: Option<String>) -> Result<(), String> {
    pm_notes::set_due(session_index, line_index, due)
}

/// Hide the panel (used by the frontend's Escape handler).
#[tauri::command]
fn hide_panel(window: tauri::WebviewWindow) {
    let _ = window.hide();
}

/// Resize the panel to a caller-computed content height. Width stays fixed; height is clamped to a
/// sane minimum so a transient empty measurement can't collapse the window.
#[tauri::command]
fn set_panel_height(window: tauri::WebviewWindow, height: f64) -> Result<(), String> {
    let h = height.max(120.0);
    window
        .set_size(tauri::LogicalSize::new(PANEL_WIDTH, h))
        .map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // Must be the first plugin: a second launch (e.g. Raycast running the binary again)
        // is routed here instead of starting a new process. `--toggle` flips visibility;
        // any other relaunch just raises the panel.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if argv.iter().any(|a| a == TOGGLE_FLAG) {
                toggle_window(app);
            } else {
                show_window(app);
            }
        }))
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        // Launch at login (macOS LaunchAgent). No extra args → the app starts resident but
        // hidden; only an explicit `--toggle` ever shows the panel.
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    // Only one shortcut is registered, so any press is the toggle.
                    if event.state() == ShortcutState::Pressed {
                        toggle_window(app);
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
        get_focused_project,
        list_projects,
        set_focused_project,
        toggle_todo,
        set_focus_to,
        add_todo,
        set_due,
        hide_panel,
        set_panel_height,
    ])
        .setup(|app| {
            // Load persisted window-behavior settings; the tray check items reflect them and the
            // blur handler reads `pinned`.
            let settings = pm_notes::read_panel_settings();
            let pinned = Arc::new(AtomicBool::new(settings.pinned));

            // Menubar-only utility: no Dock icon.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            // Summon shortcut. Non-fatal: a key conflict or missing Input-Monitoring permission
            // shouldn't stop the app launching — the tray still provides access.
            if let Err(e) = app.global_shortcut().register(toggle_shortcut()) {
                eprintln!("pm-panel: failed to register global shortcut: {e}");
            }

            // Menubar tray: Show/Hide, the two window-behavior toggles, and Quit.
            let toggle_item = MenuItem::with_id(app, "toggle", "Show / Hide Panel", true, None::<&str>)?;
            let pin_item = CheckMenuItem::with_id(
                app, "pin", "Keep Open When Unfocused", true, settings.pinned, None::<&str>,
            )?;
            let float_item = CheckMenuItem::with_id(
                app, "float", "Float Above Other Windows", true, settings.floating, None::<&str>,
            )?;
            let autostart_enabled = app.autolaunch().is_enabled().unwrap_or(false);
            let autostart_item = CheckMenuItem::with_id(
                app, "autostart", "Launch at Login", true, autostart_enabled, None::<&str>,
            )?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit PM Panel", true, None::<&str>)?;
            let menu = Menu::with_items(
                app,
                &[
                    &toggle_item,
                    &PredefinedMenuItem::separator(app)?,
                    &pin_item,
                    &float_item,
                    &autostart_item,
                    &PredefinedMenuItem::separator(app)?,
                    &quit_item,
                ],
            )?;

            app.manage(PanelState {
                pinned: pinned.clone(),
                pin_item: pin_item.clone(),
                float_item: float_item.clone(),
                autostart_item: autostart_item.clone(),
            });

            let _tray = TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .tooltip("PM Panel")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_window(app),
                    // The check item has already toggled itself; read both, apply, and persist.
                    "pin" | "float" => {
                        let state = app.state::<PanelState>();
                        let settings = pm_notes::PanelSettings {
                            pinned: state.pin_item.is_checked().unwrap_or(false),
                            floating: state.float_item.is_checked().unwrap_or(false),
                        };
                        apply_panel_settings(app, settings);
                        let _ = pm_notes::write_panel_settings(settings);
                    }
                    // The check item has already toggled itself; enable/disable to match, then
                    // re-sync the checkmark to the real LaunchAgent state (revert on failure).
                    "autostart" => {
                        let manager = app.autolaunch();
                        let want_on = app
                            .state::<PanelState>()
                            .autostart_item
                            .is_checked()
                            .unwrap_or(false);
                        let result = if want_on {
                            manager.enable()
                        } else {
                            manager.disable()
                        };
                        if let Err(e) = result {
                            eprintln!("pm-panel: failed to set autostart: {e}");
                        }
                        let actual = manager.is_enabled().unwrap_or(want_on);
                        let _ = app.state::<PanelState>().autostart_item.set_checked(actual);
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            if let Some(window) = app.get_webview_window("main") {
                // Restore position/size but start hidden — the panel is summoned, not always shown.
                let _ = window.restore_state(StateFlags::POSITION | StateFlags::SIZE);

                // Dismiss gestures: closing hides instead of quitting; clicking away hides
                // (debounced) unless the panel is pinned.
                let win = window.clone();
                // Bumped on every focus change so a pending blur-hide can tell whether focus came
                // back (newer generation) before the grace period elapsed.
                let focus_gen = Arc::new(AtomicU64::new(0));
                #[cfg(not(debug_assertions))]
                let pinned_for_event = pinned.clone();
                window.on_window_event(move |event| match event {
                    tauri::WindowEvent::CloseRequested { api, .. } => {
                        api.prevent_close();
                        let _ = win.hide();
                    }
                    tauri::WindowEvent::Focused(true) => {
                        // Focus returned — cancel any in-flight blur-hide.
                        focus_gen.fetch_add(1, Ordering::Relaxed);
                    }
                    tauri::WindowEvent::Focused(false) => {
                        // In debug builds, keep the panel open on blur so devtools can be used.
                        #[cfg(not(debug_assertions))]
                        {
                            let generation = focus_gen.fetch_add(1, Ordering::Relaxed) + 1;
                            let win = win.clone();
                            let focus_gen = focus_gen.clone();
                            let pinned = pinned_for_event.clone();
                            std::thread::spawn(move || {
                                std::thread::sleep(Duration::from_millis(BLUR_HIDE_DELAY_MS));
                                // A later focus event superseded this one (focus came back) → keep open.
                                if focus_gen.load(Ordering::Relaxed) != generation {
                                    return;
                                }
                                if pinned.load(Ordering::Relaxed) {
                                    return;
                                }
                                if win.is_focused().unwrap_or(false) {
                                    return;
                                }
                                let _ = win.hide();
                            });
                        }
                    }
                    _ => {}
                });

                // Open devtools automatically in debug builds to diagnose rendering issues.
                #[cfg(debug_assertions)]
                window.open_devtools();
            }

            // Apply persisted settings now that the window, tray, and state all exist.
            apply_panel_settings(app.handle(), settings);

            // Watch the config dir for project changes and external (Raycast) settings writes.
            run_project_watcher(app.handle().clone());

            // Cold start via a `--toggle` launch (panel wasn't running): show it. The
            // single-instance handler covers the already-running case.
            if std::env::args().any(|a| a == TOGGLE_FLAG) {
                show_window(&app.handle().clone());
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
