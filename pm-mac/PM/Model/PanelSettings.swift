import Foundation

/// Window-behavior settings persisted in `~/.config/pm/panel-settings.json`, shared with Raycast.
/// `pinned` = keep the panel open when it loses focus. (The focus panel and quick bar always float
/// above other windows now, so that's no longer a setting.)
/// An external write (from Raycast) is picked up by the config-dir watcher and re-applied live.
struct PanelSettings: Codable, Equatable {
    var pinned: Bool

    static let `default` = PanelSettings(pinned: false)

    static func load() -> PanelSettings {
        guard let data = try? Data(contentsOf: PMFiles.panelSettingsURL),
              let decoded = try? JSONDecoder().decode(PanelSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: PMFiles.configDir, withIntermediateDirectories: true)
        try? data.write(to: PMFiles.panelSettingsURL, options: .atomic)
    }
}
