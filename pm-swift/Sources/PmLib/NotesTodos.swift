import Foundation

/// Focus marker: space + @ at end of task line. Only one such line should exist in the notes file.
private let focusMarkerSuffix = " @"

private let dueInlinePattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"\s+due:\s*(\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?|\d{1,2}-\d{1,2}-\d{4}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?)(?=\s*@|\s*$)"#)
}()

/// Inline `waiting: [[Target]]` — what this task is waiting on before it can move.
///
/// The target is always bracketed, and that isn't decoration. `due:` can be permissive about what
/// follows it because a date has a shape; a wait target is a name, so an unbracketed `waiting:` would
/// swallow the rest of any task line that happens to contain the word — "stop waiting: it's done"
/// would parse as a wait on "it's done". Brackets give the value the terminator it otherwise lacks,
/// and they're the syntax the vault these notes live in already uses for naming another note.
private let waitingInlinePattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"\s+waiting:\s*\[\[([^\]\n]+)\]\]\s*$"#)
}()

// MARK: - Task line content
//
// Every mutation below decomposes a task line into (list prefix, checkbox, content) and rewrites the
// content. `TaskContent` is the one place that knows how a content string encodes its text, its
// inline `due:` and its focus marker — so no caller has to re-derive it with a raw `hasSuffix(" @")`,
// which silently misreads any line where the two tokens aren't in the canonical order.

/// A task line's content, split into its parts. Canonical storage order is
/// `<text> waiting: [[<target>]] due: <date> @`, but a line written by an older or third-party client
/// can carry the trailing tokens in any other order; `split` accepts all of them so a stray order can
/// never hide a token from an edit, and `render` always writes the canonical order back — so any line
/// touched by an edit is repaired in place.
public struct TaskContent: Equatable {
    /// The task text, with the waiting, due and focus tokens removed.
    public var text: String
    /// Inline `due:` value, stored as-is for display. nil when the task has no own due.
    public var due: String?
    /// Inline `waiting:` target — the name inside the brackets, stored as-is. nil when this task isn't
    /// waiting on anything of its own. Whether that name is a project, an area or a person is a
    /// question for a resolver that can see the folders; nothing here knows or needs to.
    public var waiting: String?
    /// True when this line carries the ` @` focus marker.
    public var focused: Bool

    public init(text: String, due: String? = nil, waiting: String? = nil, focused: Bool = false) {
        self.text = text
        self.due = due
        self.waiting = waiting
        self.focused = focused
    }

    /// Split a task line's content (everything after the checkbox) into its parts.
    ///
    /// Peels trailing tokens in a loop rather than in a fixed sequence, because with three of them the
    /// unrolled version would need six orderings to stay order-agnostic. Each token only has to know
    /// how to recognise itself at the end of what's left; the loop makes any arrangement of them parse
    /// identically. First value wins, so a line carrying a token twice keeps the outermost one rather
    /// than silently taking the last.
    public static func split(_ content: String) -> TaskContent {
        var rest = content.trimmingCharacters(in: .whitespaces)
        var focused = false
        var due: String?
        var waiting: String?
        while true {
            if let stripped = strippingFocusMarker(rest) {
                rest = stripped; focused = true; continue
            }
            if let (value, without) = strippingInlineDue(rest) {
                if due == nil { due = value }
                rest = without; continue
            }
            if let (value, without) = strippingWaiting(rest) {
                if waiting == nil { waiting = value }
                rest = without; continue
            }
            break
        }
        return TaskContent(
            text: rest.trimmingCharacters(in: .whitespaces),
            due: (due?.isEmpty == false) ? due : nil,
            waiting: (waiting?.isEmpty == false) ? waiting : nil,
            focused: focused
        )
    }

