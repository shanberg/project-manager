import AppKit
import PmLib

/// Opening a project's notes in Obsidian.
///
/// Two URL forms, because Obsidian only understands a file as "a note in a vault" when it's told which
/// vault. With `obsidianVault` and `obsidianVaultPath` configured — and the notes actually inside that
/// vault — the Advanced URI form can also jump to a heading, which is what puts you at today's session
/// rather than the top of a long file. Without them, a plain path open still works; it just lands at
/// the top.
@MainActor
enum ObsidianLink {
    static func url(notesPath: String, config: PmConfig?, heading: String?) -> URL? {
        let absolute = (notesPath as NSString).standardizingPath

        if let config, let vault = config.obsidianVault?.trimmed,
           let root = config.obsidianVaultPath?.trimmed {
            let vaultRoot = ((root as NSString).expandingTildeInPath as NSString).standardizingPath
            if let relative = relativePath(of: absolute, inside: vaultRoot) {
                var components = URLComponents(string: "obsidian://advanced-uri")
                var items = [URLQueryItem(name: "vault", value: vault),
                             URLQueryItem(name: "filepath", value: relative)]
                if let heading, !heading.isEmpty {
                    items.append(URLQueryItem(name: "heading", value: heading))
                }
                components?.queryItems = items
                if let url = components?.url { return url }
            }
        }

        var components = URLComponents(string: "obsidian://open")
        components?.queryItems = [URLQueryItem(name: "path", value: absolute)]
        return components?.url
    }

    /// Open a store's notes, aiming at today's session when there is one.
    static func open(store: PMStore) {
        guard let notesPath = store.notesPath else { return }
        let config = (try? loadConfig()) ?? nil
        guard let url = url(notesPath: notesPath, config: config, heading: heading(for: store)) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Today's session heading if the project has one, else the Sessions section itself. Deliberately
    /// read-only: "open my notes" shouldn't quietly write a session into them.
    private static func heading(for store: PMStore) -> String {
        guard let index = store.todaySessionIndex, let session = store.notes?.sessions[index] else {
            return "Sessions"
        }
        let label = session.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? session.date : "\(session.date) · \(label)"
    }

    /// The path of `path` relative to `root`, or nil when it isn't inside it. Compared component-wise
    /// so a sibling folder with a shared prefix ("…/VaultNotes" against "…/Vault") isn't mistaken for
    /// a child.
    private static func relativePath(of path: String, inside root: String) -> String? {
        let pathParts = (path as NSString).pathComponents
        let rootParts = (root as NSString).pathComponents
        guard pathParts.count > rootParts.count, Array(pathParts.prefix(rootParts.count)) == rootParts
        else { return nil }
        let relative = pathParts.dropFirst(rootParts.count).joined(separator: "/")
        // Obsidian addresses notes without the extension.
        return relative.hasSuffix(".md") ? String(relative.dropLast(3)) : relative
    }
}
