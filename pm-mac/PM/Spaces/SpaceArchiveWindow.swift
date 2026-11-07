import AppKit
import PmLib
import SwiftUI

/// Restoring an archived card, and the Archived Cards window. docs/spaces.md § Archived cards.
extension SpaceArchive {
    /// The card back on its space's board — unpinned, at the top of Today — and the entry gone. One
    /// undo step on that board. Shown when the space's window is open.
    func restore(entryID: String) {
        guard let entry = entries.first(where: { $0.id == entryID }), let card = entry.card,
              let canvas = Spaces.shared.canvas(of: entry.spaceID) else { return NSSound.beep() }
        if !FileManager.default.fileExists(atPath: canvas.path) { try? Spaces.shared.makeCanvas(at: canvas) }
        let spaceID = entry.spaceID
        // The board read off main when it isn't open, as `Spaces.move`.
        CanvasStoreRegistry.withStores([canvas]) { [weak self] stores in
            guard let self, let store = stores.first else { return NSSound.beep() }
            var id = card.id
            store.change("Restore Card") { id = Self.place(card, into: &$0) }
            store.save()
            remove([entryID])
            guard let window = Spaces.shared.window(of: spaceID), window.isVisible,
                  let frame = window.spaceFrame else { return }
            frame.refresh()
            frame.show(id)
            window.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The Archived Cards window for a space: one per space, brought forward.
    static func present(spaceID: String) {
        SpaceArchiveWindows.shared.show(spaceID)
    }
}

@MainActor
private final class SpaceArchiveWindows: NSObject, NSWindowDelegate {
    static let shared = SpaceArchiveWindows()
    private var windows: [String: NSWindow] = [:]

    func show(_ spaceID: String) {
        guard let space = Spaces.shared.space(spaceID) else { return NSSound.beep() }
        if let window = windows[spaceID] {
            window.title = "Archived Cards \u{2014} \(space.title)"
            return window.makeKeyAndOrderFront(nil)
        }
        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        made.title = "Archived Cards \u{2014} \(space.title)"
        made.isReleasedWhenClosed = false
        made.contentMinSize = NSSize(width: 380, height: 300)
        made.contentView = NSHostingView(rootView: SpaceArchiveView(spaceID: spaceID))
        made.setFrameAutosaveName("PMSpaceArchiveWindow")
        made.delegate = self
        if made.frame.origin == .zero { made.center() }
        // Another space's archive already open: this one beside it, not on top.
        if let other = windows.values.first {
            _ = made.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY))
        }
        windows[spaceID] = made
        NSApp.activate(ignoringOtherApps: true)
        made.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

private struct SpaceArchiveView: View {
    let spaceID: String
    @State private var entries: [SpaceArchive.Entry] = []
    @State private var query = ""
    @State private var selection: Set<String> = []

    private var shown: [SpaceArchive.Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.lowercased().contains(needle) || ($0.address ?? "").lowercased().contains(needle)
        }
    }

    private var days: [(day: Date, entries: [SpaceArchive.Entry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [SpaceArchive.Entry]] = [:]
        for entry in shown {
            let day = calendar.startOfDay(for: entry.archivedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search Archived Cards", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Restore") { restore(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
                Button("Clear Archive\u{2026}", action: clear)
                    .disabled(entries.isEmpty)
            }
            .padding(10)
            Divider()
            if shown.isEmpty {
                Text(entries.isEmpty ? "No archived cards" : "No archived cards match")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(days, id: \.day) { day in
                        Section(Self.dayTitle(day.day)) {
                            ForEach(day.entries) { entry in
                                row(entry).tag(entry.id)
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Restore") { restore(ids) }
                    Button("Copy Address") { copy(ids) }
                        .disabled(addresses(ids).isEmpty)
                    Divider()
                    Button("Remove from Archive") { SpaceArchive.shared.remove(ids) }
                } primaryAction: { ids in
                    restore(ids)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: SpaceArchive.changed)) { _ in reload() }
    }

    private func reload() {
        entries = SpaceArchive.shared.entries(in: spaceID)
        selection = selection.filter { id in entries.contains { $0.id == id } }
    }

    private func row(_ entry: SpaceArchive.Entry) -> some View {
        HStack(spacing: 8) {
            icon(entry).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(entry.archivedAt, style: .time).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func icon(_ entry: SpaceArchive.Entry) -> some View {
        if let host = entry.host, let favicon = FaviconLoader.shared.cached(for: host) {
            Image(nsImage: favicon).resizable()
        } else {
            Image(systemName: entry.symbol ?? (entry.host == nil ? "doc" : "globe")).foregroundStyle(.secondary)
        }
    }

    private func detail(_ entry: SpaceArchive.Entry) -> String {
        let place = entry.address.map(CanvasAddressSuggestions.bare) ?? entry.host
        return [entry.reason.label, place].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private func restore(_ ids: Set<String>) {
        // In the list's order, so the first restored ends up on top, as it was.
        for entry in entries.reversed() where ids.contains(entry.id) {
            SpaceArchive.shared.restore(entryID: entry.id)
        }
    }

    private func addresses(_ ids: Set<String>) -> [String] {
        entries.filter { ids.contains($0.id) }.compactMap(\.address)
    }

    private func copy(_ ids: Set<String>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addresses(ids).joined(separator: "\n"), forType: .string)
    }

    private func clear() {
        let alert = NSAlert()
        let title = Spaces.shared.space(spaceID)?.title ?? "this space"
        alert.messageText = "Clear Archived Cards?"
        alert.informativeText = "Every archived card of \u{201C}\(title)\u{201D} is removed for good. Cards on the board stay."
        alert.addButton(withTitle: "Clear Archive")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SpaceArchive.shared.clear(spaceID: spaceID)
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
