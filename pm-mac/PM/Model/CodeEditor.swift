import AppKit

/// Which app the Project ▸ menu offers to open a code project in, and what counts as a code project.
///
/// Both used to be constants: the item said "Open in Cursor", shelled out to `open -a Cursor`, and
/// appeared only when the folder contained a `src/` directory. That's a personal preference wearing a
/// feature's clothes — invisible to anyone whose code lives in `lib/` or `Sources/`, and broken for
/// anyone who uses Zed, VS Code or Xcode. Every other "open elsewhere" in this app is either a system
/// service (Finder) or an integration with a configurable path (Obsidian); this one is now the same.
///
/// The marker is `.git` rather than `src/`. It's the honest test for "this is code" — it's what the
/// folder has because it *is* a repository, rather than because of how one language likes to lay
/// itself out — and it catches a worktree too, where `.git` is a file rather than a directory.
enum CodeEditor {
    /// The editors offered by name, in the order a project is likeliest to want them. Anything not on
    /// this list is still reachable: `chosen` stores a bundle identifier, and the Settings pane's
    /// "Choose…" writes whichever application was picked.
    static let known: [(name: String, bundleID: String)] = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("BBEdit", "com.barebones.bbedit"),
    ]

    /// The stored preference: a bundle identifier, `off`, or absent.
    ///
    /// Absent is not the same as off. Unset means "nobody has said", and the answer to that is the
    /// first known editor actually installed — which is what the hardcoded version did for the one
    /// person who had Cursor, and does something sensible for everyone else. Off is a decision, and it
    /// is remembered as one.
    static let defaultsKey = "PMCodeEditorBundleID"
    static let offValue = "off"

    /// The identifier the menu should use, resolving "unset" to the first installed known editor.
    /// Nil when the user has turned it off, or when nothing on the list is installed.
    static var resolvedBundleID: String? {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        if stored == offValue { return nil }
        if let stored, !stored.isEmpty {
            // A stored editor that has since been uninstalled falls back rather than offering a menu
            // item that can't open anything.
            return isInstalled(stored) ? stored : firstInstalled
        }
        return firstInstalled
    }

    private static var firstInstalled: String? {
        known.first { isInstalled($0.bundleID) }?.bundleID
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        url(for: bundleID) != nil
    }

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// What to call it in a menu. The known list's own name, else whatever the installed bundle calls
    /// itself, else the identifier — which is at least something to search for.
    static func displayName(_ bundleID: String) -> String {
        if let known = known.first(where: { $0.bundleID == bundleID })?.name { return known }
        guard let url = url(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// Whether this project folder looks like code, and so whether the menu item appears at all.
    static func isCodeProject(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// Open `path` in the chosen editor. Uses `NSWorkspace` rather than shelling out to `/usr/bin/open`
    /// — the app is already resolved to a URL, so there's nothing for a subprocess to look up, and a
    /// failure comes back as an error rather than as a process that quietly exited non-zero.
    static func open(path: String) {
        guard let bundleID = resolvedBundleID, let app = url(for: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                configuration: configuration) { _, error in
            if let error { Log.write("open in editor failed: \(error.localizedDescription)") }
        }
    }
}
