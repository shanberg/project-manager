import SwiftUI
import ServiceManagement
import PmLib

/// General: appearance, launch behavior, and what PM does when it isn't showing a window.
struct GeneralSettingsView: View {
    @AppStorage("PMPanelColorMode") private var colorMode: AppColorMode = .system
    @ObservedObject private var settings = WindowSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $colorMode) {
                    Text("System").tag(AppColorMode.system)
                    Text("Light").tag(AppColorMode.light)
                    Text("Dark").tag(AppColorMode.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Launch PM at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("PM: failed to toggle login item: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Reopen windows from last session", isOn: $settings.restoreWindows)
            } footer: {
                Text("PM keeps running in the menu bar after you close its last window, so notifications and \(ShortcutHint.focusPanelPhrase) keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
    }
}

/// Windows: how project windows behave, and how the focus panel behaves.
///
/// Two sections, because they're two surfaces with genuinely different jobs. The panel's "on all
/// Spaces" and "float" are what make it a HUD; a project window mostly wants to be left alone as a
/// normal window, and only gets the float toggle because some people do want their editor on top.
struct WindowsSettingsView: View {
    @ObservedObject private var settings = WindowSettings.shared
    /// Pinned/floating live in the Raycast-shared settings file rather than `UserDefaults`, because
    /// Raycast toggles them too.
    @State private var panelSettings = PanelSettings.load()
    @AppStorage(ScreenDimSettings.quickBarDimsKey) private var quickBarDims = false
    @AppStorage(ScreenDimSettings.strengthKey) private var dimStrength = ScreenDimSettings.defaultStrength

    var body: some View {
        Form {
            Section {
                Toggle("Show on all Spaces", isOn: $settings.showOnAllSpaces)
                    .onChange(of: settings.showOnAllSpaces) { _ in
                        FocusPanelController.shared.applyWindowSettings()
                    }
                Toggle("Float above other windows", isOn: $panelSettings.floating)
                    .onChange(of: panelSettings.floating) { _ in savePanelSettings() }
                Toggle("Keep open when it loses focus", isOn: $panelSettings.pinned)
                    .onChange(of: panelSettings.pinned) { _ in savePanelSettings() }
            } header: {
                Text("Focus Panel")
            } footer: {
                Text("The focus panel shows the task you're on and stays put while you work elsewhere — \(ShortcutHint.focusPanelShowsAndHides) it. On all Spaces, it follows you between desktops and over full-screen apps. (A window still lives on one display: macOS has no way to show the same window on every screen at once.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Float above other windows", isOn: $settings.floatAboveOthers)
                    .onChange(of: settings.floatAboveOthers) { _ in
                        WindowManager.shared.applyWindowSettings()
                    }
            } header: {
                Text("Project Windows")
            } footer: {
                Text("Project windows are normal Mac windows: resizable, tabbable, and reopened where you left them. Size and position belong to the window rather than to the project, so pointing one at a different project doesn't move or resize it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Dim the screen behind the quick bar", isOn: $quickBarDims)
                Slider(value: $dimStrength, in: 0.1...0.7, step: 0.02) {
                    Text("Dimming")
                } minimumValueLabel: {
                    Text("Subtle").font(.caption)
                } maximumValueLabel: {
                    Text("Strong").font(.caption)
                }
                .disabled(!quickBarDims)
            } header: {
                Text("Quick Bar")
            } footer: {
                Text("A scrim over your windows while the quick bar is up, to push the background back. It stays under the menu bar and clicks pass straight through it, so clicking away still dismisses the bar. Reduce Transparency takes it close to solid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
    }

    /// Write through the same file Raycast reads, and let the panel apply it live.
    private func savePanelSettings() {
        panelSettings.save()
        FocusPanelController.shared.applyPanelSettings(panelSettings)
    }
}

/// Notifications: which nudges PM schedules, plus a way out to the system's own permission switch
/// (which is the one that actually decides whether anything is delivered).
struct NotificationSettingsView: View {
    @AppStorage(NotificationSettings.staleKey) private var staleNudges = true
    @AppStorage(NotificationSettings.dueKey) private var dueAlerts = true

    var body: some View {
        Form {
            Section {
                Toggle("Nudge me about a task I've been focused on for a while", isOn: $staleNudges)
                Toggle("Alert me when a task reaches its due date", isOn: $dueAlerts)
            } footer: {
                Text("Both are scheduled for the focused project only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .onChange(of: staleNudges) { _ in NotificationSettings.changed() }
        .onChange(of: dueAlerts) { _ in NotificationSettings.changed() }
    }
}

/// The notification toggles' storage, shared between the settings pane and `NotificationManager`.
enum NotificationSettings {
    static let staleKey = "PMNotifyStale"
    static let dueKey = "PMNotifyDue"

    static var staleNudges: Bool { UserDefaults.standard.object(forKey: staleKey) as? Bool ?? true }
    static var dueAlerts: Bool { UserDefaults.standard.object(forKey: dueKey) as? Bool ?? true }

    /// Posted when a toggle changes so the scheduler can rebuild — it skips rescheduling when its
    /// inputs look unchanged, and a settings flip isn't one of the inputs it watches.
    static let didChange = Notification.Name("PMNotificationSettingsDidChange")
    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}