    /// Render back to a content string in canonical order:
    /// `<text> waiting: [[<target>]] due: <date> @`.
    ///
    /// Waiting sits inside the due, not outside it, so that `dueInlinePattern` — which only matches a
    /// due followed by the focus marker or the end of the line — keeps matching a line that carries
    /// both. A canonical order that put the wait last would break every existing due.
    public func render() -> String {
        var out = text.trimmingCharacters(in: .whitespaces)
        if let waiting = waiting, !waiting.isEmpty { out += " waiting: [[\(waiting)]]" }
        if let due = due, !due.isEmpty { out += " due: \(due)" }
        if focused { out += focusMarkerSuffix }
        return out
    }

    /// Drop a trailing ` @` (the marker is a separate token — a word ending in "@" isn't one).
    private static func strippingFocusMarker(_ s: String) -> String? {
        guard s.hasSuffix(focusMarkerSuffix) else { return nil }
        return String(s.dropLast(focusMarkerSuffix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Drop a trailing inline `waiting: [[<target>]]`, returning the bracketed name and the remaining
    /// content. Anchored at the end, like the focus marker — a `waiting:` in the middle of a sentence
    /// is prose, not a token.
    private static func strippingWaiting(_ s: String) -> (waiting: String, without: String)? {
        guard let pattern = waitingInlinePattern,
              let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r0 = Range(m.range(at: 0), in: s),
              let r1 = Range(m.range(at: 1), in: s) else {
            return nil
        }
        let without = String(s[..<r0.lowerBound]) + String(s[r0.upperBound...])
        return (String(s[r1]).trimmingCharacters(in: .whitespaces),
                without.trimmingCharacters(in: .whitespaces))
    }

    /// Drop a trailing inline `due: <date>`, returning its value and the remaining content.
    private static func strippingInlineDue(_ s: String) -> (due: String, without: String)? {
        guard let pattern = dueInlinePattern,
              let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r0 = Range(m.range(at: 0), in: s),
              let r1 = Range(m.range(at: 1), in: s) else {
            return nil
        }
        let without = String(s[..<r0.lowerBound]) + String(s[r0.upperBound...])
        return (String(s[r1]), without.trimmingCharacters(in: .whitespaces))
    }
}

/// Normalizes session bodies so at most one task line carries the ` @` focus marker. The first such
/// line (by session order, then line order) keeps it; all others have it stripped. Every task line is
/// re-rendered in canonical `<text> due: <date> @` order, so a line stored the other way round is
/// repaired the next time the notes are edited.
public func normalizeFocusMarker(notes: ProjectNotes) -> ProjectNotes {
    guard let pattern = todoLinePattern else { return notes }
    var foundFirst = false
    var outSessions: [Session] = []
    for session in notes.sessions {
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var outLines: [String] = []
        for line in lines {
            guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r1 = Range(m.range(at: 1), in: line),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else {
                outLines.append(line)
                continue
            }
            var content = TaskContent.split(String(line[r3]))
            if content.focused {
                if foundFirst {
                    content.focused = false
                } else {
                    foundFirst = true
                }
            }
            outLines.append("\(String(line[r1]))[\(String(line[r2]))] \(content.render())")
        }
        let newBody = outLines.joined(separator: "\n")
        outSessions.append(Session(date: session.date, label: session.label, body: newBody))
    }
    return ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: outSessions
    )
}


public func parseTodos(notes: ProjectNotes) throws -> [Todo] {
    guard let todoLinePattern = todoLinePattern else {
        throw PmError.notesRegexError(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
    }
    var todos: [Todo] = []
    var foundFocused = false
    for (sessionIndex, session) in notes.sessions.enumerated() {
        let context = session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
        // The stable half of a TaskRef coordinate, carried on every task so a reader never has to
        // re-derive it from the heading. nil only for a session heading this parser didn't write.
        let isoDate = sessionISODate(heading: session.date)
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineIndex = 0
        for line in lines {
            guard let m = todoLinePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else { continue }
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let depth = leadingSpaces / 2
            let checked = line[r2].lowercased() == "x"
            let content = TaskContent.split(String(line[r3]))
            let dueDate = content.due
            let text = content.text
            // Only the first marked line counts as focused; normalizeFocusMarker prunes the rest on
            // the next write.
            let isFocused = content.focused && !foundFocused
            if isFocused { foundFocused = true }
            todos.append(Todo(
                text: text,
                checked: checked,
                rawLine: line,
                context: context,
                depth: depth,
                sessionIndex: sessionIndex,
                lineIndex: lineIndex,
                isFocused: isFocused,
                dueDate: dueDate,
                waiting: content.waiting,
                digest: taskDigest(text),
                sessionISODate: isoDate
            ))
            lineIndex += 1
        }
    }
    return todos
}

/// Compare due date strings by calendar order (earliest first). Uses first 10 chars (YYYY-MM-DD) when present so "2025-03-15" and "2025-03-15 14:30" compare equal.
private func dueDateSortKey(_ s: String) -> String {
    let prefix = String(s.prefix(10))
    if prefix.count == 10, prefix.filter({ $0 == "-" }).count == 2 {
        return prefix
    }
    return s
}

/// Earliest due date among ancestors (parent, grandparent, …). "Nearest" = soonest deadline. Returns nil if no ancestor has a due.
private func earliestAncestorDue(sessionTodos: [Todo], idx: Int) -> String? {
    var candidates: [String] = []
    var i = idx
    while let p = parentOf(sessionTodos: sessionTodos, idx: i) {
        if let d = sessionTodos[p].dueDate { candidates.append(d) }
        i = p
    }
    return candidates.min(by: { dueDateSortKey($0) < dueDateSortKey($1) })
}

/// Returns todos with effectiveDueDate set: earliest due among own and all ancestors (nearest
/// deadline). Use when producing notes show output.
///
/// Copies each todo and sets the one field, rather than rebuilding it from a list of the fields this
/// function happens to know about. The rebuild silently dropped anything added to `Todo` later —
/// which is how the first cut of task digests reached `notes show` as nulls.
public func todosWithEffectiveDueDates(_ todos: [Todo]) -> [Todo] {
    let bySession = Dictionary(grouping: todos) { $0.sessionIndex }
    return todos.map { todo in
        var out = todo
        let sessionTodos = (bySession[todo.sessionIndex] ?? []).sorted { $0.lineIndex < $1.lineIndex }
        guard let idx = sessionTodos.firstIndex(where: { $0.lineIndex == todo.lineIndex }) else {
            out.effectiveDueDate = todo.dueDate
            return out
        }
        var candidates: [String] = []
        if let own = todo.dueDate { candidates.append(own) }
        if let ancestor = earliestAncestorDue(sessionTodos: sessionTodos, idx: idx) { candidates.append(ancestor) }
        out.effectiveDueDate = candidates.min(by: { dueDateSortKey($0) < dueDateSortKey($1) })
        return out
    }
}

/// The nearest waiting ancestor (parent, then grandparent, …). Returns nil if no ancestor is waiting.
///
/// Nearest, not earliest — see `Todo.effectiveWaiting`. Two ancestors both waiting isn't a conflict to
/// resolve, it's a chain, and the one that blocks this task is the closest link in it.
private func nearestAncestorWaiting(sessionTodos: [Todo], idx: Int) -> String? {
    var i = idx
    while let p = parentOf(sessionTodos: sessionTodos, idx: i) {
        if let w = sessionTodos[p].waiting { return w }
        i = p
    }
    return nil
}

/// Returns todos with `effectiveWaiting` set: own wait if there is one, else the nearest waiting
/// ancestor's. Use when producing notes show output.
///
/// Copies each todo and sets the one field, for the same reason `todosWithEffectiveDueDates` does —
/// a rebuild from a field list silently drops whatever is added to `Todo` next.
public func todosWithEffectiveWaiting(_ todos: [Todo]) -> [Todo] {
    let bySession = Dictionary(grouping: todos) { $0.sessionIndex }
    return todos.map { todo in
        var out = todo
        if let own = todo.waiting {
            out.effectiveWaiting = own
            return out
        }
        let sessionTodos = (bySession[todo.sessionIndex] ?? []).sorted { $0.lineIndex < $1.lineIndex }
        guard let idx = sessionTodos.firstIndex(where: { $0.lineIndex == todo.lineIndex }) else {
            return out
        }
        out.effectiveWaiting = nearestAncestorWaiting(sessionTodos: sessionTodos, idx: idx)
        return out
    }
}

private let todoLinePattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
}()

public extension Todo {
    /// Whether this task can be handed to someone as the thing to do next.
    ///
    /// Focus is a promise that the task it lands on is workable, so a task waiting on something else
    /// isn't a candidate — not because it doesn't matter, but because offering it is offering work
    /// that can't start. Reads `effectiveWaiting`, so a task under a blocked parent is skipped too:
    /// the parent's wait is the child's.
    ///
    /// Note what this means when *everything* open is waiting — no candidate anywhere, and focus
    /// clears. That's the honest answer, and the callers already handle it: a project with nothing
    /// available has nothing to be focused on.
    ///
    /// Absent any wait this is exactly `!checked`, which is what every selector below tested before.
    var isAvailableForFocus: Bool { !checked && effectiveWaiting == nil }
}

// MARK: - The three questions a task list gets asked
//
// A wait answers each of them differently, and every surface that asks one should ask it here rather
// than spelling out its own filter. The rule is `ProjectKind`'s: a call site may *select* by these,
// but it doesn't get to decide for itself what "next" means — that difference lives in one place, so
// grepping one symbol gives the complete list of everywhere it's honoured.
//
// This existed as four separate spellings before waits did, which is how the sidebar, the switcher,
// the menubar and the focus panel all came to promise work that focus itself would have skipped.

public extension Array where Element == Todo {
    /// **What's outstanding.** Open, whether or not it's waiting.
    ///
    /// Counts, progress rings, task search and due dates all want this one. A blocked task still has
    /// to be done, and a blocked task with a deadline is *exactly* when the deadline matters — hiding
    /// it because something is in the way would suppress the warning at the moment it's earned.
    var openTasks: [Todo] { filter { !$0.checked } }

    /// **What you could pick up.** Open and not waiting on anything.
    ///
    /// Everything that offers you a task: focus advancement, the sidebar's next-task line, the
    /// switcher's second line, the menubar, the focus panel card.
    ///
    /// Requires `effectiveWaiting` to have been computed — it comes that way out of `notesShow`,
    /// which is the single read path every surface goes through.
    var availableTasks: [Todo] { filter(\.isAvailableForFocus) }

    /// **What you're blocked on.** Open and waiting, whether the wait is its own or inherited.
    var waitingTasks: [Todo] { filter { !$0.checked && $0.effectiveWaiting != nil } }

    /// The task a surface should show as this project's current one: the focused task, else the first
    /// one that could actually be picked up.
    ///
    /// The fallback is the half that matters. A project with nothing focused used to show its first
    /// *open* task, which after waits arrived meant four surfaces offering work that couldn't start
    /// while focus itself declined to.
    ///
    /// A focused task that is waiting still wins — focus advancement skips waits, so getting there
    /// took a deliberate act, and this reports what the document says rather than overruling it.
    var heroTask: Todo? { first(where: \.isFocused) ?? availableTasks.first }
}

// MARK: - Now-style focus advance (parent's first leaf, else next sibling's first leaf, else parent)
// Full flow: docs/task-focus-flow.md

/// First leaf in the subtree rooted at idx (deepest first descendant, or self if leaf).
private func firstLeafOf(sessionTodos: [Todo], idx: Int) -> Int {
    guard idx + 1 < sessionTodos.count, sessionTodos[idx + 1].depth > sessionTodos[idx].depth else {
        return idx
    }
    return firstLeafOf(sessionTodos: sessionTodos, idx: idx + 1)
}

/// First leaf in the parent's subtree (document order), excluding any index in indicesToComplete. Returns nil if parent has no such leaf.
private func firstLeafOfParentExcluding(sessionTodos: [Todo], parentIdx: Int, indicesToComplete: Set<Int>) -> Int? {
    let parentDepth = sessionTodos[parentIdx].depth
    var i = parentIdx + 1
    while i < sessionTodos.count, sessionTodos[i].depth > parentDepth {
        let isLeaf = (i + 1 >= sessionTodos.count) || (sessionTodos[i + 1].depth <= sessionTodos[i].depth)
        if isLeaf, !indicesToComplete.contains(i), sessionTodos[i].isAvailableForFocus {
            return i
        }
        i += 1
    }
    return nil
}

/// Index of the parent task (last task before idx with strictly lesser depth), or nil if root-level.
private func parentOf(sessionTodos: [Todo], idx: Int) -> Int? {
    let depth = sessionTodos[idx].depth
    for i in (0..<idx).reversed() {
        if sessionTodos[i].depth < depth { return i }
    }
    return nil
}

/// Sibling line indices at same depth under the same parent, and our position among them.
private func siblingIndicesAndPosition(sessionTodos: [Todo], idx: Int) -> (indices: [Int], position: Int)? {
    let depth = sessionTodos[idx].depth
    let parentIdx = parentOf(sessionTodos: sessionTodos, idx: idx)
    let parentDepth: Int
    let rangeStart: Int
    if let p = parentIdx {
        parentDepth = sessionTodos[p].depth
        rangeStart = p + 1
    } else {
        parentDepth = -1
        rangeStart = 0
    }
    var siblingIndices: [Int] = []
    var i = rangeStart
    while i < sessionTodos.count, sessionTodos[i].depth > parentDepth {
        if sessionTodos[i].depth == depth {
            siblingIndices.append(i)
        }
        i += 1
    }
    guard let pos = siblingIndices.firstIndex(of: idx) else { return nil }
    return (siblingIndices, pos)
}

/// First open (unchecked) leaf in document order that is not in the completed set. Used when no structural candidate exists.
private func firstOpenLeafNotInSet(todos: [Todo], completedSessionIndex: Int, indicesToComplete: Set<Int>) -> Todo? {
    let sessionIndices = Set(todos.map(\.sessionIndex)).sorted()
    for sessionIdx in sessionIndices {
        let sessionTodos = todos.filter { $0.sessionIndex == sessionIdx }.sorted { $0.lineIndex < $1.lineIndex }
        for i in 0..<sessionTodos.count {
            let t = sessionTodos[i]
            guard t.isAvailableForFocus else { continue }
            if sessionIdx == completedSessionIndex, indicesToComplete.contains(t.lineIndex) { continue }
            let isLeaf = (i + 1 >= sessionTodos.count) || (sessionTodos[i + 1].depth <= t.depth)
            if isLeaf { return t }
        }
    }
    return nil
}

/// Choose next focus using now pattern: parent's first leaf, else next sibling's first leaf, else parent. Prefer unchecked.
private func selectNewCurrentAfterRemoval(
    sessionTodos: [Todo],
    completedLineIndex: Int,
    indicesToComplete: Set<Int>
) -> Todo? {
    guard let (siblingIndices, position) = siblingIndicesAndPosition(sessionTodos: sessionTodos, idx: completedLineIndex) else {
        return nil
    }
    var candidates: [Int] = []
    if let parentIdx = parentOf(sessionTodos: sessionTodos, idx: completedLineIndex),
       let parentFirstLeaf = firstLeafOfParentExcluding(sessionTodos: sessionTodos, parentIdx: parentIdx, indicesToComplete: indicesToComplete) {
        candidates.append(parentFirstLeaf)
    }
    if position + 1 < siblingIndices.count {
        let nextSiblingIdx = siblingIndices[position + 1]
        candidates.append(firstLeafOf(sessionTodos: sessionTodos, idx: nextSiblingIdx))
    }
    if let parentIdx = parentOf(sessionTodos: sessionTodos, idx: completedLineIndex) {
        candidates.append(parentIdx)
    }
    let validCandidates = candidates.filter { !indicesToComplete.contains($0) }
    if let firstAvailable = validCandidates.first(where: { sessionTodos[$0].isAvailableForFocus }) {
        return sessionTodos[firstAvailable]
    }
    // Falling back to a *checked* candidate keeps focus somewhere structural when the subtree is
    // finished; falling back to a waiting one would be handing over blocked work, so those drop out
    // here and the caller's document-wide search gets a turn instead.
    if let firstAny = validCandidates.first(where: { sessionTodos[$0].effectiveWaiting == nil }) {
        return sessionTodos[firstAny]
    }
    return nil
}

/// The task that "Dive In" should focus next, given `todos` in document order (as produced by
/// `parseTodos`: grouped by session, then by line). Mirrors the Raycast "Dive In" command, extended
/// with a forward "advance" fallback so repeated dives walk down through the task list rather than
/// stalling once you reach a leaf:
///
///   1. A focused task with an open (unchecked) leaf in its subtree → that leaf (first in document
///      order). This is the "dive deeper" case.
///   2. A focused task that is already a leaf (or whose subtree is fully checked) → the next open
///      leaf *after* it in document order. This is the "advance to the next task" case.
///   3. Nothing focused → the first open leaf anywhere.
///   4. Otherwise (no open leaf to move to — everything checked, or already at the last open leaf) →
///      nil, so callers can no-op.
///
/// Also drives the panel's "Next" hint, so the hint and the action can never diverge. A "leaf" is a
/// task whose next task in the same session isn't deeper; a new session always ends the subtree.
public func nextDiveInLeaf(todos: [Todo]) -> Todo? {
    guard !todos.isEmpty else { return nil }
    // Computed here rather than required of the caller: `effectiveWaiting` is nil both when a task
    // isn't waiting and when nobody worked out whether it was, and a selector that can't tell those
    // apart would quietly hand back blocked work whenever a caller forgot the pass.
    let todos = todosWithEffectiveWaiting(todos)
    func isLeaf(_ i: Int) -> Bool {
        let n = i + 1
        return n >= todos.count
            || todos[n].sessionIndex != todos[i].sessionIndex
            || todos[n].depth <= todos[i].depth
    }
    func isOpenLeaf(_ i: Int) -> Bool { todos[i].isAvailableForFocus && isLeaf(i) }

    guard let fi = todos.firstIndex(where: { $0.isFocused }) else {
        // Nothing focused: the first open leaf anywhere.
        return todos.indices.first(where: isOpenLeaf).map { todos[$0] }
    }
    // 1. Dive in: the first open leaf strictly beneath the focused task (same session, deeper).
    let fd = todos[fi].depth
    var j = fi + 1
    while j < todos.count, todos[j].sessionIndex == todos[fi].sessionIndex, todos[j].depth > fd {
        if isOpenLeaf(j) { return todos[j] }
        j += 1
    }
    // 2. No open leaf beneath: advance to the next open leaf AFTER the focused task, in document
    //    order. (Not the *first* open leaf in the document — that would jump backward past the
    //    focused task, which is what "Dive In" was doing wrong.)
    if let k = ((fi + 1)..<todos.count).first(where: isOpenLeaf) { return todos[k] }
    return nil
}

/// Complete the todo at (sessionIndex, lineIndex) and all its descendants. Optionally move focus to next open todo (now-style: parent's first leaf, else next sibling first leaf, else parent).
public func completeTodoWithDescendants(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int, advanceFocus: Bool) throws -> ProjectNotes {
    let todos = todosWithEffectiveWaiting(try parseTodos(notes: notes))
    guard sessionIndex < notes.sessions.count else { return notes }
    let sessionTodos = todos.filter { $0.sessionIndex == sessionIndex }.sorted { $0.lineIndex < $1.lineIndex }
    guard lineIndex < sessionTodos.count else { return notes }
    let parent = sessionTodos[lineIndex]
    let parentDepth = parent.depth
    var indicesToComplete: Set<Int> = [lineIndex]
    for i in (lineIndex + 1)..<sessionTodos.count {
        if sessionTodos[i].depth <= parentDepth { break }
        indicesToComplete.insert(i)
    }
    guard let pattern = todoLinePattern else { return notes }
    let session = notes.sessions[sessionIndex]
    let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var taskCount = 0
    var outLines: [String] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(m.range(at: 1), in: line),
              let r2 = Range(m.range(at: 2), in: line),
              let r3 = Range(m.range(at: 3), in: line) else {
            outLines.append(line)
            i += 1
            continue
        }
        let check = String(line[r2])
        let content = String(line[r3])
        let isUnchecked = check.lowercased() != "x"
        let shouldComplete = indicesToComplete.contains(taskCount) && isUnchecked
        if shouldComplete {
            // A completed task keeps its due but drops focus — where focus lands next is decided below.
            var completed = TaskContent.split(content)
            completed.focused = false
            outLines.append("\(String(line[r1]))[x] \(completed.render())")
        } else {
            outLines.append(line)
        }
        taskCount += 1
        i += 1
    }
    var updatedNotes = ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: notes.sessions
    )
    updatedNotes.sessions[sessionIndex] = Session(date: session.date, label: session.label, body: outLines.joined(separator: "\n"))
    let shouldAdvance = advanceFocus || parent.isFocused
    if shouldAdvance {
        let nextTodo: Todo?
        if let nowStyle = selectNewCurrentAfterRemoval(sessionTodos: sessionTodos, completedLineIndex: lineIndex, indicesToComplete: indicesToComplete) {
            nextTodo = nowStyle
        } else {
            nextTodo = firstOpenLeafNotInSet(todos: todos, completedSessionIndex: sessionIndex, indicesToComplete: indicesToComplete)
        }
        updatedNotes = applyFocusToTodoInNotes(notes: updatedNotes, todo: nextTodo)
    }
    return updatedNotes
}

