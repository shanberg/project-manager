import AppKit
import SwiftUI
import PmLib

// MARK: - Catching up
//
// The other half of folding stale work out of the way (docs/stale-tasks.md). A fold makes coming back
// calm; this is how the pile gets smaller. It goes through a project's stale trees one at a time, the
// longest-forgotten first, each shown with the sitting it was written in and the sentence it was written
// beside, and asks one question of each: still meant?
//
// - **Keep** — yes, not now. Records a keep (`task.keep`), so it's fresh for another three weeks.
// - **Pick Up** — yes, now. The ordinary pick into the current sitting.
// - **Drop** — no. The ordinary drop, open subtasks with it.
// - **Skip** — not deciding. Nothing is written, and it stays stale.
//
// Each answer is the store's own verb, so each is one ⌘Z step in the project, as it would be from a row.
// Drop the Rest drops every tree not yet answered, as one step.

/// One review: the trees that were stale when it opened, in order, and what's been answered.
///
/// Held by identity rather than by position, because a Pick Up into a cold project starts a sitting and
/// shifts every index under it. A tree is named by its sitting's date and ordinal and its line among
/// that sitting's tasks, which none of the review's own writes move.
@MainActor
@Observable
final class StaleReviewModel {
    struct Item: Equatable {
        let session: String?
        let ordinal: Int
        let line: Int
        let text: String

        init(_ todo: Todo) {
            session = todo.sessionISODate
            ordinal = todo.sessionOrdinal
            line = todo.lineIndex
            text = todo.text
        }

        func matches(_ todo: Todo) -> Bool {
            todo.sessionISODate == session && todo.sessionOrdinal == ordinal && todo.lineIndex == line
        }
    }

    enum Answer { case kept, picked, next, done, dropped, skipped }

    let store: PMStore
    private(set) var items: [Item]
    private(set) var position = 0
    private(set) var answers: [Answer] = []

    init(store: PMStore) {
        self.store = store
        self.items = store.staleRoots.map(Item.init)
    }

    var isFinished: Bool { position >= items.count }
    var current: Item? { isFinished ? nil : items[position] }

    /// The tree's root as the store holds it now — what an answer acts on, so it carries the digest of
    /// the latest read. Nil once it's gone from the file (deleted in Obsidian mid-review).
    func live(_ item: Item) -> Todo? { store.todos.first(where: item.matches) }

    /// The open lines under the root, indented as in their sitting.
    func steps(of root: Todo, includingRoot: Bool = false) -> [Todo] {
        let members = TaskTree.members(of: root, in: store.todos)
        return (includingRoot ? members[...] : members.dropFirst()).filter { $0.state == .open }
    }

    func count(_ answer: Answer) -> Int { answers.filter { $0 == answer }.count }

    func answer(_ answer: Answer) {
        guard let item = current else { return }
        if let root = live(item) {
            switch answer {
            case .kept: store.keep([root])
            case .picked: store.pickUp([root])
            case .next: store.keepAsNext(root)
            // Done is the tree's open lines ticked, as ticking them on a card would: one ⌘Z step.
            case .done: store.toggleAll(steps(of: root, includingRoot: true))
            case .dropped: store.drop([root])
            case .skipped: break
            }
        }
        answers.append(answer)
        position += 1
    }

    /// Drop every tree not yet answered, as one step.
    func dropTheRest() {
        guard !isFinished else { return }
        let rest = items[position...].compactMap(live)
        store.drop(rest)
        answers += [Answer](repeating: .dropped, count: items.count - position)
        position = items.count
    }

    /// Back to the one before. Its answer stays written — ⌘Z in the project takes that back — but it's
    /// asked again, so a second answer can replace it.
    func back() {
        guard position > 0 else { return }
        position -= 1
        answers.removeLast()
    }
}

