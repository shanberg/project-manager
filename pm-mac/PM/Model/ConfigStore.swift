import Foundation
import PmLib

/// The app's live view of `config.json`, and the one place that writes it.
///
/// Every write is a read-modify-write against the file rather than a save of some longer-held copy:
/// the CLI edits the same file, and a settings pane left open across a `pm config set` would otherwise
/// put its stale idea of every other key back on disk. That also means a save touches exactly the key
/// that changed, which is what `pm config set` does.
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var config: PmConfig?
    /// Why the config couldn't be read, for the pane to show instead of an empty form.
    @Published private(set) var loadError: String?

    private init() { reload() }

    func reload() {
        do {
            config = try loadConfig()
            loadError = config == nil ? "No config yet. Choose your project folders to create one." : nil
        } catch {
            config = nil
            loadError = (error as? PmError)?.description ?? error.localizedDescription
        }
    }

    /// Apply a change and write it. Returns false (leaving the file untouched) if the config can't be
    /// read — better to refuse than to write a fresh one over something unreadable.
    @discardableResult
    func update(_ mutate: (inout PmConfig) -> Void) -> Bool {
        guard var current = (try? loadConfig()) ?? nil else {
            reload()
            return false
        }
        let before = current
        mutate(&current)
        guard current != before else { return true }
        do {
            try saveConfig(current)
            config = current
            loadError = nil
            Log.write("config saved from settings")
            return true
        } catch {
            loadError = (error as? PmError)?.description ?? error.localizedDescription
            return false
        }
    }

    /// Create the config file for the first time, from a chosen pair of folders.
    @discardableResult
    func createDefault(activePath: String, archivePath: String) -> Bool {
        do {
            try saveConfig(createDefaultConfig(activePath: activePath, archivePath: archivePath))
            reload()
            return true
        } catch {
            loadError = (error as? PmError)?.description ?? error.localizedDescription
            return false
        }
    }
}
