import Foundation

/// A card the sidebar's address field (or its add menu) makes, rather than going to an address
/// (docs/spaces.md § Adding cards from the sidebar).
enum SpaceNewCard: Equatable {
    /// A kind from the add list: a card, a view, a frame; a web or private web card asks for its address.
    case kind(CanvasAddCommand)
    /// A folder card on this folder.
    case folder(URL)
    /// A file card on this file.
    case file(URL)
    /// The open panel, for a folder that isn't among the recent ones.
    case chooseFolder
}

/// The card kinds the address field knows by name: what matches what you typed, what to fill in after
/// the caret, and paths on this Mac.
///
/// Pure (no board, no window), so the matching is tested — see `SpaceCardKindsTests`.
enum SpaceCardKinds {
    struct Kind: Equatable {
        let command: CanvasAddCommand
        /// The words that make it, lowercased. The first is what the field fills in.
        let names: [String]
        /// The row's name and what it says after it.
        let title: String
        let detail: String
        let symbol: String
    }

    /// Every kind the field makes, in the add list's order. No Web: the field already makes web cards;
    /// no Project Note: it's a project's Notes row.
    static let all: [Kind] = [
        Kind(command: .card, names: ["card", "text"], title: "Card", detail: "New card", symbol: "doc.text"),
        Kind(command: .file, names: ["file"], title: "File\u{2026}", detail: "New file card", symbol: "doc"),
        Kind(command: .folder, names: ["folder"], title: "Folder", detail: "New folder card", symbol: "folder"),
        Kind(command: .privateWeb, names: ["private"], title: "Private Web Card",
             detail: "Signed in as nobody", symbol: "eye.slash"),
        view(.dayView, "day"), view(.leftoversView, "leftovers"), view(.comingUpView, "coming up"),
        view(.projectsView, "projects"), view(.timeView, "time"), view(.waitingView, "waiting"),
        view(.searchView, "search"),
        Kind(command: .frame, names: ["frame"], title: "Frame", detail: "New frame", symbol: "rectangle.dashed"),
    ]

    private static func view(_ command: CanvasAddCommand, _ name: String) -> Kind {
        Kind(command: command, names: [name], title: command.viewName ?? name.capitalized,
             detail: "New view", symbol: command.viewKind?.symbol ?? "list.bullet")
    }

    /// Typed this much before a kind is offered or filled in: one letter is the start of every address.
    static let minimum = 2

    /// The kinds whose names start with what was typed, in the list's order.
    static func matches(_ typed: String) -> [Kind] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= minimum, !isPath(needle) else { return [] }
        return all.filter { $0.names.contains { $0.hasPrefix(needle) } }
    }

    /// The kind whose whole name was typed — what Return makes.
    static func exact(_ text: String) -> Kind? {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.names.contains(needle) }
    }

    /// What the field shows once the rest of a kind's name is filled in after `typed`, or nil. Your own
    /// letters are kept as you typed them.
    static func filled(_ typed: String) -> String? {
        let needle = typed.lowercased()
        guard needle.count >= minimum, needle.first?.isWhitespace == false else { return nil }
        for kind in all {
            guard let name = kind.names.first(where: { $0.hasPrefix(needle) && $0 != needle }) else { continue }
            return typed + name.dropFirst(typed.count)
        }
        return nil
    }

    // MARK: Paths

    /// A path on this Mac: starts with ~ or /.
    static func isPath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("~") || trimmed.hasPrefix("/")
    }

    struct PathHit: Equatable {
        let url: URL
        let isFolder: Bool
    }

    /// What's in the folder a path is being typed into, starting with its last part: folders first,
    /// then files, by name. Hidden items only when you've typed the dot.
    static func paths(_ text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      limit: Int = 8) -> [PathHit] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard isPath(trimmed) else { return [] }
        let expanded = trimmed == "~" ? home.path + "/"
            : trimmed.hasPrefix("~/") ? home.path + "/" + trimmed.dropFirst(2) : trimmed
        guard expanded.hasPrefix("/") else { return [] }
        let folder: URL, prefix: String
        if expanded.hasSuffix("/") {
            folder = URL(fileURLWithPath: expanded, isDirectory: true)
            prefix = ""
        } else {
            let url = URL(fileURLWithPath: expanded)
            folder = url.deletingLastPathComponent()
            prefix = url.lastPathComponent.lowercased()
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: []) else { return [] }
        let hits = items.compactMap { url -> PathHit? in
            let name = url.lastPathComponent
            guard name.lowercased().hasPrefix(prefix), !name.hasPrefix(".") || prefix.hasPrefix(".") else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // An app or a bundle is a file here, as the Finder shows it.
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return PathHit(url: url, isFolder: isFolder)
        }
        return Array(hits.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder
                : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }.prefix(limit))
    }

    /// How a path is written back into the field: under the home folder as ~/…, a folder ending in /.
    static func written(_ url: URL, isFolder: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { path = "~" } else if path.hasPrefix(homePath + "/") { path = "~" + path.dropFirst(homePath.count) }
        return isFolder && !path.hasSuffix("/") ? path + "/" : path
    }
}

/// The folders New Folder offers before the open panel: the project's own folder, folders put on cards
/// lately (`PMRecentCardFolders`, newest first), and Downloads.
enum SpaceRecentFolders {
    static let key = "PMRecentCardFolders"
    static let kept = 12
    static let shown = 5

    static func list(projectFolder: URL?, defaults: UserDefaults = .standard,
                     downloads: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                     exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        let recent = (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        var seen: Set<String> = []
        var out: [URL] = []
        for url in [projectFolder].compactMap({ $0 }) + recent + [downloads].compactMap({ $0 }) {
            let path = url.standardizedFileURL.path
            guard exists(url), seen.insert(path).inserted else { continue }
            out.append(url)
            if out.count == shown { break }
        }
        return out
    }

    /// A folder was put on a card: it leads the list next time.
    static func note(_ url: URL, defaults: UserDefaults = .standard) {
        let path = url.standardizedFileURL.path
        var paths = (defaults.stringArray(forKey: key) ?? []).filter { $0 != path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(kept)), forKey: key)
    }
}
