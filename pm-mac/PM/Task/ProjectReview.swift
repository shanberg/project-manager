import AppKit
import SwiftUI
import PmLib

// MARK: - Reviewing a project
//
// A sitting you sit down to on purpose, to gather your thoughts about a project and clean it up
// (docs/project-review.md). It walks a few short steps, skipping any with nothing in them:
//
// 1. **Since last time** — the sittings since the last review and what got done. Read only.
// 2. **The brief** — Summary, Problem, Goals, Approach, editable in place.
// 3. **Catch Up** — the stale trees, one at a time: the catch-up review itself, embedded.
// 4. **Dates and waits** — overdue tasks, waits on something since archived, a focus gone quiet.
// 5. **Your thoughts** — what you think now, a learning, the next task.
// 6. **Wrap up** — keep going, or archive (put down, for an area).
//
// **The review is a sitting.** Opening one starts a sitting named "Review" (`reviewSessionName`), so the
// old tasks it picks up are drawn under it and its time is counted. Your thoughts become its note, with a
// line saying what the review did, which is also what makes it count as the last review. A review closed
// without anything done takes its empty heading away again.
//
// Every answer is the store's own verb, one ⌘Z step in the project, as it would be from a row.

extension PMStore {
    /// What a review would find here now: the reasons this project is creaky (`ProjectHealth`).
    var health: ProjectHealth {
        guard let notes else { return ProjectHealth() }
        let targets = waitTargets
        return ProjectHealth(notes: notes, todos: todos, kind: kind,
                             isReleased: { targets[$0]?.isReleased ?? false })
    }
}

private extension Todo {
    /// A row's identity in a review's lists: its place, as every surface names a line.
    var reviewID: String { TaskStaleness.key(self) }
}

@MainActor
@Observable
final class ProjectReviewModel {
    enum Step: Equatable {
        case recap, brief, catchUp, datesAndWaits, thoughts, wrapUp

        var title: String {
            switch self {
            case .recap: "Since Last Time"
            case .brief: "The Brief"
            case .catchUp: "Older Tasks"
            case .datesAndWaits: "Dates and Waits"
            case .thoughts: "Your Thoughts"
            case .wrapUp: "Wrap Up"
            }
        }
    }

    /// One sitting since the last review, as the recap lists it.
    struct Recap: Identifiable {
        let id: Int
        let day: String
        let lede: String
    }

    let store: PMStore
    let steps: [Step]
    private(set) var position = 0

    // Since last time, read once, before the review's own sitting is started.
    let lastReviewed: String?
    let recap: [Recap]
    let doneSince: Int
    let droppedSince: Int

    // The brief, as edited. Written when the step is left, and only if it changed.
    var summary: String
    var problem: String
    var goals: [String]
    var approach: String
    private var savedBrief: [String]
    private(set) var briefUpdated = false

    /// The catch-up review, made when its step is reached: by then the review's sitting has been started,
    /// so the trees it names are read against the document the answers will be written into.
    private(set) var catchUp: StaleReviewModel?

    // Dates and waits: what's been answered here, for the wrap-up line.
    private(set) var redated = 0
    private(set) var waitsCleared = 0
    private(set) var dropped = 0
    private(set) var focusKept = false

    // Your thoughts.
    var thoughts = ""
    var learning = ""
    var nextTask = ""

    /// The review's own sitting, once started.
    private(set) var sitting: SessionRef?
    private(set) var isWrappedUp = false

