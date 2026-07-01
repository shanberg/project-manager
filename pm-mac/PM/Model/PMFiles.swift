import Foundation
import PmLib

/// Reads and writes the small JSON files in the pm config dir that are the shared contract between
/// the `pm` CLI, the Raycast extension, and this app. We reuse `PmLib.getConfigDir()` so the app and
/// the CLI always agree on the location (respecting `PM_CONFIG_HOME`).
enum PMFiles {
    static var configDir: URL {
        URL(fileURLWithPath: getConfigDir(), isDirectory: true)
    }

    static var focusedURL: URL { configDir.appendingPathComponent("focused.json") }
    static var panelSettingsURL: URL { configDir.appendingPathComponent("panel-settings.json") }
    static var recentProjectsURL: URL { configDir.appendingPathComponent("recent-projects.json") }

    // MARK: focused.json — { "projectKey": "basePath:name" }

    private struct FocusedFile: Codable { var projectKey: String? }

    /// The focused project key, or nil if unset/unreadable.
    static func focusedProjectKey() -> String? {
        guard let data = try? Data(contentsOf: focusedURL),
              let decoded = try? JSONDecoder().decode(FocusedFile.self, from: data) else { return nil }
        let key = decoded.projectKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    static func setFocusedProjectKey(_ key: String) throws {
        let data = try JSONEncoder().encode(FocusedFile(projectKey: key))
        try ensureConfigDir()
        try data.write(to: focusedURL, options: .atomic)
    }

    /// The folder name from a project key "basePath:name" (split on the first colon), or nil.
    /// Paths don't contain colons on macOS, so the first colon reliably separates base from name.
    static func projectName(fromKey key: String) -> String? {
        guard let idx = key.firstIndex(of: ":") else { return nil }
        let name = key[key.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: recent-projects.json — [ { "projectKey", "name" } ], most-recent first, capped at 10

    struct RecentProject: Codable, Equatable {
        var projectKey: String
        var name: String
    }

    static func recentProjects() -> [RecentProject] {
        guard let data = try? Data(contentsOf: recentProjectsURL),
              let decoded = try? JSONDecoder().decode([RecentProject].self, from: data) else { return [] }
        return decoded
    }

    static func recordRecent(projectKey: String, name: String) {
        var list = recentProjects().filter { $0.projectKey != projectKey }
        list.insert(RecentProject(projectKey: projectKey, name: name), at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? ensureConfigDir()
        try? data.write(to: recentProjectsURL, options: .atomic)
    }

    private static func ensureConfigDir() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }
}
