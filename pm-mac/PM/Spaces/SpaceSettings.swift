import AppKit
import PmLib
import SwiftUI

/// A space's settings: name, icon, colour, when Today's cards archive, and Delete. docs/spaces.md § Spaces.
///
/// - Project Settings' counterpart, with its rows, colour swatches and icon pickers (`IconPickers`).
/// - Live rather than Save: a space is one entry in `spaces.json`, with no folder to rename, so each
///   change goes through `Spaces.change` as it's made and open windows follow (title, sidebar foot, wash).
/// - A window of its own, one per space, brought forward when it's already open.
@MainActor
enum SpaceSettings {
    private static var windows: [String: NSWindow] = [:]
    private static var observers: [String: [NSObjectProtocol]] = [:]

    /// The space's sidebar foot menu and its dock mark's menu.
    static func present(spaceID: String) {
        guard Spaces.shared.space(spaceID) != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let window = windows[spaceID] {
            (window.contentViewController as? NSHostingController<SpaceSettingsView>)?.rootView.model.reload()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SpaceSettingsModel(spaceID: spaceID)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = "Space Settings"
        let host = NSHostingController(rootView: SpaceSettingsView(model: model, onDone: { [weak window] in window?.close() }))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        windows[spaceID] = window
        let center = NotificationCenter.default
        observers[spaceID] = [
            // Rename… or Colour on the dock mark while this was behind: show what's there now.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { model.reload() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    observers.removeValue(forKey: spaceID)?.forEach(center.removeObserver)
                    windows[spaceID] = nil
                    // The name, written as typed, saved now rather than on the next change.
                    Spaces.shared.flush()
                }
            },
        ]
        window.makeKeyAndOrderFront(nil)
    }

    /// The space is gone (`Spaces.delete`): its settings window with it.
    /// After the current event: Delete Space… is a button in this window, whose view shouldn't go from
    /// under its own action.
    static func close(spaceID: String) {
        DispatchQueue.main.async { windows[spaceID]?.close() }
    }
}

// MARK: - Model

@MainActor
@Observable
final class SpaceSettingsModel {
    enum Mode: Hashable { case symbol, emoji }

    let spaceID: String
    /// As typed; written trimmed, so empty or blank is Untitled Space.
    var name: String { didSet { write { $0.name = self.trimmedName } } }
    var mode: Mode { didSet { writeIcon() } }
    var symbol: String { didSet { writeIcon() } }
    var emoji: String {
        didSet {
            writeIcon()
            if !reading { EmojiCatalog.noteUsed(emoji) }
        }
    }
    /// Never nil once read: the picker offers no None for a space.
    var color: ProjectColor? {
        didSet { if let color { write { $0.color = color.value } } }
    }
    /// `SpaceFrame.archiveChoices`' seconds; -1 is Never, which a picker tag can't spell as nil.
    var archiveTag: Double { didSet { writeArchive() } }

    var symbolQuery = ""
    var symbolCategory: String?
    private(set) var symbolCatalog: SymbolCatalog?
    var emojiQuery = ""
    let recentEmoji = EmojiCatalog.recents

    /// While `reload` sets the fields from the file: nothing to write back.
    @ObservationIgnored private var reading = false

    init(spaceID: String) {
        self.spaceID = spaceID
        let space = Spaces.shared.space(spaceID)
        name = space?.name ?? ""
        color = space.flatMap { ProjectColor(value: $0.color) }
        archiveTag = space?.archiveAfter ?? -1
        switch space.flatMap({ ProjectIcon(value: $0.icon) }) {
        case .emoji(let e): mode = .emoji; symbol = Self.defaultSymbol; emoji = e
        case .symbol(let s): mode = .symbol; symbol = s; emoji = Self.defaultEmoji
        default: mode = .symbol; symbol = Self.defaultSymbol; emoji = Self.defaultEmoji
        }
        // As Project Settings: the catalog is three system plists, read off main.
        Task.detached(priority: .userInitiated) { [weak self] in
            let catalog = SymbolCatalog.shared
            await MainActor.run { self?.symbolCatalog = catalog }
        }
    }

    var space: Space? { Spaces.shared.space(spaceID) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var icon: ProjectIcon { mode == .symbol ? .symbol(symbol) : .emoji(emoji) }

    /// What the file says now, where it differs from what's shown — a name differing only in the
    /// spaces still being typed round it is left alone.
    func reload() {
        guard let space else { return }
        reading = true
        defer { reading = false }
        if trimmedName != space.name { name = space.name }
        if let read = ProjectColor(value: space.color), read != color { color = read }
        if (space.archiveAfter ?? -1) != archiveTag { archiveTag = space.archiveAfter ?? -1 }
        switch ProjectIcon(value: space.icon) {
        case .emoji(let e) where icon != .emoji(e): mode = .emoji; emoji = e
        case .symbol(let s) where icon != .symbol(s): mode = .symbol; symbol = s
        default: break
        }
    }

    private func write(_ edit: (inout Space) -> Void) {
        guard !reading else { return }
        Spaces.shared.change(spaceID, edit)
    }

    private func writeIcon() {
        let value = icon.value
        write { $0.icon = value }
    }

    /// Through the space's frame when its window is open, which also archives at once anything now due.
    private func writeArchive() {
        guard !reading else { return }
        let seconds = archiveTag < 0 ? nil : archiveTag
        if let frame = Spaces.shared.window(of: spaceID)?.spaceFrame {
            frame.setArchiveAfter(seconds)
        } else {
            Spaces.shared.change(spaceID) { $0.archiveAfter = seconds }
        }
    }

    func delete() {
        Spaces.shared.delete(spaceID)
    }

    static let defaultSymbol = "globe"
    static let defaultEmoji = "🌿"
}

// MARK: - The window

struct SpaceSettingsView: View {
    @Bindable var model: SpaceSettingsModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(spacing: 0) {
                row("Name") {
                    TextField("", text: $model.name, prompt: Text("Untitled Space"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                Divider()
                row("Color") { ProjectColorPicker(color: $model.color, allowsNone: false) }
                Divider()
                row("Icon") {
                    Picker("Icon", selection: $model.mode) {
                        Text("Symbol").tag(SpaceSettingsModel.Mode.symbol)
                        Text("Emoji").tag(SpaceSettingsModel.Mode.emoji)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                if model.mode == .symbol {
                    SymbolIconPicker(symbol: $model.symbol, query: $model.symbolQuery,
                                     category: $model.symbolCategory, catalog: model.symbolCatalog)
                        .padding(12)
                } else {
                    EmojiIconPicker(emoji: $model.emoji, query: $model.emojiQuery, recents: model.recentEmoji)
                        .padding(12)
                }
                Divider()
                row("Archive") {
                    Picker("Archive Today\u{2019}s Cards", selection: $model.archiveTag) {
                        ForEach(SpaceFrame.archiveChoices, id: \.title) { choice in
                            Text(choice.title).tag(choice.seconds ?? -1)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    Text("Today\u{2019}s cards not on screen")
                        .foregroundStyle(.secondary)
                }
                .help("Archive Today\u{2019}s cards not on screen for this long")
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Button("Delete Space\u{2026}", action: model.delete)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 488)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProjectIconMark(icon: model.icon, size: 22, tint: model.color?.swiftUIColor)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Space Settings").font(.system(size: 13, weight: .semibold))
                Text(model.trimmedName.isEmpty ? "Untitled Space" : model.trimmedName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 52, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