    init(store: PMStore) {
        self.store = store
        let notes = store.notes ?? ProjectNotes(title: "")
        let health = store.health
        let kind = store.kind

        let previous = ProjectReview.lastReviewIndex(in: notes)
        lastReviewed = previous.flatMap { sessionISODate(heading: notes.sessions[$0].date) }
            .flatMap { SessionPicks.day(iso: $0) }
        recap = ProjectReview.sittingsSince(notes).map { i in
            let s = notes.sessions[i]
            let prose = s.body.components(separatedBy: "\n")
                .filter { $0.range(of: #"^\s*[-*+]\s+\[[ xX-]\]\s"#, options: .regularExpression) == nil }
                .joined(separator: "\n")
            let day = SessionPicks.day(iso: sessionISODate(heading: s.date)) ?? s.date
            return Recap(id: i, day: day, lede: sittingLede(name: s.name, prose: prose))
        }
        let since = previous.flatMap { ProjectReview.day(of: notes.sessions[$0]) }
            ?? Calendar.current.startOfDay(for: Date().addingTimeInterval(-taskStaleAfter))
        let events = store.projectPath.map { DoneLog.events(projectPath: $0) } ?? []
        let recent = events.filter { DoneLog.date($0.at).map { $0 >= since } ?? false }
        doneSince = recent.filter { $0.event == .completed }.count
        droppedSince = recent.filter { $0.event == .dropped }.count

        summary = notes.summary
        problem = notes.problem
        goals = Array((notes.goals + ["", "", ""]).prefix(3))
        approach = notes.approach
        savedBrief = [notes.summary, notes.problem, notes.approach] + Array((notes.goals + ["", "", ""]).prefix(3))
        isArea = kind == .area

        var steps: [Step] = [.recap, .brief]
        if health.staleTrees > 0 { steps.append(.catchUp) }
        if health.overdue > 0 || health.releasedWaits > 0 || health.focusGoneQuiet { steps.append(.datesAndWaits) }
        steps += [.thoughts, .wrapUp]
        self.steps = steps
    }

    let isArea: Bool

    var step: Step { steps[position] }
    var isLast: Bool { position == steps.count - 1 }

    /// Start the review's sitting. Called once, when the window opens.
    func start() {
        store.openSession(named: reviewSessionName) { [weak self] index in
            guard let self, let index else { return }
            sitting = store.sessionRef(at: index)
        }
    }

    func next() {
        leave(step)
        guard position < steps.count - 1 else { return }
        position += 1
        enter(step)
    }

    func back() {
        leave(step)
        guard position > 0 else { return }
        position -= 1
    }

    private func enter(_ step: Step) {
        if step == .catchUp, catchUp == nil { catchUp = StaleReviewModel(store: store) }
    }

    private func leave(_ step: Step) {
        if step == .brief { saveBrief() }
    }

    // MARK: The brief

    private var brief: [String] { [summary, problem, approach] + goals }

    private func saveBrief() {
        let now = brief
        guard now != savedBrief else { return }
        savedBrief = now
        briefUpdated = true
        let (summary, problem, goals, approach) = (summary, problem, goals, approach)
        store.saveDetails { notes in
            var notes = notes
            notes.summary = summary
            notes.problem = problem
            notes.approach = approach
            notes.goals = goals
            return notes
        }
    }

    // MARK: Dates and waits

    var overdue: [Todo] {
        store.todos.filter { todo in
            todo.state == .open && todo.dueDate.map { RelativeDue.isOverdue($0) } == true
        }
    }

    var releasedWaits: [Todo] {
        store.todos.filter { $0.state == .open && $0.waiting.map { store.waitTargets[$0]?.isReleased ?? false } == true }
    }

    /// The focused task, while it's gone three weeks untouched and hasn't been answered here.
    var quietFocus: Todo? {
        guard !focusKept, let focused = store.focusedTodo, store.health.focusGoneQuiet else { return nil }
        return focused
    }

    func redate(_ todo: Todo, inDays days: Int?) {
        let due = days.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: Date()) }
            .map { Self.isoDay.string(from: $0) }
        store.setDue(todo, due: due)
        redated += 1
    }

    func clearWait(_ todo: Todo) {
        store.clearWaiting([todo])
        waitsCleared += 1
    }

    func drop(_ todo: Todo) {
        store.drop([todo])
        dropped += 1
    }

    func keepFocus(_ todo: Todo) {
        store.keep([todo])
        focusKept = true
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Wrapping up

    /// What the review did, in a line: "Kept 3 · dropped 2 · brief updated". Empty when it did nothing.
    var tally: String {
        let c = catchUp
        var parts: [String] = []
        func add(_ n: Int, _ word: String) { if n > 0 { parts.append("\(word) \(n)") } }
        add(c?.count(.kept) ?? 0, "kept")
        add(c?.count(.picked) ?? 0, "picked up")
        add((c?.count(.dropped) ?? 0) + dropped, "dropped")
        add(redated, "redated")
        add(waitsCleared, "waits cleared")
        if focusKept { parts.append("focus kept") }
        if briefUpdated { parts.append("brief updated") }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: " · ")
    }

