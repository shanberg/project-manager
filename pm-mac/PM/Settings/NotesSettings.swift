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
            PathRow(label: "Template", path: config.notesTemplatePath,
                    placeholder: "Built-in", chooseFiles: true,
                    onChoose: { path in store.update { $0.notesTemplatePath = path } },
                    onClear: { store.update { $0.notesTemplatePath = nil } })
        } header: {
            Text("New Project Notes")
        } footer: {
            Text("A Markdown file used for every new project's notes. Write {{title}} where the project's title should go. Cleared, PM uses its built-in template.")
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
                    onChoose: { path in store.update { $0.obsidianVaultPath = path } },
                    onClear: { store.update { $0.obsidianVaultPath = nil } })
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