struct StaleReviewView: View {
    @State var model: StaleReviewModel
    /// Shown as one step of a project review (`ProjectReviewView`): no header of its own, and the review
    /// goes on when it's done rather than closing.
    var embedded = false
    var onClose: () -> Void
    @State private var confirmsDropTheRest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                header
                Divider()
            }
            Group {
                if let item = model.current {
                    question(item)
                } else {
                    finished
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: embedded ? 0 : 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Catch Up").font(FolioType.title)
                Text(model.store.projectName.map(projectTitle(fromFolderName:)) ?? "")
                    .font(FolioType.meta).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isFinished {
                Text("\(model.position + 1) of \(model.items.count)")
                    .font(FolioType.meta).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(16)
    }

    @ViewBuilder private func question(_ item: StaleReviewModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BriefLabel(origin(of: item))
            if let root = model.live(item) {
                // The tree in its session, among what was written around it, rather than the tree
                // alone: the sentence beside a task is usually what says whether it still matters.
                SessionContextView(store: model.store, todo: root,
                                   highlighting: Set(TaskTree.members(of: root, in: model.store.todos).map(\.lineIndex)))
            } else {
                Text("\u{201C}\(item.text)\u{201D} isn't in the notes any more.")
                    .font(FolioType.body).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(embedded ? "Still meant? Keep it for later, make it the next thing, mark it done, or let it go."
                          : "Still meant? Keep it for later, pick it up now, mark it done, or let it go.")
                .font(FolioType.meta).foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.items.isEmpty ? "Nothing has gone stale." : "All caught up.").font(FolioType.title)
            if !model.items.isEmpty { Text(summary).font(FolioType.body).foregroundStyle(.secondary) }
            Text("Each answer is a step you can undo with ⌘Z in the project.")
                .font(FolioType.meta).foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private var summary: String {
        let parts: [(StaleReviewModel.Answer, String)] = [(.kept, "kept"), (.picked, "picked up"), (.next, "made next"),
                                                          (.done, "done"), (.dropped, "dropped"), (.skipped, "skipped")]
        return parts.compactMap { answer, word in
            let n = model.count(answer)
            return n == 0 ? nil : "\(n) \(word)"
        }.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isFinished {
                Spacer()
                Button(embedded ? "Continue" : "Done", action: onClose).keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { model.back() }
                    .disabled(model.position == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Drop the Rest…") { confirmsDropTheRest = true }
                    .confirmationDialog("Drop the \(model.items.count - model.position) remaining tasks?",
                                        isPresented: $confirmsDropTheRest) {
                        Button("Drop \(model.items.count - model.position)", role: .destructive) { model.dropTheRest() }
                    } message: {
                        Text("They're closed without being done, with their open subtasks. ⌘Z in the project brings them back.")
                    }
                Spacer()
                Button("Skip") { model.answer(.skipped) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Drop") { model.answer(.dropped) }.keyboardShortcut("d", modifiers: [])
                Button("Done") { model.answer(.done) }.keyboardShortcut("x", modifiers: [])
                // In a review, the one to do next is focused and kept rather than picked up: the pick
                // belongs to the session it's worked in, not to the review's.
                if embedded {
                    Button("Next") { model.answer(.next) }.keyboardShortcut("n", modifiers: [])
                } else {
                    Button("Pick Up") { model.answer(.picked) }.keyboardShortcut("p", modifiers: [])
                }
                Button("Keep") { model.answer(.kept) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    /// "Written Sep 2 · picked up Sep 17", or "Written Sep 2 · kept Oct 4".
    private func origin(of item: StaleReviewModel.Item) -> String {
        var parts = ["Written \(SessionPicks.day(iso: item.session) ?? "in an undated session")"]
        if let root = model.live(item) {
            if let picked = root.picked, let day = SessionPicks.day(iso: picked.into) {
                parts.append("picked up \(day)")
            }
            if let kept = root.kept, let day = SessionPicks.day(iso: String(kept.prefix(10))) {
                parts.append("kept \(day)")
            }
        }
        return parts.joined(separator: " · ")
    }

}

/// The window a review is held in. One at a time: opening another project's review replaces it.
@MainActor
final class StaleReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = StaleReviewWindowController()

    private var window: NSWindow?
    /// The project whose store the open review holds, released when it closes.
    private var heldKey: String?

    private override init() { super.init() }

    /// Open a review of `store`'s stale work. The store is acquired for as long as the window is open,
    /// so the answers have somewhere to go however the window that offered it is closed.
    func show(for store: PMStore) {
        guard let key = store.projectKey else { return }
        close()
        let held = StoreRegistry.shared.acquire(key)
        heldKey = key
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Catch Up"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: StaleReviewView(model: StaleReviewModel(store: held)) { [weak self] in
            self?.close()
        })
        window.setFrameAutosaveName("PMStaleReviewWindow")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open a review of a project by its folder — from a surface that has no store for it, such as the
    /// Projects card. Its store is read first, so the review opens on what's stale now.
    func show(projectFolder folder: String) {
        guard let key = ProjectIndex.shared.projectKey(forFolder: folder) else { return NSSound.beep() }
        let store = StoreRegistry.shared.acquire(key)
        store.reload { [weak self] in
            self?.show(for: store)
            StoreRegistry.shared.release(key)
        }
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.close()
        StoreRegistry.shared.release(heldKey)
        heldKey = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        StoreRegistry.shared.release(heldKey)
        heldKey = nil
    }
}

/// A task where it was written: its session's heading and body, prose and tasks in written order, with
/// the lines of its tree picked out and scrolled to. What a review shows so a task can be judged by the
/// sentence beside it and the tree it's part of, not by its text alone.
struct SessionContextView: View {
    let store: PMStore
    let todo: Todo
    /// The session's task lines to pick out, by `Todo.lineIndex`.
    let highlighting: Set<Int>
    /// Whether to say what the task sits under. Off where the row already says.
    var showsPath = true
    var maxHeight: CGFloat = 260

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let indent: Int
        /// The task's box, or nil for prose.
        let box: TaskState?
        let picked: Bool
        let isHeading: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsPath, let path = store.breadcrumb(for: todo) {
                Text("Under " + path).font(FolioType.meta).foregroundStyle(.secondary).lineLimit(2)
            }
            if let heading {
                Text(heading).font(FolioType.label).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(lines) { line in row(line).id(line.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(maxHeight: maxHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                .onAppear {
                    if let first = lines.first(where: \.picked) { proxy.scrollTo(first.id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ line: Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let box = line.box {
                Image(systemName: box == .done ? "checkmark.square" : box == .dropped ? "minus.square" : "square")
                    .font(FolioType.meta)
            }
            Text(line.text)
                .font(line.box == nil ? (line.isHeading ? FolioType.bodyEmphasis : FolioType.reading)
                                      : (line.picked ? FolioType.bodyEmphasis : FolioType.body))
                .strikethrough(line.box == .dropped)
                .textSelection(.enabled)
        }
        .foregroundStyle(line.picked ? Color.primary : Color.secondary)
        .padding(.leading, CGFloat(line.indent) * 14)
    }

    private var session: Session? {
        guard let sessions = store.notes?.sessions, sessions.indices.contains(todo.sessionIndex) else { return nil }
        return sessions[todo.sessionIndex]
    }

    private var heading: String? {
        guard let session else { return nil }
        let day = SessionPicks.day(iso: sessionISODate(heading: session.date)) ?? session.date
        return session.name.isEmpty ? day : "\(day) · \(session.name)"
    }

    private static let taskLine = try! NSRegularExpression(pattern: #"^(\s*)-\s+\[([ xX-])\]\s+(.*)$"#)

    private var lines: [Line] {
        guard let body = session?.body else { return [] }
        var out: [Line] = []
        var taskIndex = 0
        for (i, raw) in body.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let ns = raw as NSString
            if let m = Self.taskLine.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
               let box = TaskState(box: Character(ns.substring(with: m.range(at: 2)))) {
                var text = ns.substring(with: m.range(at: 3))
                if text.hasSuffix(" @") { text = String(text.dropLast(2)) }
                out.append(Line(id: i, text: text, indent: ns.substring(with: m.range(at: 1)).count / 2, box: box,
                                picked: highlighting.contains(taskIndex), isHeading: false))
                taskIndex += 1
            } else {
                let isHeading = trimmed.hasPrefix("#")
                let text = isHeading ? trimmed.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) : trimmed
                out.append(Line(id: i, text: text, indent: 0, box: nil, picked: false, isHeading: isHeading))
            }
        }
        return out
    }
}
