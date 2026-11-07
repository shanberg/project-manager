import SwiftUI

/// The symbol and emoji pickers, shared by Project Settings and Space Settings. Each edits a binding;
/// what's done with the choice — written on Save, or at once — is the sheet's business.

/// Search and a category menu over the whole catalog — the SF Symbols app's model, in a sheet.
/// A menu rather than a strip of category icons: there are nearly thirty categories, and a strip
/// that scrolls sideways hides most of them.
struct SymbolIconPicker: View {
    @Binding var symbol: String
    @Binding var query: String
    /// The category menu's choice. Nil is All.
    @Binding var category: String?
    /// Nil until loaded off main, which the grid shows as a spinner rather than an empty grid.
    let catalog: SymbolCatalog?
    /// Fixed, so switching category or typing a search doesn't resize the sheet under the pointer.
    var gridHeight: CGFloat = 240

    private let columns = [GridItem(.adaptive(minimum: 36), spacing: 4)]

    /// What the grid shows: the catalog, narrowed by the category menu and the search. A search that
    /// spells out a drawable symbol name is offered even if the catalog doesn't list it, so a symbol
    /// set by hand in the file can still be found and kept.
    static func results(in catalog: SymbolCatalog?, category: String?, query: String) -> [String] {
        guard let catalog else { return [] }
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        var results = catalog.symbols(in: category, matching: query)
        if !query.isEmpty, !results.contains(query), ProjectIconMark.canDraw(.symbol(query)) {
            results.insert(query, at: 0)
        }
        return results
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search symbols", text: $query)
                    .textFieldStyle(.roundedBorder)
                if let catalog, !catalog.categories.isEmpty {
                    Picker("Category", selection: $category) {
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
            grid
            // The name is the thing you'd search for next time, and the thing written into the file.
            Text(symbol)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var grid: some View {
        let results = Self.results(in: catalog, category: category, query: query)
        return ScrollViewReader { proxy in
            ScrollView {
                if catalog == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: gridHeight)
                } else if results.isEmpty {
                    IconPickerEmpty(message: "No symbols match “\(query)”", height: gridHeight)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(results, id: \.self) { name in
                            IconPickerCell(isSelected: name == symbol, help: name) {
                                symbol = name
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
            .task(id: catalog == nil) {
                guard catalog != nil else { return }
                proxy.scrollTo(symbol, anchor: .center)
            }
        }
    }
}

/// The standard emoji picker: search on top, a strip of group icons that jump the grid to their
/// section, and one scrolling grid with the section headers pinned as you pass them.
struct EmojiIconPicker: View {
    @Binding var emoji: String
    @Binding var query: String
    var catalog: EmojiCatalog = .shared
    /// Taken when the sheet opens, so choosing an emoji doesn't reshuffle the row under the pointer.
    let recents: [String]
    var gridHeight: CGFloat = 240

    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 2)]

    private struct Section: Identifiable {
        let id: String
        let title: String
        let icon: String
        let emoji: [EmojiCatalog.Emoji]
    }

    /// Recently Used, then Unicode's groups — the system picker's order.
    private var sections: [Section] {
        var sections: [Section] = []
        let recent = recents.map { EmojiCatalog.Emoji(character: $0, name: catalog.name(of: $0) ?? $0) }
        if !recent.isEmpty {
            sections.append(Section(id: "recent", title: "Recently Used", icon: "clock", emoji: recent))
        }
        sections += catalog.groups.map { Section(id: $0.id, title: $0.title, icon: $0.icon, emoji: $0.emoji) }
        return sections
    }

    var body: some View {
        let sections = self.sections
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(sections) { section in
                            Button {
                                query = ""
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
                            let results = catalog.search(query)
                            if results.isEmpty {
                                IconPickerEmpty(message: "No emoji match “\(query)”", height: gridHeight)
                            } else {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(results, id: \.self) { cell($0) }
                                }
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                                ForEach(sections) { section in
                                    SwiftUI.Section {
                                        ForEach(section.emoji, id: \.self) { cell($0) }
                                    } header: {
                                        header(section.title).id(section.id)
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

    private func cell(_ choice: EmojiCatalog.Emoji) -> some View {
        IconPickerCell(isSelected: choice.character == emoji, help: choice.name) {
            emoji = choice.character
        } label: {
            Text(choice.character).font(.system(size: 20))
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// One choice in either grid: the accent fill when chosen.
struct IconPickerCell<Label: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
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

/// A search that found nothing, the grid's height so the sheet keeps its size.
struct IconPickerEmpty: View {
    let message: String
    let height: CGFloat

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
