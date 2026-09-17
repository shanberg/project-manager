import AppKit
import PmLib
import SwiftUI

/// A project's settings: its title, and what it shows in place of the progress ring.
///
/// The domain isn't here. It's part of the folder's name along with the number, and moving a project
/// between domains would mean renumbering it — a different act with a larger blast radius than a
/// settings sheet should carry.
///
/// Save rather than live edits, unlike the Settings window's panes: those write `config.json`, but a
/// title here renames a folder, and doing that once per keystroke is not an option. The icon waits for
/// Save too, so the sheet has one rule rather than two.
@MainActor
enum ProjectSettings {
    /// Takes the folder name rather than a sidebar row, so the menu bar item — which only ever has a
    /// store — can offer the same command.
    static func present(projectNamed name: String, isArchived: Bool) {
        let model = ProjectSettingsModel(projectNamed: name)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = "\(model.kind.displayName) Settings"
        let parent = sheetParent()

        func finish(saving: Bool) {
            if let parent { parent.endSheet(window) } else { NSApp.stopModal(); window.orderOut(nil) }
            // After the sheet is down: a rename can fail with an alert of its own, and the hosting
            // controller whose button is calling this shouldn't be torn down from inside the call.
            DispatchQueue.main.async {
                window.contentViewController = nil
                if saving { apply(model, projectNamed: name, isArchived: isArchived) }
            }
        }

        let host = NSHostingController(rootView: ProjectSettingsView(
            model: model, onCancel: { finish(saving: false) }, onSave: { finish(saving: true) }))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host

        NSApp.activate(ignoringOtherApps: true)
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            NSApp.runModal(for: window)
        }
    }

    /// The frontmost project window, to hang the sheet from. Nil when there isn't one — the command is
    /// also on the menu bar item's menu, and PM keeps running with every window closed — in which case
    /// the sheet comes up as a window of its own. Panels (the quick bar, the focus panel) don't count.
    private static func sheetParent() -> NSWindow? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible,
              !(window is NSPanel), window.attachedSheet == nil else { return nil }
        return window
    }

    /// The icon first, while the folder still has the name it was read under; then the title, which
    /// moves the folder and repairs everything holding its key.
    private static func apply(_ model: ProjectSettingsModel, projectNamed name: String, isArchived: Bool) {
        let icon = model.chosenIcon
        let title = model.trimmedTitle
        do {
            if icon != model.originalIcon {
                try setProjectIcon(project: name, to: icon)
                Log.write("project icon: \(name) -> \(icon?.value ?? "none")")
                if case .emoji(let emoji) = icon { EmojiCatalog.noteUsed(emoji) }
            }
            if model.color != model.originalColor {
                try setProjectColor(project: name, to: model.color)
                Log.write("project color: \(name) -> \(model.color?.value ?? "none")")
            }
            if !title.isEmpty, title != model.originalTitle {
                try ProjectLifecycle.rename(projectNamed: name, to: title, isArchived: isArchived)
            } else {
                // A rename rescans on its own. An icon alone is a notes write the open store's watcher
                // picks up, but the sidebar's scan has a TTL and needs telling.
                ProjectIndex.shared.warmAllProjects(force: true)
            }
        } catch {
            ProjectLifecycle.present(error, doing: "Couldn't save “\(name)”")
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class ProjectSettingsModel {
    enum Mode: Hashable { case progress, symbol, emoji }

    let kind: ProjectKind
    let folderName: String
    /// "W-012", shown ahead of the title because it stays put. Nil for an area, whose name is its title.
    let prefix: String?
    let originalTitle: String
    let originalIcon: ProjectIcon?
    let originalColor: ProjectColor?
    let done: Int
    let total: Int

    var title: String
    var mode: Mode
    var symbol: String
    var emoji: String
    var color: ProjectColor?
    var symbolQuery = ""
    /// The category menu's choice. Nil is All.
    var symbolCategory: String?
    /// Loaded off the main thread when the sheet opens — see `init`. Nil until then, which the grid
    /// shows as a spinner rather than an empty grid.
    private(set) var symbolCatalog: SymbolCatalog?
    var emojiQuery = ""
    let emojiCatalog = EmojiCatalog.shared
    /// Taken when the sheet opens, so choosing an emoji doesn't reshuffle the row under the pointer.
    let recentEmoji = EmojiCatalog.recents

    init(projectNamed name: String) {
        let config = (try? loadConfig()) ?? nil
        kind = ProjectKind.of(folderName: name)
        folderName = name
        let parts = kind.isNumbered
            ? try? parseProjectPrefixAndTitle(folderName: name, domainCodes: Array(config?.domains.keys ?? [:].keys))
            : nil
        prefix = parts?.prefix
        originalTitle = parts?.title ?? name
        title = originalTitle

        // One read for both the icon and the preview ring's progress.
        let raw = (try? resolveNotesHandle(project: name)).flatMap { try? $0.io.readContent(path: $0.notesPath) }
        let todos = raw.flatMap { try? notesShow(rawText: $0) }?.todos ?? []
        done = todos.filter(\.checked).count
        total = todos.count
        originalIcon = raw.flatMap(projectIcon(rawText:))
        originalColor = raw.flatMap(projectColor(rawText:))
        color = originalColor

        switch originalIcon {
        case .symbol(let name): mode = .symbol; symbol = name; emoji = Self.defaultEmoji
        case .emoji(let e): mode = .emoji; symbol = Self.defaultSymbol; emoji = e
        case nil: mode = .progress; symbol = Self.defaultSymbol; emoji = Self.defaultEmoji
        }

        // Three system plists and ~8,000 names: a first open would otherwise stall the sheet coming up.
        Task.detached(priority: .userInitiated) { [weak self] in
            let catalog = SymbolCatalog.shared
            await MainActor.run { self?.symbolCatalog = catalog }
        }
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var chosenIcon: ProjectIcon? {
        switch mode {
        case .progress: return nil
        case .symbol: return .symbol(symbol)
        case .emoji: return .emoji(emoji)
        }
    }

    var canSave: Bool {
        !trimmedTitle.isEmpty && (trimmedTitle != originalTitle || chosenIcon != originalIcon || color != originalColor)
    }

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// What the grid shows: the catalog, narrowed by the category menu and the search. A search that
    /// spells out a drawable symbol name is offered even if the catalog doesn't list it, so a symbol
    /// set by hand in the file can still be found and kept.
    var symbolResults: [String] {
        guard let catalog = symbolCatalog else { return [] }
        let query = symbolQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var results = catalog.symbols(in: symbolCategory, matching: query)
        if !query.isEmpty, !results.contains(query), ProjectIconMark.canDraw(.symbol(query)) {
            results.insert(query, at: 0)
        }
        return results
    }

    static let defaultSymbol = "star.fill"
    static let defaultEmoji = "🌿"
}

// MARK: - The mark

/// A project's chosen icon, where its ring would otherwise be: the sidebar row, the Up Next card, the
/// menu bar button and its menu's header.
///
/// A symbol is drawn without a color of its own, so it takes the foreground it's placed in — white on
/// the sidebar's selection, the label color in the menu bar — exactly as the template ring does. An
/// emoji keeps its own colors, which is what an emoji is for.
struct ProjectIconMark: View {
    let icon: ProjectIcon
    var size: CGFloat = 13
    /// The menu bar's stale-task yellow or red. Only a symbol can take it.
    var tint: Color? = nil

    /// Whether this can be drawn at all. A symbol name typed into the file by hand, or one from a newer
    /// macOS, may not exist here — and then the caller draws the ring rather than a blank.
    nonisolated static func canDraw(_ icon: ProjectIcon) -> Bool {
        switch icon {
        case .emoji: return true
        case .symbol(let name): return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        }
    }

    var body: some View {
        switch icon {
        case .symbol(let name):
            if let tint {
                Image(systemName: name).font(.system(size: size)).foregroundStyle(tint)
            } else {
                Image(systemName: name).font(.system(size: size))
            }
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size))
        }
    }
}

// MARK: - The sheet

struct ProjectSettingsView: View {
    @Bindable var model: ProjectSettingsModel
    let onCancel: () -> Void
    let onSave: () -> Void
    private let symbolColumns = [GridItem(.adaptive(minimum: 36), spacing: 4)]
    private let emojiColumns = [GridItem(.adaptive(minimum: 34), spacing: 2)]
    /// Fixed, so switching category or typing a search doesn't resize the sheet under the pointer.
    private let gridHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(spacing: 0) {
                row("Title") {
                    HStack(spacing: 6) {
                        if let prefix = model.prefix {
                            Text(prefix)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        TextField("", text: $model.title)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                }
                Divider()
                row("Icon") {
                    Picker("Icon", selection: $model.mode) {
                        Text(model.kind.showsProgress ? "Progress" : "Dotted").tag(ProjectSettingsModel.Mode.progress)
                        Text("Symbol").tag(ProjectSettingsModel.Mode.symbol)
                        Text("Emoji").tag(ProjectSettingsModel.Mode.emoji)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if model.mode == .symbol {
                    Divider()
                    symbolPicker.padding(12)
                } else if model.mode == .emoji {
                    Divider()
                    emojiPicker.padding(12)
                }
                Divider()
                row("Color") { ProjectColorPicker(color: $model.color) }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.kind.displayName) Settings").font(.system(size: 13, weight: .semibold))
                Text(model.folderName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let icon = model.chosenIcon, ProjectIconMark.canDraw(icon) {
            ProjectIconMark(icon: icon, size: 22)
        } else {
            Image(nsImage: MenubarRing.image(fraction: model.fraction, hasProject: model.total > 0,
                                             showsProgress: model.kind.showsProgress, tint: nil))
                .resizable()
                .renderingMode(.template)
                .frame(width: 24, height: 24)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 40, alignment: .leading)
            content()
        }
        // Leading, not centered: a control that doesn't stretch (the segmented picker) would otherwise
        // sit in the middle of the group and pull its label out of line with the others.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Symbols

    /// Search and a category menu over the whole catalog — the SF Symbols app's model, in a sheet.
    /// A menu rather than a strip of category icons: there are nearly thirty categories, and a strip
    /// that scrolls sideways hides most of them.
    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search symbols", text: $model.symbolQuery)
                    .textFieldStyle(.roundedBorder)
                if let catalog = model.symbolCatalog, !catalog.categories.isEmpty {
                    Picker("Category", selection: $model.symbolCategory) {
                        Label("All", systemImage: "square.grid.2x2").tag(String?.none)
                        Divider()
                        ForEach(catalog.categories) { category in
                            Label(category.title, systemImage: category.icon).tag(Optional(category.key))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            symbolGrid
            // The name is the thing you'd search for next time, and the thing written into the file.
            Text(model.symbol)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var symbolGrid: some View {
        let results = model.symbolResults
        return ScrollViewReader { proxy in
            ScrollView {
                if model.symbolCatalog == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: gridHeight)
                } else if results.isEmpty {
                    emptyResult("No symbols match “\(model.symbolQuery)”")
                } else {
                    LazyVGrid(columns: symbolColumns, spacing: 4) {
                        ForEach(results, id: \.self) { name in
                            choice(isSelected: name == model.symbol, help: name) {
                                model.symbol = name
                            } label: {
                                Image(systemName: name).font(.system(size: 16))
                            }
                            .id(name)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(height: gridHeight)
            // Open on the current choice rather than the top of eight thousand symbols.
            .task(id: model.symbolCatalog == nil) {
                guard model.symbolCatalog != nil else { return }
                proxy.scrollTo(model.symbol, anchor: .center)
            }
        }
    }

    // MARK: Emoji

    private struct EmojiSection: Identifiable {
        let id: String
        let title: String
        let icon: String
        let emoji: [EmojiCatalog.Emoji]
    }

    /// Recently Used, then Unicode's groups — the system picker's order.
    private var emojiSections: [EmojiSection] {
        var sections: [EmojiSection] = []
        let recent = model.recentEmoji.map {
            EmojiCatalog.Emoji(character: $0, name: model.emojiCatalog.name(of: $0) ?? $0)
        }
        if !recent.isEmpty {
            sections.append(EmojiSection(id: "recent", title: "Recently Used", icon: "clock", emoji: recent))
        }
        sections += model.emojiCatalog.groups.map {
            EmojiSection(id: $0.id, title: $0.title, icon: $0.icon, emoji: $0.emoji)
        }
        return sections
    }

    /// The standard emoji picker: search on top, a strip of group icons that jump the grid to their
    /// section, and one scrolling grid with the section headers pinned as you pass them.
    private var emojiPicker: some View {
        let sections = emojiSections
        let searching = !model.emojiQuery.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Search emoji", text: $model.emojiQuery)
                .textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(sections) { section in
                            Button {
                                model.emojiQuery = ""
                                proxy.scrollTo(section.id, anchor: .top)
                            } label: {
                                Image(systemName: section.icon)
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, minHeight: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(section.title)
                            .accessibilityLabel(section.title)
                        }
                    }
                    ScrollView {
                        if searching {
                            let results = model.emojiCatalog.search(model.emojiQuery)
                            if results.isEmpty {
                                emptyResult("No emoji match “\(model.emojiQuery)”")
                            } else {
                                LazyVGrid(columns: emojiColumns, spacing: 2) {
                                    ForEach(results, id: \.self) { emojiCell($0) }
                                }
                            }
                        } else {
                            LazyVGrid(columns: emojiColumns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                                ForEach(sections) { section in
                                    Section {
                                        ForEach(section.emoji, id: \.self) { emojiCell($0) }
                                    } header: {
                                        sectionHeader(section.title).id(section.id)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: gridHeight)
                }
            }
        }
    }

    private func emojiCell(_ emoji: EmojiCatalog.Emoji) -> some View {
        choice(isSelected: emoji.character == model.emoji, help: emoji.name) {
            model.emoji = emoji.character
        } label: {
            Text(emoji.character).font(.system(size: 20))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private func emptyResult(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: gridHeight)
    }

    private func choice<Label: View>(isSelected: Bool, help: String, action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
