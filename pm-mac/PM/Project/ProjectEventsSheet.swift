import AppKit
import PmLib
import SwiftUI

/// Show Events From…: which calendars a project or area takes its events from, and which of their
/// events (views.md, Calendars C2). Writes `pm-events` on Save, like Project Settings.
@MainActor
enum ProjectEventsSheet {
    static func present(projectNamed name: String) {
        let model = ProjectEventsModel(projectNamed: name)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = PMCommand.showEvents.title
        let parent = sheetParent()

        func finish(saving: Bool) {
            if let parent { parent.endSheet(window) } else { NSApp.stopModal(); window.orderOut(nil) }
            DispatchQueue.main.async {
                window.contentViewController = nil
                if saving { save(model, projectNamed: name) }
            }
        }

        let host = NSHostingController(rootView: ProjectEventsView(
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

    /// As in `ProjectSettings`: the frontmost project window, or none, and then a window of its own.
    private static func sheetParent() -> NSWindow? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible,
              !(window is NSPanel), window.attachedSheet == nil else { return nil }
        return window
    }

    private static func save(_ model: ProjectEventsModel, projectNamed name: String) {
        let sources = model.sources
        guard sources != model.original else { return }
        do {
            try setProjectEventSources(project: name, to: sources)
            Log.write("project events: \(name) -> \(sources.map(\.calendar))")
        } catch {
            ProjectLifecycle.present(error, doing: "Couldn't save “\(name)”")
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class ProjectEventsModel {
    typealias Row = ProjectEventChoice

    struct Group: Identifiable {
        var id: String { title }
        let title: String
        let rows: [Int]
    }

    let kind: ProjectKind
    let folderName: String
    let original: [ProjectEventSource]
    private(set) var access: CalendarEvents.Access
    var rows: [Row] = []
    /// Each calendar's own colour, by row id. Not a row's business, which is what gets saved.
    private(set) var colors: [String: NSColor] = [:]

    convenience init(projectNamed name: String) {
        let handle = try? resolveNotesHandle(project: name)
        let raw = handle.flatMap { try? $0.io.readContent(path: $0.notesPath) }
        self.init(folderName: name, sources: raw.map(projectEventSources(rawText:)) ?? [],
                  access: CalendarEvents.shared.access, calendars: CalendarEvents.shared.calendars())
    }

    /// With everything in hand, so a harness can draw the sheet without a vault or EventKit.
    init(folderName: String, sources: [ProjectEventSource], access: CalendarEvents.Access,
         calendars: [CalendarEvents.Calendar]) {
        kind = ProjectKind.of(folderName: folderName)
        self.folderName = folderName
        original = sources
        self.access = access
        load(sources: sources, calendars: calendars)
    }

    private func load(sources: [ProjectEventSource], calendars: [CalendarEvents.Calendar]) {
        rows = projectEventChoices(calendars: calendars.map { ($0.title, $0.account) }, sources: sources)
        colors = Dictionary(zip(rows.prefix(calendars.count).map(\.id), calendars.map(\.color)),
                            uniquingKeysWith: { a, _ in a })
    }

    func requestAccess() {
        Task {
            _ = await CalendarEvents.shared.requestAccess()
            access = CalendarEvents.shared.access
            // From what the rows say now, so anything edited before access came is kept.
            load(sources: sources, calendars: CalendarEvents.shared.calendars())
        }
    }

    /// By account, then the saved calendars this Mac doesn't have.
    var groups: [Group] {
        var byAccount: [String: [Int]] = [:]
        var accounts: [String] = []
        var missing: [Int] = []
        for (index, row) in rows.enumerated() {
            if access == .granted, !row.isOnThisMac { missing.append(index); continue }
            let account = row.account ?? "Any Account"
            if byAccount[account] == nil { accounts.append(account) }
            byAccount[account, default: []].append(index)
        }
        var groups = accounts.map { Group(title: $0, rows: byAccount[$0]!) }
        if !missing.isEmpty { groups.append(Group(title: "Not on This Mac", rows: missing)) }
        return groups
    }

    /// What Save writes: the checked rows, in the file's order, blank queries dropped.
    var sources: [ProjectEventSource] { projectEventSources(from: rows) }

    var hasChanges: Bool { sources != original }

    /// The events a row would show over the next 30 days, for a preview under it.
    func upcoming(_ row: Row) -> [CalendarEvents.Event] {
        guard row.isOn, row.isOnThisMac, let account = row.account else { return [] }
        let source = ProjectEventSource(calendar: row.title, account: account, match: row.queries)
        let now = Date()
        return CalendarEvents.shared.events(in: DateInterval(start: now, duration: 30 * 86_400), for: [source])
    }
}

// MARK: - The sheet

struct ProjectEventsView: View {
    @Bindable var model: ProjectEventsModel
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PMCommand.showEvents.title.replacingOccurrences(of: "…", with: ""))
                    .font(.system(size: 13, weight: .semibold))
                Text(model.folderName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Without access, nothing below can be chosen or checked, so the ask takes the list's place.
            if model.access != .granted {
                accessPlaceholder.modifier(ListWell())
            } else if model.rows.isEmpty {
                ContentUnavailableView("No Calendars on This Mac", systemImage: "calendar")
                    .modifier(ListWell())
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(group.rows, id: \.self) { index in
                                    CalendarRow(model: model, row: $model.rows[index])
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(ListWell())
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var accessPlaceholder: some View {
        ContentUnavailableView {
            Label(model.access == .notAsked ? "Calendar Access Needed" : "Calendar Access Is Off",
                  systemImage: model.access == .notAsked ? "calendar" : "calendar.badge.exclamationmark")
        } description: {
            Text("Read only")
        } actions: {
            if model.access == .notAsked {
                Button("Allow Access…") { model.requestAccess() }
            } else {
                Button("Open Privacy Settings") { CalendarEvents.openPrivacySettings() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

/// The rounded, bordered ground the calendar list sits in — and whatever stands in for it.
private struct ListWell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct CalendarRow: View {
    let model: ProjectEventsModel
    @Binding var row: ProjectEventsModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $row.isOn) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.colors[row.id].map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(row.title)
                }
            }
            .toggleStyle(.checkbox)

            if row.isOn {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.queries.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            TextField("Title contains", text: $row.queries[index])
                                .textFieldStyle(.roundedBorder)
                            Button { row.queries.remove(at: index) } label: { Image(systemName: "minus") }
                                .buttonStyle(.borderless)
                                .help("Remove")
                        }
                    }
                    HStack(spacing: 8) {
                        Button { row.queries.append("") } label: { Label("Title Contains", systemImage: "plus") }
                            .buttonStyle(.borderless)
                        Spacer()
                        Text(summary).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                .padding(.leading, 20)
            }
        }
    }

    /// What the row would show, so a query can be checked against the calendar before saving.
    private var summary: String {
        let hasQuery = row.queries.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard row.isOnThisMac, model.access == .granted else { return hasQuery ? "" : "All events" }
        let upcoming = model.upcoming(row)
        guard let next = upcoming.first else { return hasQuery ? "None in the next 30 days" : "All events · none soon" }
        let when = next.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()
            .hour(next.isAllDay ? .omitted : .defaultDigits(amPM: .abbreviated))
            .minute(next.isAllDay ? .omitted : .twoDigits))
        let count = upcoming.count == 1 ? "1 in 30 days" : "\(upcoming.count) in 30 days"
        return "\(hasQuery ? count : "All events · \(count)") · next \(when)"
    }
}
