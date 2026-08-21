import AppKit
import SwiftUI
import PmLib

/// Projects: where they live, what domains they can be filed under, and what folders each one gets.
///
/// These are the same values `pm config` reads and writes, so everything here is a read-modify-write
/// of `config.json` rather than a form with a Save button — the CLI, the settings pane and the app all
/// see one state, and there's no window in which a pane left open holds a stale copy.
struct ProjectsSettingsView: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            if let config = store.config {
                folders(config)
                domains(config)
                structure(config)
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
            PathRow(label: "Active", path: resolved?.activePath) { chosen in
                setPaths(active: chosen, archive: nil)
            }
            PathRow(label: "Archive", path: resolved?.archivePath) { chosen in
                setPaths(active: nil, archive: chosen)
            }
        } header: {
            Text("Folders")
        } footer: {
            Text("Numbers are unique across both, so a project keeps its number when it's archived.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private var resolved: ResolvedPaths? {
        store.config.flatMap { try? resolvePaths(config: $0) }
    }

    // MARK: Domains

    @ViewBuilder
    private func domains(_ config: PmConfig) -> some View {
        let codes = config.domains.keys.sorted()
        Section {
            EditableList(items: codes.indices, addTitle: "Add Domain",
                         onAdd: addDomain, onRemove: { removeDomain(codes[$0]) },
                         canRemove: codes.count > 1) { index in
                let code = codes[index]
                CommittingTextField(value: code, prompt: "Code") { renameDomain(code, to: $0) }
                    .frame(width: 70)
                    .textCase(.uppercase)
                CommittingTextField(value: config.domains[code] ?? "", prompt: "Label") { label in
                    store.update { $0.domains[code] = label.trimmingCharacters(in: .whitespaces) }
                }
            }
        } header: {
            Text("Domains")
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

    // MARK: Project structure

    @ViewBuilder
    private func structure(_ config: PmConfig) -> some View {
        Section {
            EditableList(items: config.subfolders.indices, addTitle: "Add Folder",
                         onAdd: { store.update { $0.subfolders.append("") } },
                         onRemove: { index in store.update { $0.subfolders.remove(at: index) } },
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
            Text("Project Structure")
        } footer: {
            Text("Created inside each new project. Existing projects are left alone.")
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