/// Move the single " @" focus marker to the task at (sessionIndex, lineIndex). Strips @ from all other task lines.
public func applyFocusToTodoAt(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int) -> ProjectNotes {
    guard let pattern = todoLinePattern else { return notes }
    var outSessions: [Session] = []
    for (si, session) in notes.sessions.enumerated() {
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var taskCount = 0
        var outLines: [String] = []
        for line in lines {
            guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r1 = Range(m.range(at: 1), in: line),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else {
                outLines.append(line)
                continue
            }
            var content = TaskContent.split(String(line[r3]))
            content.focused = si == sessionIndex && taskCount == lineIndex
            outLines.append("\(String(line[r1]))[\(String(line[r2]))] \(content.render())")
            taskCount += 1
        }
        outSessions.append(Session(date: session.date, label: session.label, body: outLines.joined(separator: "\n")))
    }
    return ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: outSessions
    )
}

/// Set or clear the inline `waiting:` on the task at (sessionIndex, lineIndex). Passing nil clears it.
///
/// Written as a sibling of `setDueOnTodoAt` rather than folded into a shared "set a token" helper:
/// the two differ only in the field they assign, but that field is the whole operation, and the
/// generalised version would take a key path or an enum to say which — a parameter whose only job is
/// to undo the generalisation.
public func setWaitingOnTodoAt(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int,
                               waiting: String?) -> ProjectNotes {
    editTaskLine(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex) { content in
        content.waiting = (waiting?.isEmpty == false) ? waiting : nil
    }
}

