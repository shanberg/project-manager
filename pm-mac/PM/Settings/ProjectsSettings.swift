import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PmLib

/// Projects: where they live, what domains they can be filed under, and what folders each one gets.
///
/// These are the same values `pm config` reads and writes, so everything here is a read-modify-write
/// of `config.json` rather than a form with a Save button — the CLI, the settings pane and the app all
/// see one state, and there's no window in which a pane left open holds a stale copy.
struct ProjectsSettingsView: View {
    @ObservedObject private var store = ConfigStore.shared
    /// The raw code-editor preference. Empty means unset, which `CodeEditor` resolves rather than
    /// treating as off — see `CodeEditor.resolvedBundleID`.
    @AppStorage(CodeEditor.defaultsKey) private var storedEditor = ""
    /// Whether link rows fetch their site's icon — the app's only network call. See `FaviconLoader`.
    @AppStorage(FaviconLoader.defaultsKey) private var fetchFavicons = true

    var body: some View {
        Form {
            if let config = store.config {
                folders(config)
                domains(config)
                structure(config)
                codeEditor
                links
            } else {
                firstRun
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .onAppear { store.reload() }
    }

    // MARK: Folders

    @ViewBuilder
    private func folders(_ config: PmConfig) -> some View {
        Section {
            PathRow(label: "Active", path: resolved?.activePath,
                    chooseMessage: "Choose the folder your active projects live in.") { chosen in
                setPaths(active: chosen, archive: nil)
            }
            PathRow(label: "Archive", path: resolved?.archivePath,
                    chooseMessage: "Choose the folder archived projects move to.") { chosen in
                setPaths(active: nil, archive: chosen)
            }
            PathRow(label: "Areas", path: resolved?.areasPath,
                    chooseMessage: "Choose the folder your areas live in.",
                    onChoose: { setAreas($0) },
                    // Offered only when there's an explicit value to clear. Clearing goes back to the
                    // derived location, and the row is already showing what that would be.
                    onClear: config.areasPath == nil ? nil : { setAreas(nil) },
                    clearHelp: "Go back to the location PM works out for itself")
        } header: {
            Text("Folders")
        } footer: {
            Text("Numbers are unique across Active and Archive, so a project keeps its number when it's archived. Areas aren't numbered.\n\n\(areasNote(config))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Areas are the one root PM will invent a location for, so the row has to say where the location
    /// it's showing came from. And they're the one root a folder doesn't join by being in it: an Area
    /// is a folder PM has written notes into, which means a folder already on disk stays invisible
    /// until it's taken on — worth saying here, because the alternative is reading an empty list as a
    /// broken one.
    private func areasNote(_ config: PmConfig) -> String {
        let origin = config.areasPath == nil
            ? "Areas isn't set, so PM is using this — inside your PARA folder, or beside Active. Choose one to pin it."
            : "Clear Areas to go back to the location PM works out for itself."
        return "\(origin) A folder that's already there becomes an Area once you take it on: File ▸ Take On a Folder…"
    }

    /// Change one of the project folders, then bring the app's idea of what's open with it.
    ///
    /// Both paths are always written, even though only one was chosen. `paraPath` is a fallback that
    /// supplies *both* folders, and it's consulted whenever either explicit path is empty — so setting
    /// only Active on a config that leans on `paraPath` would leave Archive empty, send the resolver
    /// back to the fallback, and quietly ignore the folder that was just chosen. Writing the other
    /// path's current resolved value settles the question without touching `paraPath`, which stays as
    /// the portable default it was set up to be.
    ///
    /// Then the repair: every project key names the folder it was found in, so this invalidates all of
    /// them at once. `rebase` moves the focused project and any open window across rather than leaving
    /// them pointing into the folder you just stopped using.
    private func setPaths(active: String?, archive: String?) {
        guard let before = resolved else { return }
        guard store.update({ config in
            config.activePath = active ?? before.activePath
            config.archivePath = archive ?? before.archivePath
        }) else { return }
        guard let after = resolved else { return }
        ProjectLifecycle.rebase(from: before, to: after)
    }

    /// Areas are the one root that's allowed to be unset, so clearing writes `nil` rather than the
    /// path currently resolved. Writing that back would pin the derived location, which would make
    /// "clear" the one action that permanently commits to it.
    ///
    /// The rebase is here for the same reason it's in `setPaths`: a project key names the folder its
    /// project was found in, so moving the areas root invalidates the key of every open or focused
    /// Area.
    private func setAreas(_ path: String?) {
        guard let before = resolved else { return }
        guard store.update({ $0.areasPath = path }) else { return }
        guard let after = resolved else { return }
        ProjectLifecycle.rebase(from: before, to: after)
    }

    private var resolved: ResolvedPaths? {
        store.config.flatMap { try? resolvePaths(config: $0) }
    }

    // MARK: Domains

    @ViewBuilder
    private func domains(_ config: PmConfig) -> some View {
        let codes = config.domains.keys.sorted()
        Section {
            EditableList(namespace: "domain", items: codes, onRemove: removeDomain,
                         canRemove: codes.count > 1) { code in
                CommittingTextField(value: code, prompt: "Code") { renameDomain(code, to: $0) }
                    .frame(width: 70)
                    .textCase(.uppercase)
                CommittingTextField(value: config.domains[code] ?? "", prompt: "Label") { label in
                    store.update { $0.domains[code] = label.trimmingCharacters(in: .whitespaces) }
                }
            }
        } header: {
            ListSectionHeader(title: "Domains", addTitle: "Add Domain", onAdd: addDomain)
        } footer: {
            Text("The code leads a project's name — W-012 Website Refresh. Renaming a code here doesn't rename existing projects, which keep the code they were created with.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addDomain() {
        store.update { config in
            // First free single letter, so the new row is usable without having to think of a code.
            let taken = Set(config.domains.keys)
            let free = Self.codeAlphabet.first { !taken.contains($0) }
            config.domains[free ?? "NEW"] = ""
        }
    }

    private static let codeAlphabet = (UInt8(ascii: "A")...UInt8(ascii: "Z"))
        .map { String(UnicodeScalar($0)) }

    private func removeDomain(_ code: String) {
        store.update { config in
            guard config.domains.count > 1 else { return }
            config.domains[code] = nil
        }
    }

    /// Codes are uppercased and can't collide — two rows with the same code would be one row after the
    /// next save, silently taking the second one's label.
    private func renameDomain(_ code: String, to newCode: String) {
        let trimmed = newCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, trimmed != code else { return }
        store.update { config in
            guard config.domains[trimmed] == nil else { return }
            let label = config.domains[code]
            config.domains[code] = nil
            config.domains[trimmed] = label ?? ""
        }
    }

    // MARK: Structure

    /// Two lists, because the two kinds are scaffolded differently and always were — an Area has no
    /// `deliverables/` or `previews/`, because an Area doesn't ship. Showing one list and applying it
    /// to both would be a smaller pane that lies about what gets created.
    @ViewBuilder
    private func structure(_ config: PmConfig) -> some View {
        Section {
            EditableList(namespace: "project-folder", items: Array(config.subfolders.indices),
                         onRemove: { index in
                             store.update { config in
                                 guard config.subfolders.indices.contains(index) else { return }
                                 config.subfolders.remove(at: index)
                             }
                         },
                         canRemove: config.subfolders.count > 1) { index in
                CommittingTextField(value: config.subfolders[index], prompt: "Folder name") { name in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    store.update { config in
                        guard config.subfolders.indices.contains(index) else { return }
                        if trimmed.isEmpty { config.subfolders.remove(at: index) }
                        else { config.subfolders[index] = trimmed }
                    }
                }
            }
        } header: {
            ListSectionHeader(title: "Project Structure", addTitle: "Add Folder",
                              onAdd: { store.update { $0.subfolders.append("") } })
        } footer: {
            Text("Created inside each new project. Existing projects are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            let folders = areaSubfolders(config)
            EditableList(namespace: "area-folder", items: Array(folders.indices),
                         onRemove: { index in
                             updateAreaSubfolders { folders in
                                 guard folders.indices.contains(index) else { return }
                                 folders.remove(at: index)
                             }
                         },
                         canRemove: folders.count > 1) { index in
                CommittingTextField(value: folders[index], prompt: "Folder name") { name in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    updateAreaSubfolders { folders in
                        guard folders.indices.contains(index) else { return }
                        if trimmed.isEmpty { folders.remove(at: index) }
                        else { folders[index] = trimmed }
                    }
                }
            }
        } header: {
            ListSectionHeader(title: "Area Structure", addTitle: "Add Folder",
                              onAdd: { updateAreaSubfolders { $0.append("") } })
        } footer: {
            Text("Created inside each new area. A folder you take on keeps the shape it already has — it only gains the docs folder its notes go in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What an Area is actually created with. `areaSubfolders` is optional and unset in every config
    /// written before Areas existed, so the pane shows the built-in list rather than an empty one —
    /// and the first edit writes it out, which is why every mutation goes through `update` below.
    private func areaSubfolders(_ config: PmConfig) -> [String] {
        config.areaSubfolders ?? defaultAreaSubfolders
    }

    private func updateAreaSubfolders(_ change: (inout [String]) -> Void) {
        store.update { config in
            var folders = config.areaSubfolders ?? defaultAreaSubfolders
            change(&folders)
            config.areaSubfolders = folders
        }
    }

    // MARK: Code editor

    /// Which app "Open in…" uses for a project that's a repository.
    ///
    /// The menu item behind this was hardcoded to Cursor and gated on a `src/` folder, which made it a
    /// feature exactly one person could use. The picker lists the known editors that are actually
    /// installed — offering to open a project in an app you don't have is worse than not offering —
    /// plus anything previously chosen by hand, plus Off.
    @ViewBuilder
    private var codeEditor: some View {
        Section {
            Picker("Open code projects in", selection: editorSelection) {
                ForEach(editorChoices, id: \.bundleID) { choice in
                    Text(choice.name).tag(choice.bundleID)
                }
                Divider()
                Text("Nothing").tag(CodeEditor.offValue)
            }
            Button("Choose Another App…") { chooseEditor() }
        } header: {
            Text("Code")
        } footer: {
            Text("A project counts as code when its folder is a git repository. The menu item appears under Project ▸ in the menu bar item, and only for those.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The installed known editors, plus a hand-picked one that isn't on the list so the picker can
    /// show what's actually selected rather than silently landing on something else.
    private var editorChoices: [(name: String, bundleID: String)] {
        var choices = CodeEditor.known.filter { CodeEditor.isInstalled($0.bundleID) }
        if let current = CodeEditor.resolvedBundleID,
           !choices.contains(where: { $0.bundleID == current }) {
            choices.append((name: CodeEditor.displayName(current), bundleID: current))
        }
        return choices
    }

    /// Shows the *resolved* editor rather than the raw preference, so an unset value displays the one
    /// the menu will really use instead of leaving the picker on nothing. Writes go through
    /// `storedEditor` so the pane redraws — a plain `UserDefaults` write would land silently and leave
    /// the picker showing the old choice until something else caused a body pass.
    private var editorSelection: Binding<String> {
        Binding(
            get: {
                storedEditor == CodeEditor.offValue
                    ? CodeEditor.offValue
                    : (CodeEditor.resolvedBundleID ?? CodeEditor.offValue)
            },
            set: { storedEditor = $0 })
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose the app to open code projects in."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        storedEditor = bundleID
    }

    // MARK: Links

    /// The one network call the app makes, and the switch for it.
    ///
    /// Worth a pane row rather than a silent default: the hosts reached are read out of a project's
    /// own notes, so an internal tracker or a client's staging box is exactly the kind of address that
    /// ends up in there. An app that touches the network nowhere else owes its user the sentence.
    @ViewBuilder
    private var links: some View {
        Section {
            Toggle("Show site icons beside links", isOn: $fetchFavicons)
        } header: {
            Text("Links")
        } footer: {
            Text("Fetches each linked site's own icon from that site, once per site, and keeps it for the session. Nothing else is sent and no third-party icon service is used — but it is the only time PM goes to the network, so it's here to turn off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: First run

    /// No config file yet. One button, because until the folders are chosen there's nothing else here
    /// that can be set.
    @ViewBuilder
    private var firstRun: some View {
        Section {
            Text(store.loadError ?? "No config yet.")
                .foregroundStyle(.secondary)
            Button("Choose Project Folders…") { chooseInitialFolders() }
        }
    }

    private func chooseInitialFolders() {
        guard let active = pickFolder(message: "Choose the folder your active projects live in.") else { return }
        guard let archive = pickFolder(message: "Choose the folder archived projects move to.") else { return }
        store.createDefault(activePath: active, archivePath: archive)
        ProjectIndex.shared.warmAllProjects(force: true)
        ProjectIndex.shared.warmRecents(force: true)
    }

    private func pickFolder(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
