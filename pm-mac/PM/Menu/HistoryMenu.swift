import AppKit
import SwiftUI

/// The History menu: Reopen Closed Card (⇧⌘T), Show All History (⌘Y), Archived Cards…, the last pages
/// visited, Clear History…. docs/spaces.md § Browsing.
@MainActor
final class HistoryMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = HistoryMenu()
    private static let recentCount = 15
    /// Items from here down are rebuilt each time the menu opens.
    private static let recentTag = 0x4849

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "History")
        menu.delegate = self
        let reopen = menu.addItem(withTitle: "Reopen Closed Card", action: #selector(reopenClosed(_:)), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        reopen.target = self
        menu.addItem(withTitle: "Show All History", action: #selector(showAll(_:)), keyEquivalent: "y").target = self
        menu.addItem(withTitle: "Archived Cards\u{2026}", action: #selector(showArchive(_:)), keyEquivalent: "").target = self
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        while let last = menu.items.last, last.tag == Self.recentTag { menu.removeItem(last) }
        func add(_ item: NSMenuItem) { item.tag = Self.recentTag; menu.addItem(item) }
        add(.separator())
        let visits = CanvasHistory.visits.prefix(Self.recentCount)
        if visits.isEmpty {
            let none = NSMenuItem(title: "No Pages Visited", action: nil, keyEquivalent: "")
            none.isEnabled = false
            add(none)
        }
        for visit in visits {
            let host = URL(string: visit.address)?.host() ?? visit.address
            let item = NSMenuItem(title: visit.title.isEmpty ? host : visit.title, action: #selector(open(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = visit.address
            item.toolTip = visit.address
            if let icon = FaviconLoader.shared.cached(for: host) {
                let image = icon.copy() as? NSImage
                image?.size = NSSize(width: 16, height: 16)
                item.image = image
                MenuPictures.forceImageVisible(item)
            }
            add(item)
        }
        add(.separator())
        let clear = NSMenuItem(title: "Clear History\u{2026}", action: #selector(clear(_:)), keyEquivalent: "")
        clear.target = self
        add(clear)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(reopenClosed(_:)): return !CanvasHistory.closed.isEmpty
        case #selector(clear(_:)): return !CanvasHistory.visits.isEmpty
        case #selector(showArchive(_:)): return Spaces.shared.frontSpace != nil
        default: return true
        }
    }

    @objc func reopenClosed(_ sender: Any?) {
        guard let closed = CanvasHistory.takeLastClosed() else { return NSSound.beep() }
        if closed.spaceID != nil { return Spaces.shared.reopen(closed) }
        guard ProjectWindowController.reopen(closed) else { return NSSound.beep() }
    }

    @objc func showAll(_ sender: Any?) { HistoryWindow.shared.show() }

    /// The front space window's Archived Cards (`SpaceArchive`).
    @objc func showArchive(_ sender: Any?) {
        guard let space = Spaces.shared.frontSpace else { return NSSound.beep() }
        SpaceArchive.present(spaceID: space)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String, let url = URL(string: address) else { return }
        CanvasIncomingLinks.open(url)
    }

    @objc func clear(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear History?"
        alert.informativeText = "Pages are removed from History and from the address field's suggestions. Cards and sign-ins stay."
        alert.addButton(withTitle: "Clear All History")
        alert.addButton(withTitle: "Clear Today")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: CanvasHistory.clear()
        case .alertSecondButtonReturn: CanvasHistory.clear(since: Calendar.current.startOfDay(for: Date()))
        default: break
        }
    }
}

// MARK: - The window

/// Show All History (⌘Y): every page visited, newest first, by day, with a search field.
@MainActor
final class HistoryWindow: NSObject, NSWindowDelegate {
    static let shared = HistoryWindow()
    private var window: NSWindow?

    func show() {
        if let window { return window.makeKeyAndOrderFront(nil) }
        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        made.title = "History"
        made.isReleasedWhenClosed = false
        made.contentMinSize = NSSize(width: 380, height: 300)
        made.contentView = NSHostingView(rootView: HistoryView())
        made.setFrameAutosaveName("PMHistoryWindow")
        made.delegate = self
        if made.frame.origin == .zero { made.center() }
        window = made
        made.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

private struct HistoryView: View {
    @State private var visits = CanvasHistory.visits
    @State private var query = ""
    @State private var selection: String?

    private var shown: [CanvasHistory.Visit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return visits }
        return visits.filter { $0.title.lowercased().contains(needle) || $0.address.lowercased().contains(needle) }
    }

    private var days: [(day: Date, visits: [CanvasHistory.Visit])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [CanvasHistory.Visit]] = [:]
        for visit in shown.prefix(3_000) {
            let day = calendar.startOfDay(for: visit.last)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(visit)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search History", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Clear History\u{2026}") { HistoryMenu.shared.clear(nil) }
                    .disabled(visits.isEmpty)
            }
            .padding(10)
            Divider()
            if shown.isEmpty {
                Text(visits.isEmpty ? "No pages visited" : "No pages match")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(days, id: \.day) { day in
                        Section(Self.dayTitle(day.day)) {
                            ForEach(day.visits) { visit in
                                row(visit).tag(visit.address)
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: String.self) { addresses in
                    Button("Open") { addresses.forEach(open) }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(addresses.joined(separator: "\n"), forType: .string)
                    }
                    Divider()
                    Button("Remove from History") { addresses.forEach(CanvasHistory.remove) }
                } primaryAction: { addresses in
                    addresses.forEach(open)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: CanvasHistory.changed)) { _ in
            visits = CanvasHistory.visits
        }
    }

    private func row(_ visit: CanvasHistory.Visit) -> some View {
        let host = URL(string: visit.address)?.host() ?? visit.address
        return HStack(spacing: 8) {
            if let icon = FaviconLoader.shared.cached(for: host) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "globe").frame(width: 16, height: 16).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.title.isEmpty ? host : visit.title).lineLimit(1)
                Text(CanvasAddressSuggestions.bare(visit.address)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(visit.last, style: .time).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        CanvasIncomingLinks.open(url)
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