    /// Whether anything has been written, or would be: the test for whether this was a review at all.
    private var didAnything: Bool {
        !tally.isEmpty || [thoughts, learning, nextTask].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Write what's left: your thoughts and the tally as the sitting's note, a learning, the next task.
    /// Then archive, when asked. A review that did nothing takes its empty heading away instead.
    /// Called once, from Finish or from the window closing.
    func wrapUp(archiving: Bool = false) {
        guard !isWrappedUp else { return }
        isWrappedUp = true
        leave(step)
        guard didAnything else {
            // Only a heading that's still empty: one written in from elsewhere meanwhile is a sitting.
            if let sitting, let i = sitting.index, let sessions = store.notes?.sessions, sessions.indices.contains(i),
               ProjectReview.isReview(sessions[i]),
               sessions[i].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.deleteSession(sitting)
            }
            if archiving { archive() }
            return
        }

        let trimmed = thoughts.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = tally.isEmpty ? "Reviewed." : "Reviewed: \(tally.prefix(1).lowercased() + tally.dropFirst())."
        let note = trimmed.isEmpty ? line : "\(trimmed)\n\n\(line)"
        let learning = learning.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTask = nextTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = store
        // Chained, so each lands in the sitting the one before it left current, and the archive moves
        // the folder only once everything is written into it.
        let finish = { if archiving { self.archive() } }
        let addNext = {
            guard !nextTask.isEmpty else { return finish() }
            store.addTodo(text: nextTask, then: finish)
        }
        store.appendSessionNote(note) {
            guard !learning.isEmpty else { return addNext() }
            store.saveDetails({ notes in
                var notes = notes
                notes.learnings = notes.learnings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } + [learning]
                return notes
            }, then: addNext)
        }
    }

    private func archive() {
        guard let name = store.projectName else { return }
        do {
            try ProjectLifecycle.move(projectNamed: name, from: isArea ? .areas : .active)
        } catch {
            ProjectLifecycle.present(error, doing: isArea ? "Couldn't put down “\(name)”" : "Couldn't archive “\(name)”")
        }
    }
}

