import Foundation

/// A `/` command in the note editor: something the line at the caret can be given.
///
/// The list is exactly the three things a task line can carry — that it's a task, when it's due, and
/// what it's waiting on. That isn't a starting subset; it's the whole vocabulary the notes format
/// has for a task, which is what makes a slash menu the right shape here rather than an open-ended
/// command palette. The quick bar's `>` is where app *commands* live, and this is deliberately not
/// that: `/` acts on the line under the caret, `>` acts on the project.
public struct EditorCommand: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        /// Make the line at the caret a task line.
        case makeTask
        /// Give the line an inline `due:` of this stored date.
        case setDue(String)
        /// Start a `waiting:` and hand straight over to the mention picker for its target.
        case startWaiting
    }

    public let id: String
    /// What the row reads.
    public let title: String
    /// The quiet half of the row — the date a preset stands for, so "Due next week" says which day.
    public let detail: String?
    public let action: Action

    public init(id: String, title: String, detail: String? = nil, action: Action) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
    }
}

/// The commands offered, in the order they're offered.
///
/// The date presets are `duePresets` — the same list the due chip's menu shows and the same one
/// `QuickCaptureParser` reads back — so "next week" means one day across the whole app rather than
/// one per surface that had to name it.
public func editorCommands(now: Date = Date(), calendar: Calendar = .current) -> [EditorCommand] {
    var commands: [EditorCommand] = [
        EditorCommand(id: "task", title: "Task", detail: "make this line a task", action: .makeTask),
        EditorCommand(id: "waiting", title: "Waiting on…", detail: "a project, an area, or a person",
                      action: .startWaiting),
    ]
    commands += duePresets(now: now, calendar: calendar).map {
        EditorCommand(id: "due-\($0.title.lowercased())", title: "Due \($0.title.lowercased())",
                      detail: DueFormat.string($0.date), action: .setDue(DueFormat.string($0.date)))
    }
    return commands
}

/// Rank commands against what's been typed after the `/`. An empty query offers all of them, which is
/// what a slash menu does — unlike a mention, where an empty query has nothing to search for.
public func rankEditorCommands(_ commands: [EditorCommand], query: String) -> [EditorCommand] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return commands }
    return commands.filter { command in
        let title = command.title.lowercased()
        return title.hasPrefix(needle)
            || title.split(separator: " ").contains { $0.hasPrefix(needle) }
    }
}

/// Run a command: remove the `/…` that summoned it and apply its effect to the line it was typed on.
///
/// `opensMention` is how `startWaiting` says the interaction isn't finished — it has written
/// `waiting: @` and the picker should come up on it, rather than leaving somebody to type a sigil
/// they've just been shown they don't have to.
public func applyEditorCommand(_ command: EditorCommand, to text: String,
                               removing range: Range<String.Index>)
    -> (text: String, selection: Range<String.Index>, opensMention: Bool) {
    var out = text
    out.replaceSubrange(range, with: "")

    // The space the slash was typed after goes with it, once, for every command. A token removed from
    // mid-sentence leaves the sentence intact; one removed from the end leaves the space that
    // separated it, and `TaskContent` would then be trimming it back off on every write.
    let slashOffset = text.distance(from: text.startIndex, to: range.lowerBound)
    var lineStart = lineStartIndex(in: out, at: out.index(out.startIndex, offsetBy: slashOffset))
    let lineStartOffset = out.distance(from: out.startIndex, to: lineStart)
    var lineEnd = lineEndIndex(in: out, at: lineStart)
    let trimmed = String(out[lineStart..<lineEnd]).replacingOccurrences(
        of: #"\s+$"#, with: "", options: .regularExpression)
    out.replaceSubrange(lineStart..<lineEnd, with: trimmed)
    lineStart = out.index(out.startIndex, offsetBy: lineStartOffset)
    lineEnd = out.index(lineStart, offsetBy: trimmed.count)

    func caretAtLineEnd() -> Range<String.Index> {
        let end = lineEndIndex(in: out, at: out.index(out.startIndex, offsetBy: lineStartOffset))
        return end..<end
    }

    switch command.action {
    case .makeTask:
        let indent = String(trimmed.prefix(while: { $0 == " " }))
        let body = String(trimmed.dropFirst(indent.count))
        // Already a task: the trailing-space tidy above is the whole effect, which is the right
        // answer — asking for what you already have shouldn't add a second checkbox.
        guard !body.hasPrefix("- [") else { break }
        let stripped = body.hasPrefix("- ") ? String(body.dropFirst(2)) : body
        out.replaceSubrange(lineStart..<lineEnd, with: "\(indent)- [ ] \(stripped)")

    case .setDue(let stored):
        out.replaceSubrange(lineEnd..<lineEnd, with: " due: \(stored)")

    case .startWaiting:
        out.replaceSubrange(lineEnd..<lineEnd, with: " waiting: @")
        return (out, caretAtLineEnd(), true)
    }
    return (out, caretAtLineEnd(), false)
}

/// The start of the line `index` is on.
func lineStartIndex(in text: String, at index: String.Index) -> String.Index {
    var i = index
    while i > text.startIndex {
        let previous = text.index(before: i)
        if text[previous] == "\n" { return i }
        i = previous
    }
    return text.startIndex
}

/// The end of the line `index` is on, not counting the newline.
func lineEndIndex(in text: String, at index: String.Index) -> String.Index {
    var i = index
    while i < text.endIndex {
        if text[i] == "\n" { return i }
        i = text.index(after: i)
    }
    return text.endIndex
}

/// The line's end with trailing spaces dropped, so appending a token doesn't double a space.
private func trimmedLineEnd(in text: String, from start: String.Index, to end: String.Index) -> String.Index {
    var i = end
    while i > start {
        let previous = text.index(before: i)
        guard text[previous] == " " else { break }
        i = previous
    }
    return i
}