/// Rewrite one task line's content in place, leaving every other line — and the line's own list
/// prefix and checkbox — exactly as it was found.
///
/// The walk this does (find the nth task line in a session, splice it, leave the rest) was written out
/// once per mutation before there were three of them. It is the part that has to agree with
/// `parseTodos` about what counts as a task line and in what order, so it is the part worth having in
/// one place.
func editTaskLine(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int,
                  _ mutate: (inout TaskContent) -> Void) -> ProjectNotes {
    guard sessionIndex < notes.sessions.count, let pattern = todoLinePattern else { return notes }
    let session = notes.sessions[sessionIndex]
    let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var taskCount = 0
    var outLines: [String] = []
    for line in lines {
        guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(m.range(at: 1), in: line),
              let r2 = Range(m.range(at: 2), in: line),
              let r3 = Range(m.range(at: 3), in: line) else {
            outLines.append(line)
            continue
        }
        if taskCount != lineIndex {
            outLines.append(line)
            taskCount += 1
            continue
        }
        var content = TaskContent.split(String(line[r3]))
        mutate(&content)
        outLines.append("\(String(line[r1]))[\(String(line[r2]))] \(content.render())")
        taskCount += 1
    }
    var updated = notes
    updated.sessions[sessionIndex] = Session(date: session.date, label: session.label,
                                             body: outLines.joined(separator: "\n"))
    return updated
}