struct ProjectReviewView: View {
    @State var model: ProjectReviewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if model.step != .catchUp {
                Divider()
                footer
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.step.title).font(FolioType.title)
                Text(model.store.projectName.map(projectTitle(fromFolderName:)) ?? "")
                    .font(FolioType.meta).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.position + 1) of \(model.steps.count)")
                .font(FolioType.meta).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .recap: recap
        case .brief: brief
        case .catchUp:
            if let catchUp = model.catchUp {
                StaleReviewView(model: catchUp, embedded: true) { model.next() }
            }
        case .datesAndWaits: datesAndWaits
        case .thoughts: thoughts
        case .wrapUp: wrapUp
        }
    }

    // MARK: Steps

    private var recap: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BriefLabel(model.lastReviewed.map { "Since the last review, \($0)" } ?? "The last three weeks")
                if model.recap.isEmpty {
                    Text("No sittings.").font(FolioType.body).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.recap.prefix(12)) { sitting in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(sitting.day).font(FolioType.meta).foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .leading)
                                Text(sitting.lede.isEmpty ? "Tasks only" : sitting.lede)
                                    .font(FolioType.body).lineLimit(2)
                                    .foregroundStyle(sitting.lede.isEmpty ? .secondary : .primary)
                            }
                        }
                        if model.recap.count > 12 {
                            Text("and \(model.recap.count - 12) more").font(FolioType.meta).foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(doneLine).font(FolioType.body).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Take a minute to remember where this got to before deciding anything.")
                    .font(FolioType.meta).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private var doneLine: String {
        let done = model.doneSince == 1 ? "1 task done" : "\(model.doneSince) tasks done"
        return model.droppedSince > 0 ? "\(done), \(model.droppedSince) dropped." : "\(done)."
    }

    private var brief: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                field("Summary", text: $model.summary)
                if !model.isArea { field("Problem", text: $model.problem) }
                VStack(alignment: .leading, spacing: 4) {
                    BriefLabel("Goals")
                    ForEach(0..<3, id: \.self) { i in
                        TextField("Goal \(i + 1)", text: $model.goals[i], axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(FolioType.body)
                    }
                }
                if !model.isArea { field("Approach", text: $model.approach) }
                Text("Is it still true? Change what's drifted.")
                    .font(FolioType.meta).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            BriefLabel(title)
            TextField(title, text: text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder).font(FolioType.body)
        }
    }

    private var datesAndWaits: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let overdue = model.overdue
                if !overdue.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BriefLabel("Overdue")
                        ForEach(overdue, id: \.reviewID) { todo in
                            row(todo, detail: todo.dueDate.flatMap(RelativeDue.parse).map {
                                "Was due \($0.formatted(date: .abbreviated, time: .omitted))"
                            }) {
                                Button("Tomorrow") { model.redate(todo, inDays: 1) }
                                Button("Next Week") { model.redate(todo, inDays: 7) }
                                Button("No Date") { model.redate(todo, inDays: nil) }
                                Button("Drop") { model.drop(todo) }
                            }
                        }
                    }
                }
                let waits = model.releasedWaits
                if !waits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BriefLabel("Waiting on something that's done")
                        ForEach(waits, id: \.reviewID) { todo in
                            row(todo, detail: todo.waiting.map { "\(ProjectCodes.display($0)) has been archived" }) {
                                Button("Clear Wait") { model.clearWait(todo) }
                                Button("Drop") { model.drop(todo) }
                            }
                        }
                    }
                }
                if let focus = model.quietFocus {
                    VStack(alignment: .leading, spacing: 8) {
                        BriefLabel("Still your focus?")
                        row(focus, detail: "Untouched for three weeks or more") {
                            Button("Keep") { model.keepFocus(focus) }
                            Button("Drop") { model.drop(focus) }
                        }
                    }
                }
                if overdue.isEmpty && waits.isEmpty && model.quietFocus == nil {
                    Text("All sorted.").font(FolioType.body).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private func row<Actions: View>(_ todo: Todo, detail: String?, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(todo.text).font(FolioType.body).textSelection(.enabled)
            if let detail { Text(detail).font(FolioType.meta).foregroundStyle(.secondary) }
            HStack(spacing: 6) { actions() }.controlSize(.small)
        }
    }

    private var thoughts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    BriefLabel("What do you think now?")
                    TextField("Where this stands, what's next, what's bothering you…",
                              text: $model.thoughts, axis: .vertical)
                        .lineLimit(5...12)
                        .textFieldStyle(.roundedBorder).font(FolioType.reading)
                }
                VStack(alignment: .leading, spacing: 4) {
                    BriefLabel("A learning")
                    TextField("Optional, for Learnings", text: $model.learning)
                        .textFieldStyle(.roundedBorder).font(FolioType.body)
                }
                VStack(alignment: .leading, spacing: 4) {
                    BriefLabel("The next task")
                    TextField("Optional", text: $model.nextTask)
                        .textFieldStyle(.roundedBorder).font(FolioType.body)
                }
                Text("This becomes the note of today's Review sitting.")
                    .font(FolioType.meta).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private var wrapUp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.tally.isEmpty ? "Nothing changed." : model.tally).font(FolioType.body)
            Text("Finish to write the review into today's sitting. Each change is a step you can undo with ⌘Z in the project.")
                .font(FolioType.meta).foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Back") { model.back() }
                .disabled(model.position == 0)
            Spacer()
            if model.isLast {
                Button(model.isArea ? "Finish and Put Down" : "Finish and Archive") {
                    model.wrapUp(archiving: true)
                    onClose()
                }
                Button("Finish") {
                    model.wrapUp()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { model.next() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

/// The window a review is held in. One at a time: opening another replaces it, wrapping the first up.
@MainActor
final class ProjectReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = ProjectReviewWindowController()

    private var window: NSWindow?
    private var model: ProjectReviewModel?
    /// The project whose store the open review holds, released when it closes.
    private var heldKey: String?

    private override init() { super.init() }

    /// Open a review of `store`'s project. The store is held for as long as the window is open, so the
    /// answers have somewhere to go however the window that offered it went away.
    func show(for store: PMStore) {
        guard let key = store.projectKey else { return }
        close()
        let held = StoreRegistry.shared.acquire(key)
        heldKey = key
        let model = ProjectReviewModel(store: held)
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Review"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ProjectReviewView(model: model) { [weak self] in
            self?.close()
        })
        window.setFrameAutosaveName("PMProjectReviewWindow")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    /// Open a review of a project by its folder, from a surface with no store for it.
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
        finish()
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        finish()
    }

    /// Closing the window is finishing: what was answered stays, and the thoughts typed so far are kept.
    private func finish() {
        model?.wrapUp()
        model = nil
        StoreRegistry.shared.release(heldKey)
        heldKey = nil
    }
}
