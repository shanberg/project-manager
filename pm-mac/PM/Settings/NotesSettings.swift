import SwiftUI
import PmLib

/// Notes: what a new project's notes file starts as, and how notes are read, written and opened.
///
/// Split from Projects because it's a different question — that pane is about where projects live and
/// what they're called, this one about the file inside each of them.
struct NotesSettingsView: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            if let config = store.config {
                template(config)
                display
                obsidian(config)
            } else {
                Text(store.loadError ?? "No config yet. Set your project folders first.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .onAppear { store.reload() }
    }

    // MARK: Template

    @ViewBuilder
    private func template(_ config: PmConfig) -> some View {
        Section {
            PathRow(label: "Projects", path: config.notesTemplatePath,
                    placeholder: "Built-in", chooseFiles: true,
                    chooseMessage: "Choose the Markdown file new project notes start from.",
                    onChoose: { path in store.update { $0.notesTemplatePath = path } },
                    onClear: { store.update { $0.notesTemplatePath = nil } },
                    clearHelp: "Use the built-in template")
            PathRow(label: "Areas", path: config.areaNotesTemplatePath,
                    placeholder: "Built-in", chooseFiles: true,
                    chooseMessage: "Choose the Markdown file new area notes start from.",
                    onChoose: { path in store.update { $0.areaNotesTemplatePath = path } },
                    onClear: { store.update { $0.areaNotesTemplatePath = nil } },
                    clearHelp: "Use the built-in template")
        } header: {
            Text("New Notes")
        } footer: {
            // Two rows rather than one, because a project template has a Problem and an Approach in
            // it, and handing that to an Area would give every Area the two sections the kind exists
            // to leave out.
            Text("The Markdown a new project or area's notes start from. Write {{title}} where the title should go. Cleared, PM uses its built-in template — which for an Area is a Summary and Goals, and nothing else.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Display

    /// Whether references read as pills or as the markup they are.
    ///
    /// Lives beside the notes settings rather than in a pane of its own because it's a question about
    /// the same thing they are: what the file says versus what you see. Stored in `UserDefaults`, not
    /// in pm config — the file is unchanged either way, so this is a fact about this Mac's reading of
    /// it rather than about the project.
    @ViewBuilder
    private var display: some View {
        Section {
            Toggle("Show link syntax", isOn: Binding(get: { TokenDisplay.showsSyntax },
                                                     set: { TokenDisplay.showsSyntax = $0 }))
        } header: {
            Text("Display")
        } footer: {
            Text("Off, a reference reads as a pill — “Vendor Contract”. On, it reads as it's written "
                 + "in the file — “[[W-3 Vendor Contract]]”. Either way the file is the same.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Obsidian

    @ViewBuilder
    private func obsidian(_ config: PmConfig) -> some View {
        let vault = config.obsidianVault ?? ""
        let vaultPath = config.obsidianVaultPath
        Section {
            LabeledContent("Vault name") {
                CommittingTextField(value: vault, prompt: "My Vault") { name in
                    store.update { $0.obsidianVault = name.trimmingCharacters(in: .whitespaces) }
                }
            }
            PathRow(label: "Vault folder", path: vaultPath,
                    chooseMessage: "Choose your Obsidian vault's folder.",
                    onChoose: { path in store.update { $0.obsidianVaultPath = path } },
                    onClear: { store.update { $0.obsidianVaultPath = nil } },
                    clearHelp: "Forget the vault folder")
            Toggle("Read and write notes through the Obsidian CLI",
                   isOn: Binding(get: { config.useObsidianCLI ?? false },
                                 set: { on in store.update { $0.useObsidianCLI = on } }))
                // Turning it on without a vault would mean falling straight back to file I/O on every
                // read, which looks like the setting doing nothing.
                .disabled(vault.isEmpty || vaultPath == nil)
        } header: {
            Text("Obsidian")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("With both set, Open in Obsidian jumps to today's session rather than the top of the file.")
                if vault.isEmpty || vaultPath == nil {
                    Text("Set both to enable the CLI option.")
                } else if config.useObsidianCLI == true {
                    Text("Needs Obsidian 1.12 or later with its CLI enabled. If it isn't available, PM reads and writes the files directly.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
