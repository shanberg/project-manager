import Foundation

// MARK: - Format-preserving notes edits
//
// The model round-trip (parseNotes → mutate → serializeNotes) regenerates the entire
// document on every write, which rewrites whitespace and drops any content the model
// doesn't capture (frontmatter, extra sections, custom spacing). For the interactive
// operations — toggling todos and adding sessions — only one or two lines actually change.
//
// These helpers reuse the tested model logic to decide *what* changes, then splice just
// those lines into the original markdown, leaving every other byte verbatim.

/// Task line: optional indent + "- ", a "[ ]"/"[x]" checkbox, then content.
private let rawTaskPattern = try? NSRegularExpression(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
/// Session heading: matches NotesParse's sessionHeading exactly so session indexing aligns with parseTodos.
private let rawSessionHeadingPattern = try? NSRegularExpression(
    pattern: #"^###\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2}),\s+(\d{4})(?:\s+(.*))?$"#
)
/// Any "## " section heading (ends the Sessions region, matching parseSessionsBlock's body boundary).
private let rawSectionPattern = try? NSRegularExpression(pattern: #"^##\s"#)
/// The "## Sessions" heading specifically.
private let rawSessionsSectionPattern = try? NSRegularExpression(pattern: #"^##\s+Sessions\s*$"#, options: .caseInsensitive)

private func matches(_ pattern: NSRegularExpression?, _ line: String) -> Bool {
    guard let pattern = pattern else { return false }
    return pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

/// Apply a model-level mutation, but produce the new markdown by splicing only the task lines
/// whose raw text changed back into `rawText`. Everything outside changed task lines is preserved
/// byte-for-byte. Returns nil if nothing changed (caller can skip the write).
///
/// Requires the mutation to preserve the count and ordering of task lines per session
/// (true for complete/focus/undo/normalize — they rewrite lines in place, never add or remove them).
public func editTodosPreservingFormat(
    rawText: String,
    mutate: (ProjectNotes) throws -> ProjectNotes
) throws -> String? {
    let original = try parseNotes(markdown: rawText)
    let updated = try mutate(original)

    let oldTodos = try parseTodos(notes: original)
    let newTodos = try parseTodos(notes: updated)

    // Map (sessionIndex, lineIndex) -> new raw line, only where it differs from the original.
    let oldByKey = Dictionary(
        oldTodos.map { ("\($0.sessionIndex):\($0.lineIndex)", $0.rawLine) },
        uniquingKeysWith: { first, _ in first }
    )
    var replacements: [String: String] = [:]
    for todo in newTodos {
        let key = "\(todo.sessionIndex):\(todo.lineIndex)"
        if let old = oldByKey[key], old != todo.rawLine {
            replacements[key] = todo.rawLine
        }
    }
    if replacements.isEmpty { return nil }

    return spliceTaskLines(rawText: rawText, replacements: replacements)
}

/// Walk the raw markdown the same way parseTodos indexes task lines (by session, then task-line order),
/// replacing only the lines named in `replacements`. All other lines — headings, callouts, blank lines,
/// frontmatter — are left exactly as they were.
private func spliceTaskLines(rawText: String, replacements: [String: String]) -> String {
    var lines = rawText.components(separatedBy: "\n")
    var inSessions = false
    var sessionIndex = -1
    var taskIndex = 0

    for n in lines.indices {
        let line = lines[n]
        if !inSessions {
            if matches(rawSessionsSectionPattern, line) { inSessions = true }
            continue
        }
        if matches(rawSessionHeadingPattern, line) {
            sessionIndex += 1
            taskIndex = 0
            continue
        }
        // A later "## " section ends the Sessions region (mirrors parseSessionsBlock's body boundary).
        if matches(rawSectionPattern, line) {
            inSessions = false
            continue
        }
        guard sessionIndex >= 0, matches(rawTaskPattern, line) else { continue }
        let key = "\(sessionIndex):\(taskIndex)"
        if let replacement = replacements[key] {
            lines[n] = replacement
        }
        taskIndex += 1
    }
    return lines.joined(separator: "\n")
}

// MARK: - Task insertion (format-preserving)
//
// `editTodosPreservingFormat` can only rewrite existing task lines 1:1. Adding a task needs a
// line *insertion*, so these helpers walk the raw markdown the same way parseTodos indexes task
// lines and splice a new line in at the right spot, leaving every other byte verbatim.

/// Where a new task sits relative to an anchor task.
public enum TaskInsertPosition {
    case before
    case after
    case child
}

/// Leading list prefix ("  - ", "- ", etc.) of a raw task line; falls back to "- ".
private func listPrefix(of line: String) -> String {
    guard let pattern = rawTaskPattern,
          let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let r1 = Range(m.range(at: 1), in: line) else {
        return "- "
    }
    return String(line[r1])
}

/// Build a new unchecked task line at the given list prefix, with an optional inline `due:`.
/// Mirrors the canonical order parseTodos round-trips: "<prefix>[ ] <text> due: <date>".
private func newTaskLine(prefix: String, text: String, due: String?) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let dueSuffix = (due?.isEmpty == false) ? " due: \(due!)" : ""
    return "\(prefix)[ ] \(trimmed)\(dueSuffix)"
}

/// Insert a new task relative to the task at (anchorSessionIndex, anchorLineIndex), preserving format.
/// before/after reuse the anchor's indent; child indents two spaces deeper. Returns the new markdown
/// and the (sessionIndex, lineIndex) of the inserted task, or nil if the anchor can't be located.
public func insertTaskRelative(
    rawText: String,
    anchorSessionIndex: Int,
    anchorLineIndex: Int,
    text: String,
    due: String?,
    position: TaskInsertPosition
) -> (rawText: String, sessionIndex: Int, lineIndex: Int)? {
    var lines = rawText.components(separatedBy: "\n")
    var inSessions = false
    var sessionIndex = -1
    var taskIndex = 0

    for n in lines.indices {
        let line = lines[n]
        if !inSessions {
            if matches(rawSessionsSectionPattern, line) { inSessions = true }
            continue
        }
        if matches(rawSessionHeadingPattern, line) {
            sessionIndex += 1
            taskIndex = 0
            continue
        }
        if matches(rawSectionPattern, line) {
            inSessions = false
            continue
        }
        guard sessionIndex >= 0, matches(rawTaskPattern, line) else { continue }
        if sessionIndex == anchorSessionIndex && taskIndex == anchorLineIndex {
            let prefix = position == .child ? "  " + listPrefix(of: line) : listPrefix(of: line)
            let inserted = newTaskLine(prefix: prefix, text: text, due: due)
            switch position {
            case .before:
                lines.insert(inserted, at: n)
                return (lines.joined(separator: "\n"), sessionIndex, taskIndex)
            case .after, .child:
                lines.insert(inserted, at: n + 1)
                return (lines.joined(separator: "\n"), sessionIndex, taskIndex + 1)
            }
        }
        taskIndex += 1
    }
    return nil
}

/// Leading-space count of a line (the task-indent depth; the notes convention is two-space steps).
private func leadingSpaces(_ line: String) -> Int {
    line.prefix { $0 == " " }.count
}

/// Wrap the task at (sessionIndex, lineIndex) in a new parent task: insert an unchecked parent line
/// at the task's own indent, then indent the task and its (deeper, contiguous) descendants two spaces
/// so they nest under it. The wrapped task keeps its checkbox, due, and focus marker verbatim (only
/// its indent changes), so focus stays on it. Returns the new markdown, or nil if the task can't be
/// located. Mirrors the Raycast "Wrap" command, extended to carry a task's subtree along.
public func wrapTaskPreservingFormat(
    rawText: String,
    sessionIndex targetSession: Int,
    lineIndex targetLine: Int,
    parentText: String
) -> String? {
    var lines = rawText.components(separatedBy: "\n")
    var inSessions = false
    var sessionIndex = -1
    var taskIndex = 0

    for n in lines.indices {
        let line = lines[n]
        if !inSessions {
            if matches(rawSessionsSectionPattern, line) { inSessions = true }
            continue
        }
        if matches(rawSessionHeadingPattern, line) {
            sessionIndex += 1
            taskIndex = 0
            continue
        }
        if matches(rawSectionPattern, line) {
            inSessions = false
            continue
        }
        guard sessionIndex >= 0, matches(rawTaskPattern, line) else { continue }
        if sessionIndex == targetSession && taskIndex == targetLine {
            let prefix = listPrefix(of: line)
            let indent = leadingSpaces(line)
            let parentLine = "\(prefix)[ ] \(parentText.trimmingCharacters(in: .whitespaces))"
            // Indent the target line, then every immediately following deeper task line (its subtree).
            var i = n
            while i < lines.count {
                if i == n {
                    lines[i] = "  " + lines[i]
                } else if matches(rawTaskPattern, lines[i]), leadingSpaces(lines[i]) > indent {
                    lines[i] = "  " + lines[i]
                } else {
                    break
                }
                i += 1
            }
            lines.insert(parentLine, at: n)
            return lines.joined(separator: "\n")
        }
        taskIndex += 1
    }
    return nil
}

/// Append a new task at the end of a session's task list (or right after its heading when the
/// session has no tasks yet), preserving format. Returns the new markdown and the (sessionIndex,
/// lineIndex) of the inserted task, or nil if the session can't be located.
public func appendTaskToSession(
    rawText: String,
    sessionIndex targetSession: Int,
    text: String,
    due: String?
) -> (rawText: String, sessionIndex: Int, lineIndex: Int)? {
    var lines = rawText.components(separatedBy: "\n")
    var inSessions = false
    var sessionIndex = -1
    var taskIndex = 0
    var headingLine: Int? = nil
    var lastTaskLine: Int? = nil
    var prefix = "- "

    for n in lines.indices {
        let line = lines[n]
        if !inSessions {
            if matches(rawSessionsSectionPattern, line) { inSessions = true }
            continue
        }
        if matches(rawSessionHeadingPattern, line) {
            sessionIndex += 1
            if sessionIndex == targetSession {
                headingLine = n
                taskIndex = 0
                lastTaskLine = nil
            } else if sessionIndex > targetSession {
                break
            }
            continue
        }
        if matches(rawSectionPattern, line) {
            if sessionIndex >= targetSession { break }
            inSessions = false
            continue
        }
        guard sessionIndex == targetSession, matches(rawTaskPattern, line) else { continue }
        lastTaskLine = n
        prefix = listPrefix(of: line)
        taskIndex += 1
    }

    guard let heading = headingLine else { return nil }
    // Tasks inherit the session's indent level (root); reuse the last task's prefix when present.
    let inserted = newTaskLine(prefix: lastTaskLine != nil ? prefix : "- ", text: text, due: due)
    let insertAt = (lastTaskLine ?? heading) + 1
    lines.insert(inserted, at: insertAt)
    return (lines.joined(separator: "\n"), targetSession, taskIndex)
}

// MARK: - Section-level splicing for `notes write`
//
// A full-document write (e.g. editing goals/learnings/summary from Raycast) arrives as a complete
// ProjectNotes. Rather than regenerate the file, compare each section against what's on disk and
// rewrite only the sections that actually changed — leaving frontmatter, untouched sections, the
// Sessions region, and all inter-section spacing verbatim.

private let summaryAnchor = try? NSRegularExpression(pattern: #"^>\s*\[!summary\]"#, options: .caseInsensitive)
private let problemAnchor = try? NSRegularExpression(pattern: #"^>\s*\[!question\]"#, options: .caseInsensitive)
private let goalsAnchor = try? NSRegularExpression(pattern: #"^>\s*\[!info\]\s*Goals"#, options: .caseInsensitive)
private let approachAnchor = try? NSRegularExpression(pattern: #"^>\s*\[!info\]\s*Approach"#, options: .caseInsensitive)
private let linksAnchor = try? NSRegularExpression(pattern: #"^##\s+Links\s*$"#, options: .caseInsensitive)
private let learningsAnchor = try? NSRegularExpression(pattern: #"^##\s+Learnings\s*$"#, options: .caseInsensitive)

/// Write a full ProjectNotes by splicing only the changed sections into `rawText`, preserving
/// everything else byte-for-byte. Returns nil when the change can't be spliced safely (a changed
/// section's anchor is missing, or the Sessions region changed) — the caller should fall back to
/// the full serializer so the change is never silently dropped.
public func writeNotesPreservingFormat(rawText: String, incoming: ProjectNotes) throws -> String? {
    let existing = try parseNotes(markdown: rawText)

    // Session/todo edits are handled by the surgical todo path; `notes write` shouldn't change them.
    // If they differ, splicing would drop the change — fall back to the full serializer.
    if existing.sessions != incoming.sessions { return nil }

    var lines = rawText.components(separatedBy: "\n")
    var ok = true

    // Process sections bottom-to-top so each splice leaves the anchors above it at stable indices.
    if existing.learnings != incoming.learnings {
        ok = replaceListItems(&lines, anchor: learningsAnchor, newItemLines: itemLines(serializeLearnings(incoming.learnings))) && ok
    }
    if existing.links != incoming.links {
        ok = replaceListItems(&lines, anchor: linksAnchor, newItemLines: itemLines(serializeLinks(incoming.links))) && ok
    }
    if existing.approach != incoming.approach {
        ok = replaceCalloutBody(&lines, anchor: approachAnchor, body: calloutContentLines(incoming.approach)) && ok
    }
    if existing.goals != incoming.goals {
        ok = replaceCalloutBody(&lines, anchor: goalsAnchor, body: serializeGoals(incoming.goals).components(separatedBy: "\n")) && ok
    }
    if existing.problem != incoming.problem {
        ok = replaceCalloutBody(&lines, anchor: problemAnchor, body: calloutContentLines(incoming.problem)) && ok
    }
    if existing.summary != incoming.summary {
        ok = replaceCalloutBody(&lines, anchor: summaryAnchor, body: calloutContentLines(incoming.summary)) && ok
    }
    if existing.title != incoming.title {
        if let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[i] = "# \(incoming.title)"
        } else {
            ok = false
        }
    }

    guard ok else { return nil }
    return lines.joined(separator: "\n")
}

/// Split a serializer's output string into its constituent lines, dropping the single trailing
/// newline some serializers append (so we don't introduce a spurious blank line).
private func itemLines(_ serialized: String) -> [String] {
    let trimmed = serialized.hasSuffix("\n") ? String(serialized.dropLast()) : serialized
    return trimmed.components(separatedBy: "\n")
}

/// Replace a callout's body lines (the `> ...` lines after the `> [!type] Label` header), keeping
/// the header line and everything outside the block untouched. Returns false if the anchor is absent.
private func replaceCalloutBody(_ lines: inout [String], anchor: NSRegularExpression?, body: [String]) -> Bool {
    guard let start = lines.firstIndex(where: { matches(anchor, $0) }) else { return false }
    var end = start + 1
    while end < lines.count, lines[end].hasPrefix(">") { end += 1 }
    lines.replaceSubrange((start + 1)..<end, with: body)
    return true
}

/// Replace just the list items under a `## Section` heading, preserving the blank lines between the
/// heading and the items and between the items and whatever follows. Returns false if the anchor is absent.
private func replaceListItems(_ lines: inout [String], anchor: NSRegularExpression?, newItemLines: [String]) -> Bool {
    guard let heading = lines.firstIndex(where: { matches(anchor, $0) }) else { return false }
    // The section's content runs until the next "## " heading or a callout line (or EOF).
    var boundary = heading + 1
    while boundary < lines.count, !matches(rawSectionPattern, lines[boundary]), !lines[boundary].hasPrefix(">") {
        boundary += 1
    }
    var itemsStart = heading + 1
    while itemsStart < boundary, lines[itemsStart].trimmingCharacters(in: .whitespaces).isEmpty { itemsStart += 1 }
    var itemsEnd = itemsStart
    while itemsEnd < boundary, !lines[itemsEnd].trimmingCharacters(in: .whitespaces).isEmpty { itemsEnd += 1 }
    lines.replaceSubrange(itemsStart..<itemsEnd, with: newItemLines)
    return true
}

/// Insert a new (empty) session heading at the top of the Sessions list, preserving all other
/// formatting. Returns nil if no "## Sessions" heading exists (caller should fall back).
public func sessionAddPreservingFormat(rawText: String, label: String, date: Date) -> String? {
    var lines = rawText.components(separatedBy: "\n")
    guard let sessionsLineIndex = lines.firstIndex(where: { matches(rawSessionsSectionPattern, $0) }) else {
        return nil
    }
    let sessionDate = formatSessionDate(date)
    let heading = label.isEmpty ? "### \(sessionDate)" : "### \(sessionDate) \(label)"

    // Insert one blank line, the heading, and (if the next line isn't already blank) a trailing
    // blank line so the new session is separated from whatever follows.
    var block = ["", heading]
    let nextIndex = sessionsLineIndex + 1
    if nextIndex < lines.count, !lines[nextIndex].isEmpty {
        block.append("")
    }
    lines.insert(contentsOf: block, at: nextIndex)
    return lines.joined(separator: "\n")
}