/// Set or clear the inline `due:` on the task at (sessionIndex, lineIndex). Passing nil clears it.
/// The text, the wait and the focus marker ride along untouched.
public func setDueOnTodoAt(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int, due: String?) -> ProjectNotes {
    editTaskLine(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex) { content in
        content.due = (due?.isEmpty == false) ? due : nil
    }
}

/// Replace the task text at (sessionIndex, lineIndex), preserving the list prefix/indent, checkbox
/// state, and the inline `due:`, `waiting:` and focus tokens.
public func setTextOnTodoAt(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int, text: String) -> ProjectNotes {
    editTaskLine(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex) { content in
        content.text = text.trimmingCharacters(in: .whitespaces)
    }
}

/// Uncheck the task at (sessionIndex, lineIndex) and move focus to it. One logical write.
public func undoTodoAt(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int) throws -> ProjectNotes {
    guard sessionIndex < notes.sessions.count else { return notes }
    guard let pattern = todoLinePattern else { return notes }
    let session = notes.sessions[sessionIndex]
    let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var taskCount = 0
    var outLines: [String] = []
    for line in lines {
        guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(m.range(at: 1), in: line),
              let r2 = Range(m.range(at: 2), in: line),
              let r3 = Range(m.range(at: 3), in: line) else {
            outLines.append(line)
            continue
        }
        let prefix = String(line[r1])
        var check = String(line[r2])
        // Focus is cleared everywhere here, then applied to the target line below.
        var content = TaskContent.split(String(line[r3]))
        content.focused = false
        if taskCount == lineIndex {
            check = " "
        }
        outLines.append("\(prefix)[\(check)] \(content.render())")
        taskCount += 1
    }
    var updatedNotes = ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: notes.sessions
    )
    updatedNotes.sessions[sessionIndex] = Session(date: session.date, label: session.label, body: outLines.joined(separator: "\n"))
    return applyFocusToTodoAt(notes: updatedNotes, sessionIndex: sessionIndex, lineIndex: lineIndex)
}

private func applyFocusToTodoInNotes(notes: ProjectNotes, todo: Todo?) -> ProjectNotes {
    guard let pattern = todoLinePattern else { return notes }
    let targetSessionIndex = todo?.sessionIndex ?? -1
    let targetLineIndex = todo?.lineIndex ?? -1
    var outSessions: [Session] = []
    for (si, session) in notes.sessions.enumerated() {
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var taskCount = 0
        var outLines: [String] = []
        for line in lines {
            guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r1 = Range(m.range(at: 1), in: line),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else {
                outLines.append(line)
                continue
            }
            var content = TaskContent.split(String(line[r3]))
            content.focused = todo != nil && si == targetSessionIndex && taskCount == targetLineIndex
            outLines.append("\(String(line[r1]))[\(String(line[r2]))] \(content.render())")
            taskCount += 1
        }
        outSessions.append(Session(date: session.date, label: session.label, body: outLines.joined(separator: "\n")))
    }
    return ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: outSessions
    )
}
