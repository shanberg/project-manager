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
    /// The sentence in the open panel. Defaulted from the label, which reads well enough for a row
    /// whose label is a noun phrase and badly for one that isn't ("Choose the areas.").
    var chooseMessage: String?
    let onChoose: (String) -> Void
    /// Offered only when there's something sensible to fall back to — a template can be cleared to the
    /// built-in one; a projects folder can't be cleared to anything.
    var onClear: (() -> Void)?
    /// What clearing falls back to, said plainly — the button is an icon, so this is the only place
    /// it gets explained.
    var clearHelp = "Clear"

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? placeholder)
                    .foregroundStyle(path == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path ?? placeholder)
                    // Yield to the buttons. Without this a path long enough to crowd them makes
                    // LabeledContent give up on one line and stack the row, so a single deep folder
                    // reshapes the pane instead of quietly truncating.
                    .layoutPriority(-1)
                // Only for something that's actually there. A path can be derived rather than chosen
                // — the areas folder is, until the first Area is made — and revealing one that doesn't
                // exist opens a Finder window on nothing.
                if let path, FileManager.default.fileExists(atPath: path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
                Button(chooseTitle) { choose() }
                // An icon, matching the reveal button beside it: "Clear" as a word is wide enough to
                // be the thing that costs the row its single line.
                if let onClear, path != nil {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(clearHelp)
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
        panel.message = chooseMessage ?? "Choose the \(label.lowercased())."
        if let path { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChoose(url.path)
    }
}

/// The removable-rows shape the domain table and both folder lists use. The add sits in the
/// section header — see `ListSectionHeader`.
///
/// `Item` is whatever identifies a row, and each list gives the answer that's true for it. A domain
/// is identified by its code: unique and never blank, because adding one picks a free letter and
/// renaming refuses a collision. A subfolder is identified by its position, because its text is the
/// thing being edited and two blank rows are a legal state you can reach by pressing Add twice.
/// Neither answer is right for both lists, so neither is baked in here.
struct EditableList<Item: Hashable, Row: View>: View {
    /// Which list this is.
    ///
    /// SwiftUI treats equal ids as the same row wherever it meets them, and these lists share one
    /// Form. Both folder lists identify rows by position, so between them the ids are `0, 1, 2…`
    /// twice over — and `docs` is in both lists by name too, so switching everything to content
    /// wouldn't settle it either. Unnamespaced, SwiftUI merges them: the area list renders the
    /// project list's rows. That isn't hypothetical, it's what it did.
    let namespace: String
    let items: [Item]
    let onRemove: (Item) -> Void
    /// True when removing would empty the list. Both lists PM keeps have to have something in them:
    /// a project can't be created without a domain, and a structure with no folders isn't one.
    var canRemove: Bool
    @ViewBuilder let row: (Item) -> Row

    /// A row's identity: what it is, and which list it's in.
    private struct RowID: Hashable {
        let namespace: String
        let item: Item
    }

    var body: some View {
        ForEach(items.map { RowID(namespace: namespace, item: $0) }, id: \.self) { rowID in
            HStack(spacing: 6) {
                row(rowID.item)
                Button {
                    onRemove(rowID.item)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!canRemove)
                .help(canRemove ? "Remove" : "At least one is required")
            }
        }
    }
}

/// A section title with the list's add button on the same line.
///
/// The add used to be the last thing in the section's content, which made it a row that isn't one:
/// it has no ⊖, it isn't part of the list, and a grouped Form draws its section container with an
/// off-by-one that lands on whichever trailing item it likes — so the button was sometimes inside
/// the rows' background and sometimes below it, and worse, sometimes took a real row out with it.
/// In the header it isn't a row at all, and the container is exactly the rows.
struct ListSectionHeader: View {
    let title: String
    let addTitle: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(addTitle)
            .accessibilityLabel(addTitle)
        }
    }
}
