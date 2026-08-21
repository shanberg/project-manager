import AppKit
import PmLib

/// Creating, renaming, archiving and unarchiving projects — the operations that change which projects
/// exist, or what a project is called.
///
/// They're together because they share the awkward half. A project's identity here *is* its path
/// ("<base>:<folder name>"), so all three of them change a project's key: archiving moves it between
/// the two base folders, renaming rewrites the folder name, creating mints one. Everything holding a
/// key — `focused.json`, the open windows, the store registry — is then pointing at a project that has
/// moved, and repairing that is `repairIdentity`, which each of them ends with.
@MainActor
enum ProjectLifecycle {
    // MARK: Archiving

    /// Move a project to the other folder: archive an active one, unarchive an archived one.
    /// Returns its new project key.
    @discardableResult
    static func move(projectNamed name: String, from source: ProjectScope) throws -> String {
        let (_, paths) = try loadConfigAndPaths()
        let destination = source.opposite
        try moveProject(named: name, from: source, to: destination, paths: paths)
        Log.write("project \(source == .active ? "archived" : "unarchived"): \(name)")
        return repairIdentity(oldKey: key(base: source.path(in: paths), name: name),
                              newKey: key(base: destination.path(in: paths), name: name))
    }

    /// Archive or unarchive several projects, reporting the first failure rather than carrying on
    /// silently. Selecting a mixed set isn't offered, so every target moves the same way.
    static func move(projects entries: [PMStore.ProjectEntry]) {
        for entry in entries {
            do {
                try move(projectNamed: entry.name, from: entry.isArchived ? .archive : .active)
            } catch {
                present(error, doing: entry.isArchived ? "Couldn't unarchive “\(entry.name)”"
                                                       : "Couldn't archive “\(entry.name)”")
                return
            }
        }
    }

    // MARK: Renaming

    /// Give a project a new title, keeping its domain and number. Returns its new project key.
    @discardableResult
    static func rename(projectNamed name: String, to newTitle: String, isArchived: Bool) throws -> String {
        let (_, paths) = try loadConfigAndPaths()
        let scope: ProjectScope = isArchived ? .archive : .active
        let newName = try renameProjectTitle(nameOrPrefix: name, newTitle: newTitle)
        Log.write("project renamed: \(name) -> \(newName)")
        let base = scope.path(in: paths)
        return repairIdentity(oldKey: key(base: base, name: name), newKey: key(base: base, name: newName))
    }

    // MARK: Creating

    /// Create a project, focus it, and hand back its key. The caller decides what to open.
    static func create(domainCode: String, title: String) throws -> String {
        let (config, paths) = try loadConfigAndPaths()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw PmError.invalidProjectTitle(title: title) }
        let code = domainCode.uppercased()
        guard config.domains[code] != nil else { throw PmError.unknownDomain(code) }

        // `createProject` isn't atomic — a failed template read or notes write leaves the folder and
        // its subfolders behind — and it doesn't report which folder it got to, so there's nothing to
        // clean up by. Logged rather than swallowed: the leftover takes a number with it.
        let path = try createProject(config: config, paths: paths, domainCode: code, title: trimmedTitle)
        let name = (path as NSString).lastPathComponent
        Log.write("project created: \(name)")
        let newKey = key(base: paths.activePath, name: name)
        try? PMFiles.setFocusedProjectKey(newKey)
        PMFiles.recordRecent(projectKey: newKey, name: name)
        refresh()
        return newKey
    }

    // MARK: Identity repair

    private static func key(base: String, name: String) -> String { "\(base):\(name)" }

    /// Move everything that named the project by its old key onto the new one, and rescan.
    ///
    /// Order matters: `focused.json` is written before the windows are retargeted, because a window
    /// becoming main writes the focus itself — retarget first and it would write the *old* key straight
    /// back over the new one.
    @discardableResult
    private static func repairIdentity(oldKey: String, newKey: String) -> String {
        if PMFiles.focusedProjectKey() == oldKey {
            try? PMFiles.setFocusedProjectKey(newKey)
            PMFiles.recordRecent(projectKey: newKey, name: PMFiles.projectName(fromKey: newKey) ?? "")
        }
        for controller in WindowManager.shared.controllers where controller.projectKey == oldKey {
            WindowManager.shared.retarget(controller, to: newKey)
        }
        // The menubar, the focus panel and the notifications all follow `focused.json`; this is the
        // same re-point the config watcher would eventually make, done now so the change is immediate.
        (NSApp.delegate as? AppDelegate)?.syncFocusedStore()
        refresh()
        return newKey
    }

    /// Both project lists are derived from a folder scan, so a change on disk only shows once they're
    /// rescanned. Forced, because the change is almost always newer than the scan's TTL.
    private static func refresh() {
        ProjectIndex.shared.warmAllProjects(force: true)
        ProjectIndex.shared.warmRecents(force: true)
    }

    // MARK: Failure

    /// These are all deliberate, one-off actions on the user's own folders, and each way they fail is
    /// something only the user can resolve — a name already taken, a folder that can't be read. An
    /// alert is the honest response; a silent no-op reads as the command not existing.
    static func present(_ error: Error, doing description: String) {
        Log.write("\(description): \(error)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = description
        alert.informativeText = (error as? PmError)?.description ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
