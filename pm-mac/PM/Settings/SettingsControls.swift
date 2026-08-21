import AppKit
import SwiftUI

/// A text field that reports its value when you're done with it — Return, or moving the focus away —
/// rather than on every keystroke.
///
/// Settings here write `config.json`, which the `pm` CLI reads and writes too. Committing per
/// character would rewrite that file a dozen times per word, and each write wakes the config watcher,
/// which reloads every open project. Once, when you've finished typing, is the right number.
struct CommittingTextField: View {
    let value: String
    var prompt: String = ""
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        // `TextField(_ title:, text:)` inside a `Form` renders its string as the *row's label*, which
        // turns a row of two fields into a row of two labels with the values pushed to the right. The
        // text here is placeholder, so it goes in `prompt` and the label is hidden outright.
        TextField(text: $draft, prompt: Text(prompt)) { EmptyView() }
            .labelsHidden()
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { isFocused in if !isFocused { commit() } }
            .onAppear { draft = value }
            // An external edit (the CLI, another pane) replaces what's shown — unless you're typing
            // into it, where having the text change under the caret is worse than being briefly stale.
            .onChange(of: value) { new in if !focused { draft = new } }
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}

/// A row naming a folder or file, with the buttons to change it and to go look at it.
struct PathRow: View {
    let label: String
    let path: String?
    var placeholder: String = "Not set"
    var chooseFiles = false
    var chooseTitle = "Choose…"
    let onChoose: (String) -> Void
    /// Offered only when there's something sensible to fall back to — a template can be cleared to the
    /// built-in one; a projects folder can't be cleared to anything.
    var onClear: (() -> Void)?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? placeholder)
                    .foregroundStyle(path == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path ?? placeholder)
                if let path {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
                Button(chooseTitle) { choose() }
                if let onClear, path != nil {
                    Button("Clear", action: onClear)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !chooseFiles
        panel.canChooseFiles = chooseFiles
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = !chooseFiles
        panel.prompt = "Choose"
        panel.message = "Choose the \(label.lowercased())."
        if let path { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChoose(url.path)
    }
}

/// The rows-plus-add-button shape both the domain table and the folder list use.
struct EditableList<Row: View>: View {
    let items: Range<Int>
    var addTitle: String
    let onAdd: () -> Void
    let onRemove: (Int) -> Void
    /// True when removing would empty the list. Both lists PM keeps have to have something in them:
    /// a project can't be created without a domain, and a structure with no folders isn't one.
    var canRemove: Bool
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        ForEach(items, id: \.self) { index in
            HStack(spacing: 6) {
                row(index)
                Button {
                    onRemove(index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!canRemove)
                .help(canRemove ? "Remove" : "At least one is required")
            }
        }
        // An icon, so the add reads as an action of the same kind as the ⊖ on each row rather than as
        // a stray line of grey text under the list.
        Button(action: onAdd) {
            Label(addTitle, systemImage: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
    }
}
