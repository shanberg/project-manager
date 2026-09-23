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
                if saving {
                    apply(model, projectNamed: name, isArchived: isArchived)
                    ProjectAppearancePreview.shared.commit(for: name)
                } else {
                    ProjectAppearancePreview.shared.cancel(for: name)
                }
            }
        }

        // The first touch of colour or texture lifts the dimming off the window behind, and from then
        // on the window shows each choice as it's made — see `ProjectAppearancePreview`.
        let onAppearanceChange: (ProjectAppearancePreview.Appearance) -> Void = { appearance in
            if let parent { SheetDimming.reveal(parent) }
            ProjectAppearancePreview.shared.show(appearance, for: name)
        }

        let host = NSHostingController(rootView: ProjectSettingsView(
            model: model, onCancel: { finish(saving: false) }, onSave: { finish(saving: true) },
            onAppearanceChange: onAppearanceChange))
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
        let title = model.trimmedTitle
        do {
            if model.iconChanged {
                let icon = try savedIcon(model, projectNamed: name)
                try setProjectIcon(project: name, to: icon)
                Log.write("project icon: \(name) -> \(icon?.value ?? "none")")
                if case .emoji(let emoji) = icon { EmojiCatalog.noteUsed(emoji) }
            }
            if model.color != model.originalColor {
                try setProjectColor(project: name, to: model.color)
                Log.write("project color: \(name) -> \(model.color?.value ?? "none")")
            }
            if model.textureChanged {
                try setProjectTexture(project: name, to: savedTexture(model, projectNamed: name),
                                      style: model.textureStyle)
                Log.write("project texture: \(name) -> \(model.chosenTexture?.value ?? "none")")
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

    /// The icon to write, copying an image picked in the sheet into the attachments folder first — the
    /// same as `savedTexture`, below.
    private static func savedIcon(_ model: ProjectSettingsModel, projectNamed name: String) throws -> ProjectIcon? {
        guard let source = model.pendingIconImage, model.mode == .image else { return model.chosenIcon }
        let notes = URL(fileURLWithPath: try resolveNotesHandle(project: name).notesPath)
        let landing = try copyNoteAttachment(source, forNoteAt: notes)
        return .image(path: "\(markdownAttachmentsFolder)/\(landing.lastPathComponent)", recolor: model.iconRecolor)
    }

    /// The texture to write. An image picked in the sheet is copied into the attachments folder beside
    /// the notes first — under whatever name it lands as, since `copyNoteAttachment` steps past a file
    /// already there — and the texture names that copy.
    private static func savedTexture(_ model: ProjectSettingsModel, projectNamed name: String) throws -> ProjectTexture? {
        guard let source = model.pendingTextureImage, model.textureMode == .image else { return model.chosenTexture }
        let notes = URL(fileURLWithPath: try resolveNotesHandle(project: name).notesPath)
        let landing = try copyNoteAttachment(source, forNoteAt: notes)
        return .image("\(markdownAttachmentsFolder)/\(landing.lastPathComponent)")
    }
}

// MARK: - Model

@MainActor
@Observable
final class ProjectSettingsModel {
    enum Mode: Hashable { case progress, symbol, emoji, image }
    enum TextureMode: Hashable { case none, pattern, image }

    let kind: ProjectKind
    let folderName: String
    /// "W-012", shown ahead of the title because it stays put. Nil for an area, whose name is its title.
    let prefix: String?
    let originalTitle: String
    let originalIcon: ProjectIcon?
    let originalColor: ProjectColor?
    let originalTexture: ProjectTexture?
    let originalTextureStyle: ProjectTextureStyle
    /// Where the notes file is, for finding an image texture already set. Nil when it can't be resolved.
    let notesPath: String?
    let done: Int
    let total: Int

    var title: String
    var mode: Mode
    var symbol: String
    var emoji: String
    var color: ProjectColor?
    /// The image icon, relative to the notes — the saved one, or where a picked one will land. Kept while
    /// another mode is chosen, so switching back finds it.
    private(set) var iconImagePath: String?
    /// An image picked for the icon and not saved yet — copied into the attachments folder on Save.
    private(set) var pendingIconImage: URL?
    /// Whether the image icon is drawn in the project's colour rather than its own.
    var iconRecolor = false
    var textureMode: TextureMode
    /// Kept while the mode is Image or None, so switching back finds the pattern you had.
    var texturePattern: ProjectTexture.Name
    /// The image texture, relative to the notes — the saved one, or where a picked one will land. Kept
    /// while the mode is Pattern or None, for the same reason.
    private(set) var textureImagePath: String?
    /// An image picked for the texture and not saved yet — copied into the attachments folder on Save.
    private(set) var pendingTextureImage: URL?
    /// The image texture's pixels, loaded once — the tile is dithered from them at whatever tile size
    /// is chosen.
    private(set) var textureImageSource: CGImage?
    @ObservationIgnored private var ditheredImage: (cells: Int, tile: CanvasTexture.Tile)?
    var textureStyle: ProjectTextureStyle
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
        let handle = try? resolveNotesHandle(project: name)
        notesPath = handle?.notesPath
        let raw = handle.flatMap { try? $0.io.readContent(path: $0.notesPath) }
        let todos = raw.flatMap { try? notesShow(rawText: $0) }?.todos ?? []
        (done, total) = todos.progress
        originalIcon = raw.flatMap(projectIcon(rawText:))
        originalColor = raw.flatMap(projectColor(rawText:))
        color = originalColor
        originalTexture = raw.flatMap(projectTexture(rawText:))
        originalTextureStyle = raw.map(projectTextureStyle(rawText:)) ?? .standard
        textureStyle = originalTextureStyle
        switch originalTexture {
        case .named(let name):
            textureMode = .pattern; texturePattern = name
        case .image(let path):
            textureMode = .image; texturePattern = Self.defaultPattern; textureImagePath = path
            let url = handle.flatMap { ProjectTexture.image(path).imageURL(notesPath: $0.notesPath) }
            textureImageSource = url.flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        case nil:
            textureMode = .none; texturePattern = Self.defaultPattern
        }

        switch originalIcon {
        case .symbol(let name): mode = .symbol; symbol = name; emoji = Self.defaultEmoji
        case .emoji(let e): mode = .emoji; symbol = Self.defaultSymbol; emoji = e
        case .image(let path, let recolor):
            mode = .image; symbol = Self.defaultSymbol; emoji = Self.defaultEmoji
            iconImagePath = path; iconRecolor = recolor
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
        case .image: return iconImagePath.map { .image(path: $0, recolor: iconRecolor) }
        }
    }

    /// The chosen icon as it can be drawn: an image's path made absolute — the picked file itself until
    /// Save copies it.
    var drawableIcon: ProjectIcon? {
        if mode == .image, let pendingIconImage {
            return .image(path: pendingIconImage.path, recolor: iconRecolor)
        }
        return chosenIcon?.resolved(notesPath: notesPath)
    }

    var iconImageName: String? {
        pendingIconImage?.lastPathComponent ?? iconImagePath.map { ($0 as NSString).lastPathComponent }
    }

    /// An image counts as chosen at once, so the sheet shows it; the copy waits for Save.
    func chooseIconImage(_ url: URL) {
        guard ProjectIconImages.image(atPath: url.path) != nil else { NSSound.beep(); return }
        pendingIconImage = url
        iconImagePath = "\(markdownAttachmentsFolder)/\(url.lastPathComponent)"
        mode = .image
    }

    var iconChanged: Bool { chosenIcon != originalIcon || (mode == .image && pendingIconImage != nil) }

    var canSave: Bool {
        !trimmedTitle.isEmpty && (trimmedTitle != originalTitle || iconChanged || color != originalColor
            || textureChanged)
    }

    var chosenTexture: ProjectTexture? {
        switch textureMode {
        case .none: return nil
        case .pattern: return .named(texturePattern)
        case .image: return textureImagePath.map(ProjectTexture.image)
        }
    }

    /// The style only counts while there's a texture for it to style: clearing one drops the other.
    var textureChanged: Bool {
        chosenTexture != originalTexture
            || (chosenTexture != nil && textureStyle != originalTextureStyle)
            || (textureMode == .image && pendingTextureImage != nil)
    }

    /// What the preview draws: the choice as it stands, not as it was saved.
    var previewTexture: CanvasTexture.Spec? {
        switch textureMode {
        case .none: return nil
        case .pattern: return CanvasTexture.Spec(tile: CanvasTexture.tile(rows: CanvasTexture.rows(texturePattern)),
                                                 style: textureStyle)
        case .image: return textureImageTile.map { CanvasTexture.Spec(tile: $0, style: textureStyle) }
        }
    }

    /// The image as it will be drawn, dithered once per tile size rather than on every redraw.
    var textureImageTile: CanvasTexture.Tile? {
        guard let source = textureImageSource else { return nil }
        let cells = textureStyle.tile
        if let ditheredImage, ditheredImage.cells == cells { return ditheredImage.tile }
        guard let tile = CanvasTexture.dithered(source, cells: cells) else { return nil }
        ditheredImage = (cells, tile)
        return tile
    }

    var textureImageName: String? {
        pendingTextureImage?.lastPathComponent ?? textureImagePath.map { ($0 as NSString).lastPathComponent }
    }

    /// An image counts as chosen at once, so the panel and preview show it; the copy waits for Save.
    func chooseTextureImage(_ url: URL) {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { NSSound.beep(); return }
        pendingTextureImage = url
        textureImagePath = "\(markdownAttachmentsFolder)/\(url.lastPathComponent)"
        textureImageSource = image
        ditheredImage = nil
        textureMode = .image
    }

    /// The colour and texture as they stand in the sheet, for the window behind it.
    var previewAppearance: ProjectAppearancePreview.Appearance {
        ProjectAppearancePreview.Appearance(color: color, texture: previewTexture)
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

    static let defaultPattern: ProjectTexture.Name = .checker
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
///
/// An image does whichever it was set to: recoloured, it's drawn as a template — its shape, in the
/// colour a symbol would take there — and otherwise in its own colours, like an emoji. Its path must be
/// absolute by the time it gets here; see `ProjectIcon.resolved(notesPath:)`.
struct ProjectIconMark: View {
    let icon: ProjectIcon
    var size: CGFloat = 13
    /// The project's colour, or the menu bar's stale-task yellow or red. A symbol and a recoloured image
    /// take it; an emoji and an image in its own colours don't.
    var tint: Color? = nil

    /// Whether this can be drawn at all. A symbol name typed into the file by hand, or one from a newer
    /// macOS, may not exist here; an image may have been moved or deleted — and then the caller draws the
    /// ring rather than a blank.
    nonisolated static func canDraw(_ icon: ProjectIcon) -> Bool {
        switch icon {
        case .emoji: return true
        case .symbol(let name): return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        case .image(let path, _): return ProjectIconImages.image(atPath: path) != nil
        }
    }

    /// Whether it's drawn in colours of its own, so the project's colour has to ride beside it.
    static func keepsOwnColors(_ icon: ProjectIcon) -> Bool {
        switch icon {
        case .emoji: return true
        case .symbol: return false
        case .image(_, let recolor): return !recolor
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
        case .image(let path, let recolor):
            if let image = ProjectIconImages.image(atPath: path) {
                // A shade larger than the point size, which is what a symbol at that size fills.
                let side = (size * 1.2).rounded()
                let picture = Image(nsImage: image).resizable().interpolation(.high)
                if recolor {
                    picture.renderingMode(.template).aspectRatio(contentMode: .fit)
                        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                        .frame(width: side, height: side)
                } else {
                    picture.renderingMode(.original).aspectRatio(contentMode: .fit).frame(width: side, height: side)
                }
            }
        }
    }
}

/// Image icons, loaded once per file version. Thread-safe, since `canDraw` is asked off the main actor.
enum ProjectIconImages {
    private static let cache = NSCache<NSString, NSImage>()

    /// The image at `path`, SVG or bitmap. Keyed on the modification date too, so editing the file in
    /// place shows on the next draw that asks.
    static func image(atPath path: String) -> NSImage? {
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        guard let date else { return nil }
        let key = "\(path)|\(date.timeIntervalSinceReferenceDate)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - The sheet

struct ProjectSettingsView: View {
    @Bindable var model: ProjectSettingsModel
    let onCancel: () -> Void
    let onSave: () -> Void
    var onAppearanceChange: (ProjectAppearancePreview.Appearance) -> Void = { _ in }
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
                row("Color") { ProjectColorPicker(color: $model.color) }
                Divider()
                row("Icon") {
                    Picker("Icon", selection: $model.mode) {
                        Text(model.kind.showsProgress ? "Progress" : "Dotted").tag(ProjectSettingsModel.Mode.progress)
                        Text("Symbol").tag(ProjectSettingsModel.Mode.symbol)
                        Text("Emoji").tag(ProjectSettingsModel.Mode.emoji)
                        Text("Image").tag(ProjectSettingsModel.Mode.image)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    ProjectIconImagePanel.acceptDrop(providers) { model.chooseIconImage($0) }
                }
                if model.mode == .symbol {
                    Divider()
                    symbolPicker.padding(12)
                } else if model.mode == .emoji {
                    Divider()
                    emojiPicker.padding(12)
                } else if model.mode == .image {
                    Divider()
                    ProjectIconImagePanel(model: model).padding(12)
                }
                Divider()
                row("Texture") {
                    Picker("Texture", selection: $model.textureMode) {
                        Text("None").tag(ProjectSettingsModel.TextureMode.none)
                        Text("Pattern").tag(ProjectSettingsModel.TextureMode.pattern)
                        Text("Image").tag(ProjectSettingsModel.TextureMode.image)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    ProjectTexturePanel.acceptDrop(providers) { model.chooseTextureImage($0) }
                }
                if model.textureMode != .none {
                    Divider()
                    ProjectTexturePanel(model: model).padding(12)
                }
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
        .frame(width: 488)
        .onChange(of: model.previewAppearance) { _, appearance in onAppearanceChange(appearance) }
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
        if let icon = model.drawableIcon, ProjectIconMark.canDraw(icon) {
            ProjectIconMark(icon: icon, size: 22, tint: model.color?.swiftUIColor)
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
            Text(label).frame(width: 52, alignment: .leading)
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
