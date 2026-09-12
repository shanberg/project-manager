import SwiftUI
import ServiceManagement
import PmLib

/// General: appearance, launch behavior, and what PM does when it isn't showing a window.
struct GeneralSettingsView: View {
    @AppStorage("PMPanelColorMode") private var colorMode: AppColorMode = .system
    @Bindable private var settings = WindowSettings.shared
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

/// Windows: how the focus panel and the quick bar behave.
///
/// Project windows aren't here, because there is nothing to decide about them: they're ordinary Mac
/// windows. Floating belongs to the two surfaces that exist to sit over your work while you use
/// another app — the focus panel and the quick bar — and a full editor window doing the same thing
/// was a nuisance rather than a feature.
struct WindowsSettingsView: View {
    @Bindable private var settings = WindowSettings.shared
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

/// Boards: how much of the web a canvas is allowed to run at once.
///
/// One number and one switch, because that is genuinely the whole policy. A card showing a live page
/// is a browser tab — a renderer process, its own memory, its own timers, its own network — and a
/// dashboard of a dozen embeds is a dozen of them. Everything else a board does is free by comparison,
/// which is why this pane is about the web cards and nothing else.
struct BoardsSettingsView: View {
    @AppStorage(CanvasLinkNodeView.defaultsKey) private var loadsPages = true
    @AppStorage(CanvasPageBudget.defaultsKey) private var livePages = CanvasPageBudget.defaultLivePages
    @AppStorage(CanvasPageBudget.graceDefaultsKey)
    private var offScreenGrace = CanvasPageBudget.defaultOffScreenGrace

    var body: some View {
        Form {
            Section {
                Toggle("Show live pages in link cards", isOn: $loadsPages)
                Stepper("Pages kept live: \(livePages)", value: $livePages,
                        in: CanvasPageBudget.allowed)
                    .disabled(!loadsPages)
                Picker("Pause a card left off screen", selection: $offScreenGrace) {
                    ForEach(CanvasPageBudget.graceChoices, id: \.self) { seconds in
                        Text(after(seconds)).tag(seconds)
                    }
                    Divider()
                    Text("Never").tag(TimeInterval(0))
                }
                .disabled(!loadsPages)
            } header: {
                Text("Web Cards")
            } footer: {
                // The honest version of the trade, because the number is only meaningful next to what
                // a page costs — and nothing else in PM has a per-item cost anywhere near this.
                Text("A live page is a real browser tab, and a heavy site can hold a few hundred megabytes of memory on its own. Cards past the limit keep a picture of the page and wake up when you come back to them.\n\nScrolling a card out of the window doesn't pause it, and neither does hiding it behind a workspace — a board keeps more running than it is showing, and the ones you looked at most recently keep their place in the queue. The timeout is only for a card you have well and truly left: it stops a board you wandered away from holding pages all afternoon. Every tile in a workspace runs, whatever the limit says.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .onChange(of: livePages) { _ in CanvasPageBudget.changed() }
        .onChange(of: loadsPages) { _ in CanvasPageBudget.changed() }
        .onChange(of: offScreenGrace) { _ in CanvasPageBudget.changed() }
    }

    /// The choices read as the tail of the row's own label — "Pause a card left off screen: 10 minutes".
    private func after(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

/// Notifications: which nudges PM schedules, plus a way out to the system's own permission switch
/// (which is the one that actually decides whether anything is delivered).
struct NotificationSettingsView: View {
    @AppStorage(NotificationSettings.staleKey) private var staleNudges = true
    @AppStorage(NotificationSettings.dueKey) private var dueAlerts = true
    @AppStorage(NotificationSettings.unblockKey) private var unblockAlerts = true

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
                Toggle("Tell me when something I'm waiting on is archived", isOn: $unblockAlerts)
            } footer: {
                // Its own section because it is the one alert about work in a project you are not in.
                Text("Archiving a project frees every task waiting on it, wherever they live. "
                     + "Delivered once, when it happens.")
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
        .onChange(of: unblockAlerts) { _ in NotificationSettings.changed() }
    }
}

/// The notification toggles' storage, shared between the settings pane and `NotificationManager`.
enum NotificationSettings {
    static let staleKey = "PMNotifyStale"
    static let dueKey = "PMNotifyDue"
    static let unblockKey = "PMNotifyUnblock"

    static var staleNudges: Bool { UserDefaults.standard.object(forKey: staleKey) as? Bool ?? true }
    static var dueAlerts: Bool { UserDefaults.standard.object(forKey: dueKey) as? Bool ?? true }
    /// Whether the unblock moment is announced — see `WaitingWatcher`. Unlike the other two this
    /// isn't scheduled ahead of time; it fires when a project is archived, which is why it is read at
    /// the moment of the event rather than folded into `NotificationManager.sync`'s signature.
    static var unblockAlerts: Bool { UserDefaults.standard.object(forKey: unblockKey) as? Bool ?? true }

    /// Posted when a toggle changes so the scheduler can rebuild — it skips rescheduling when its
    /// inputs look unchanged, and a settings flip isn't one of the inputs it watches.
    static let didChange = Notification.Name("PMNotificationSettingsDidChange")
    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}
