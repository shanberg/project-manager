import SwiftUI
import ServiceManagement
import PmLib

/// General: appearance, launch behavior, and what PM does when it isn't showing a window.
struct GeneralSettingsView: View {
    @AppStorage("PMPanelColorMode") private var colorMode: PanelColorMode = .system
    @ObservedObject private var settings = WindowSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $colorMode) {
                    Text("System").tag(PanelColorMode.system)
                    Text("Light").tag(PanelColorMode.light)
                    Text("Dark").tag(PanelColorMode.dark)
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
                Text("PM keeps running in the menu bar after you close its last window, so notifications and the ⌃⌥P shortcut keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
    }
}

/// Windows: how project windows behave — the settings that used to be the menubar's Panel submenu,
/// plus the chrome choice that replaced the panel itself.
struct WindowsSettingsView: View {
    @ObservedObject private var settings = WindowSettings.shared
    /// Pinned/floating live in the Raycast-shared settings file rather than `UserDefaults`, so they're
    /// read and written through the app delegate's copy.
    @State private var panelSettings = PanelSettings.load()

    var body: some View {
        Form {
            Section {
                Picker("Window style", selection: $settings.chromeStyle) {
                    Text("Standard").tag(WindowChromeStyle.window)
                    Text("Floating panel").tag(WindowChromeStyle.panel)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.chromeStyle) { _ in reopenWindowsNotice = true }
            } footer: {
                Text(settings.chromeStyle == .panel
                     ? "A borderless panel that sizes itself to its content, snaps to the screen edges, and hides when it loses focus."
                     : "A normal Mac window: resizable, tabbable, and remembered per project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show on all Spaces", isOn: $settings.showOnAllSpaces)
                    .onChange(of: settings.showOnAllSpaces) { _ in WindowManager.shared.applyWindowSettings() }
                Toggle("Float above other windows", isOn: $settings.floatAboveOthers)
                    .onChange(of: settings.floatAboveOthers) { _ in WindowManager.shared.applyWindowSettings() }
            } footer: {
                Text("On all Spaces, a PM window follows you between desktops and full-screen apps. (A window still lives on one display — macOS has no way to show the same window on every screen at once.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.chromeStyle == .panel {
                Section("Panel") {
                    Toggle("Keep open when it loses focus", isOn: $panelSettings.pinned)
                        .onChange(of: panelSettings.pinned) { _ in savePanelSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .alert("Reopen your windows to change their style", isPresented: $reopenWindowsNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Windows already open keep their current chrome. Close and reopen one to see the new style.")
        }
    }

    @State private var reopenWindowsNotice = false

    /// Write through the same file Raycast reads, and let the app apply it to open windows. The float
    /// toggle above is the app's own setting; `floating` in this file stays the Raycast contract.
    private func savePanelSettings() {
        panelSettings.save()
        WindowManager.shared.applyPanelSettings(panelSettings)
    }
}

/// Projects: where PM reads from. The values themselves are the CLI's config, so this shows them and
/// hands off to the place that edits them rather than offering a second, divergent editor.
struct ProjectsSettingsView: View {
    private var config: PmConfig? { (try? loadConfig()) ?? nil }
    private var paths: ResolvedPaths? { (try? loadConfigAndPaths())?.1 }

    var body: some View {
        Form {
            Section("Folders") {
                folderRow("Active", path: paths?.activePath)
                folderRow("Archive", path: paths?.archivePath)
            }

            Section("Domains") {
                if let domains = config?.domains, !domains.isEmpty {
                    ForEach(domains.sorted(by: { $0.key < $1.key }), id: \.key) { code, label in
                        LabeledContent(code, value: label)
                    }
                } else {
                    Text("No domains configured").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Open in Obsidian") {
                    Text((config?.useObsidianCLI ?? false) ? "Via the Obsidian CLI" : "Via the file system")
                        .foregroundStyle(.secondary)
                }
                Button("Configure…") {
                    if let url = URL(string: "raycast://extensions/shanberg/project-manager/configure") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("These come from PM's config file, shared with the pm command line tool and the Raycast extension.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
    }

    @ViewBuilder
    private func folderRow(_ label: String, path: String?) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not set")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let path {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
            }
        }
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
