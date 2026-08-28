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

/// Unwrap (dissolve) the parent task at (sessionIndex, lineIndex): delete the parent line and promote
/// its subtree — the contiguous run of deeper task lines immediately following it — one indent level
/// (two spaces) shallower, so the former children take the parent's position and depth. Returns the new
/// markdown, or nil if the task can't be located or has no children (a leaf — nothing to dissolve).
/// Inverse of `wrapTaskPreservingFormat`; the caller handles moving focus off the removed parent.
public func unwrapTaskPreservingFormat(
    rawText: String,
    sessionIndex targetSession: Int,
    lineIndex targetLine: Int
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
            let indent = leadingSpaces(line)
            // The subtree is the contiguous run of deeper task lines right after the parent.
            var end = n + 1
            while end < lines.count, matches(rawTaskPattern, lines[end]), leadingSpaces(lines[end]) > indent {
                end += 1
            }
            guard end > n + 1 else { return nil }  // leaf task — nothing to dissolve
            // Promote each descendant two spaces shallower (their relative nesting is preserved),
            // then drop the parent line so the first child lands at the parent's old position.
            for i in (n + 1)..<end {
                lines[i] = String(lines[i].dropFirst(2))
            }
            lines.remove(at: n)
            return lines.joined(separator: "\n")
        }
        taskIndex += 1
    }
    return nil
}

// MARK: - Subtree move (format-preserving)
//
// Drag-to-reorder in the panel moves a whole subtree (a task plus its contiguous deeper descendants)
// to a precise slot — a document position (an insertion gap) plus an explicit target depth. The block
// travels verbatim (checkbox, due, focus marker included) and is only re-indented so its root lands at
// the chosen depth; descendants keep their relative nesting. The panel resolves the drop's Y (which
// gap) and X (which depth, clamped to the legal range at that gap) into these arguments.

/// The 0-based line number of the task at (sessionIndex, taskIndex), indexed exactly as parseTodos
/// walks the Sessions region, or nil if it can't be located.
private func rawTaskLineNumber(_ lines: [String], sessionIndex targetSession: Int, taskIndex targetTask: Int) -> Int? {
    var inSessions = false
    var sessionIndex = -1
    var taskIndex = 0
    for n in lines.indices {
        let line = lines[n]
        if !inSessions {
            if matches(rawSessionsSectionPattern, line) { inSessions = true }
            continue
        }
        if matches(rawSessionHeadingPattern, line) { sessionIndex += 1; taskIndex = 0; continue }
        if matches(rawSectionPattern, line) { inSessions = false; continue }
        guard sessionIndex >= 0, matches(rawTaskPattern, line) else { continue }
        if sessionIndex == targetSession && taskIndex == targetTask { return n }
        taskIndex += 1
    }
    return nil
}

/// The half-open line range [start, end) of the subtree rooted at `start`: the root line plus the
/// contiguous run of deeper task lines immediately following it (the same subtree rule wrap/unwrap use).
private func rawSubtreeRange(_ lines: [String], start: Int) -> Range<Int> {
    let indent = leadingSpaces(lines[start])
    var end = start + 1
    while end < lines.count, matches(rawTaskPattern, lines[end]), leadingSpaces(lines[end]) > indent {
        end += 1
    }
    return start..<end
}

/// Move the subtree rooted at the source task to a precise slot: immediately after the anchor task's
/// own line (`insertAfterAnchor`) or immediately before it, with the subtree's root re-indented to
/// `depth` (× two spaces). Descendants ride along at their relative nesting. Format-preserving — the
/// moved lines are spliced verbatim apart from the uniform indent shift. Returns the new markdown, or
/// nil if either task can't be located or the anchor is the source itself or one of its descendants
/// (an illegal drop inside the moved subtree). Moves may cross session boundaries — the destination
/// session is whichever the anchor belongs to. The caller is responsible for passing a `depth` that's
/// legal at the slot (the panel clamps to the [rowBelow.depth ... rowAbove.depth+1] range).
public func moveSubtreePreservingFormat(
    rawText: String,
    sourceSessionIndex: Int,
    sourceLineIndex: Int,
    anchorSessionIndex: Int,
    anchorLineIndex: Int,
    insertAfterAnchor: Bool,
    depth: Int
) -> String? {
    let lines = rawText.components(separatedBy: "\n")
    guard let sourceStart = rawTaskLineNumber(lines, sessionIndex: sourceSessionIndex, taskIndex: sourceLineIndex),
          let anchorLine = rawTaskLineNumber(lines, sessionIndex: anchorSessionIndex, taskIndex: anchorLineIndex)
    else { return nil }

    let sourceRange = rawSubtreeRange(lines, start: sourceStart)
    // Can't drop the subtree into itself or one of its own descendants.
    if sourceRange.contains(anchorLine) { return nil }

    let insertAt = insertAfterAnchor ? anchorLine + 1 : anchorLine
    return splicedSubtree(lines, sourceRange: sourceRange, insertAt: insertAt, depth: depth)
        .joined(separator: "\n")
}

/// Move the subtree at (sourceSessionIndex, sourceLineIndex) to the end of a session's task list,
/// re-rooted at depth 0. This is the destination a drop into a session with no tasks names: there is
/// no anchor task there to sit beside, only the session itself.
///
/// Where it lands inside the session is the rule a newly added task already follows — after the last
/// task if there is one, else after the session's leading prose so the note isn't stranded below the
/// list, else right under the heading. A session that reads as empty on screen isn't always empty in
/// the file (the task being dragged is still in it until the splice), which is why this appends rather
/// than assuming the session is bare.
public func moveSubtreeToSessionPreservingFormat(
    rawText: String,
    sourceSessionIndex: Int,
    sourceLineIndex: Int,
    targetSessionIndex: Int
) -> String? {
    let lines = rawText.components(separatedBy: "\n")
    guard let sourceStart = rawTaskLineNumber(lines, sessionIndex: sourceSessionIndex, taskIndex: sourceLineIndex),
          let slot = rawSessionAppendSlot(lines, sessionIndex: targetSessionIndex)
    else { return nil }
    return splicedSubtree(lines, sourceRange: rawSubtreeRange(lines, start: sourceStart),
                          insertAt: slot.line, depth: 0)
        .joined(separator: "\n")
}

/// Lift the block at `sourceRange` out of `lines` and re-insert it at `insertAt`, re-indented so its
/// root sits at `depth` and the nesting inside it is preserved.
private func splicedSubtree(_ lines: [String], sourceRange: Range<Int>, insertAt: Int, depth: Int) -> [String] {
    var lines = lines
    let sourceIndent = leadingSpaces(lines[sourceRange.lowerBound])
    let newRootIndent = max(0, depth) * 2

    // Re-indent every block line by the same delta so relative nesting is preserved. A negative delta
    // can't underflow: each line's indent is ≥ sourceIndent, and newRootIndent ≥ 0.
    let block = Array(lines[sourceRange])
    let delta = newRootIndent - sourceIndent
    let reindented = block.map { line -> String in
        delta >= 0 ? String(repeating: " ", count: delta) + line : String(line.dropFirst(-delta))
    }

    // Drop the source block, then insert the re-indented copy. Insertion points at or after the
    // removed block shift left by its length; points before it are unaffected.
    let adjustedInsert = insertAt >= sourceRange.upperBound ? insertAt - block.count : insertAt
    lines.removeSubrange(sourceRange)
    lines.insert(contentsOf: reindented, at: adjustedInsert)
    return lines
}

/// Delete the subtree rooted at the task at (sessionIndex, lineIndex): its own line plus the
/// contiguous run of deeper task lines right after it — the same subtree rule wrap/unwrap/move use,
/// so a task never leaves orphaned children behind. Format-preserving: nothing else in the document
/// is touched, including any prose interleaved elsewhere in the session. Returns the new markdown, or
/// nil if the task can't be located. Focus is *not* repaired here — `deleteTodo` does that once it
/// knows whether the removed block carried the marker.
public func deleteSubtreePreservingFormat(
    rawText: String,
    sessionIndex: Int,
    lineIndex: Int
) -> String? {
    var lines = rawText.components(separatedBy: "\n")
    guard let start = rawTaskLineNumber(lines, sessionIndex: sessionIndex, taskIndex: lineIndex) else {
        return nil
    }
    lines.removeSubrange(rawSubtreeRange(lines, start: start))
    return lines.joined(separator: "\n")
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
    guard let slot = rawSessionAppendSlot(lines, sessionIndex: targetSession) else { return nil }
    // Tasks inherit the session's indent level (root); reuse the last task's prefix when present.
    lines.insert(newTaskLine(prefix: slot.prefix, text: text, due: due), at: slot.line)
    return (lines.joined(separator: "\n"), targetSession, slot.taskIndex)
}

/// Where a task appended to a session goes, and what it should look like when it gets there. Shared
/// by "add a task to this session" and by a drag dropped on the session itself, so the two can't
/// drift on the one question they both have to answer.
private struct SessionAppendSlot {
    /// The line the appended task is inserted at.
    let line: Int
    /// Its `lineIndex` within the session once inserted.
    let taskIndex: Int
    /// The list prefix to match — the last task's, or `"- "` in a session with none.
    let prefix: String
}

/// Resolve `sessionIndex`'s append slot: after its last task if it has one, otherwise after its
/// leading prose (its note), so the note isn't stranded below the list, otherwise right after the
/// heading. Nil when the session can't be located.
private func rawSessionAppendSlot(_ lines: [String], sessionIndex targetSession: Int) -> SessionAppendSlot? {
    var inSessions = false
    var sessionIndex = -1
    var taskIndex = 0
    var headingLine: Int? = nil
    var lastTaskLine: Int? = nil
    /// Last non-blank prose line of the target session (only meaningful before its first task): a new
    /// first task lands after it, so the session's leading-prose note stays above the task list.
    var lastProseLine: Int? = nil
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
                lastProseLine = nil
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
        guard sessionIndex == targetSession else { continue }
        if matches(rawTaskPattern, line) {
            lastTaskLine = n
            prefix = listPrefix(of: line)
            taskIndex += 1
        } else if lastTaskLine == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty {
            lastProseLine = n
        }
    }

    guard let heading = headingLine else { return nil }
    return SessionAppendSlot(line: (lastTaskLine ?? lastProseLine ?? heading) + 1,
                             taskIndex: taskIndex,
                             prefix: lastTaskLine != nil ? prefix : "- ")
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
/// Start of any callout block (`> [!type] ...`). A callout's body ends here — the next callout's
/// header — even when there's no blank line between the two, so replacing one body can't run into the
/// next callout.
private let rawCalloutStartPattern = try? NSRegularExpression(pattern: #"^>\s*\[!"#)

/// Write a full ProjectNotes by splicing only the changed sections into `rawText`, preserving
/// everything else byte-for-byte. Returns nil when the change can't be spliced safely (a changed
/// section's anchor is missing, or the Sessions region changed) — the caller should fall back to
/// the full serializer so the change is never silently dropped.
public func writeNotesPreservingFormat(rawText: String, incoming: ProjectNotes,
                                       kind: ProjectKind) throws -> String? {
    let existing = try parseNotes(markdown: rawText)

    // A write may not *introduce* a section this kind doesn't have. Note the third clause: a section
    // already written into the document is left alone, because the serializer deliberately preserves a
    // non-empty omitted section — that's what keeps a Problem somebody typed into an area by hand in
    // Obsidian from vanishing. What that protection must not become is a way in.
    //
    // It throws rather than returning nil. Nil means "can't splice this, fall back to the full
    // serializer", and the full serializer would then write the section for exactly the reason above —
    // so a refusal expressed as nil would be a refusal that wrote the thing anyway.
    for section in HeaderSection.allCases
    where !kind.headerSections.contains(section) && !incoming.isEmpty(section) && existing.isEmpty(section) {
        throw PmError.sectionNotApplicable(kind: kind.rawValue, section: section.label)
    }

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
    // The body runs to the next non-`>` line OR the next callout header — callouts can abut with no
    // blank line between them (the default template does), so a bare `hasPrefix(">")` scan would run
    // straight through the following callout and overwrite it.
    var end = start + 1
    while end < lines.count, lines[end].hasPrefix(">"), !matches(rawCalloutStartPattern, lines[end]) {
        end += 1
    }
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

// MARK: - Session-level edits (format-preserving)
//
// The panel surfaces sessions (the dated "### ..." entries under "## Sessions") as first-class
// notes: rename their label, delete an empty one, and write an editable prose body. A session's
// "note" is its *leading prose* — the lines between the heading and its first task line — so the
// task list underneath is never disturbed. These helpers walk the Sessions region with the same
// indexing parseSessionsBlock/parseTodos use, and splice only the affected lines.

/// The 0-based line number of the session heading at `sessionIndex` (indexed as parseSessionsBlock
/// walks the Sessions region), or nil if there aren't that many sessions.
private func rawSessionHeadingLineNumber(_ lines: [String], sessionIndex targetSession: Int) -> Int? {
    var inSessions = false
    var sessionIndex = -1
    for n in lines.indices {
        let line = lines[n]
        if !inSessions {
            if matches(rawSessionsSectionPattern, line) { inSessions = true }
            continue
        }
        if matches(rawSessionHeadingPattern, line) {
            sessionIndex += 1
            if sessionIndex == targetSession { return n }
            continue
        }
        if matches(rawSectionPattern, line) { return nil }  // ran past the Sessions region
    }
    return nil
}

/// The 0-based line numbers of every session heading, in document order.
private func rawSessionHeadingLineNumbers(_ lines: [String]) -> [Int] {
    var inSessions = false
    var headings: [Int] = []
    for n in lines.indices {
        let line = lines[n]
        if !inSessions {
            if matches(rawSessionsSectionPattern, line) { inSessions = true }
            continue
        }
        if matches(rawSessionHeadingPattern, line) { headings.append(n); continue }
        if matches(rawSectionPattern, line) { break }  // ran past the Sessions region
    }
    return headings
}

/// The end (exclusive) of the session whose heading is at `headingLine`: the next session heading or
/// "## " section line, or lines.count. Mirrors parseSessionsBlock's body boundary.
private func rawSessionEnd(_ lines: [String], headingLine: Int) -> Int {
    var n = headingLine + 1
    while n < lines.count, !matches(rawSessionHeadingPattern, lines[n]), !matches(rawSectionPattern, lines[n]) {
        n += 1
    }
    return n
}

/// The leading prose of a session body: the lines before its first task line, trimmed. Empty when
/// the body starts with a task (or is blank). Used by the panel to render/seed a session's editable
/// note; prose that appears *after* a task is preserved on disk but not surfaced here.
public func leadingSessionProse(body: String) -> String {
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var prose: [String] = []
    for line in lines {
        if matches(rawTaskPattern, line) { break }
        prose.append(line)
    }
    return prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Set (create/replace/clear) a session's leading-prose note, preserving format. The region between
/// the heading and the session's first task line (or the session end, when it has no tasks) is
/// rewritten to a canonical block — a blank line, the prose, and a trailing blank when a task or
/// another heading follows — so exactly one blank separates heading/prose/tasks. Empty `prose`
/// removes the note. Everything from the first task onward is left byte-for-byte. Returns nil if the
/// session can't be located.
public func setSessionNotePreservingFormat(rawText: String, sessionIndex: Int, prose: String) -> String? {
    var lines = rawText.components(separatedBy: "\n")
    guard let heading = rawSessionHeadingLineNumber(lines, sessionIndex: sessionIndex) else { return nil }
    let end = rawSessionEnd(lines, headingLine: heading)

    // The leading-prose region ends at the session's first task line, else at the session end.
    var firstTask: Int? = nil
    var n = heading + 1
    while n < end {
        if matches(rawTaskPattern, lines[n]) { firstTask = n; break }
        n += 1
    }
    let regionEnd = firstTask ?? end
    // A following task, or another heading/section after this session, needs a blank line before it.
    let followed = firstTask != nil || end < lines.count

    let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
    var replacement: [String] = []
    if trimmed.isEmpty {
        if followed { replacement = [""] }
    } else {
        replacement = [""] + trimmed.components(separatedBy: "\n")
        if followed { replacement.append("") }
    }
    lines.replaceSubrange((heading + 1)..<regionEnd, with: replacement)
    return lines.joined(separator: "\n")
}

/// Append `prose` to the note of the current session, starting one when the project hasn't got one
/// for `date` — or has been left alone past `sessionIdleWindow`, which makes this note the beginning
/// of a new sitting rather than a late addition to the last one (see `SessionWindow.swift`). Returns
/// the updated text, or nil if the session can't be located and couldn't be added (no `## Sessions`
/// heading to splice into).
///
/// The note is appended rather than replaced — a session's note is a running log, so a second entry
/// joins the first under a blank line. The prose goes through the same sanitizing as any other session
/// note (see `commitSessionNotePreservingFormat`), so pasted headings and checkboxes can't break the
/// document.
public func appendSessionNotePreservingFormat(rawText: String, prose: String, lastEdited: Date? = nil,
                                              date: Date = Date()) throws -> String? {
    let addition = prose.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !addition.isEmpty else { return rawText }

    guard let current = try currentSessionPreservingFormat(rawText: rawText, lastEdited: lastEdited,
                                                           now: date) else { return nil }
    let notes = try parseNotes(markdown: current.rawText)
    guard current.sessionIndex < notes.sessions.count else { return nil }

    let existing = leadingSessionProse(body: notes.sessions[current.sessionIndex].body)
    let combined = existing.isEmpty ? addition : existing + "\n\n" + addition
    return commitSessionNotePreservingFormat(rawText: current.rawText,
                                             sessionIndex: current.sessionIndex, prose: combined)
}

/// Rename a session's label (the trailing text after the date), preserving format. The heading line
/// is rebuilt from its captured date parts + the new label — `"### <date>"` or `"### <date> <label>"`,
/// matching the parser exactly — so the date and the session's body are untouched. An empty label
/// removes the trailing text. Returns nil if the session can't be located.
public func renameSessionPreservingFormat(rawText: String, sessionIndex: Int, label: String) -> String? {
    var lines = rawText.components(separatedBy: "\n")
    guard let heading = rawSessionHeadingLineNumber(lines, sessionIndex: sessionIndex),
          let pattern = rawSessionHeadingPattern else { return nil }
    let line = lines[heading]
    guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let r1 = Range(m.range(at: 1), in: line),
          let r2 = Range(m.range(at: 2), in: line),
          let r3 = Range(m.range(at: 3), in: line),
          let r4 = Range(m.range(at: 4), in: line) else { return nil }
    let date = "\(line[r1]), \(line[r2]) \(line[r3]), \(line[r4])"
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    lines[heading] = trimmed.isEmpty ? "### \(date)" : "### \(date) \(trimmed)"
    return lines.joined(separator: "\n")
}

/// If `line` is an ATX heading shallower than H4 (one to three `#`), demote it to H4 so it nests
/// *within* a session (whose heading is H3) instead of colliding with the document's structural
/// markers — a two-hash line is the `## Section` boundary and a three-hash line can be a `### <date>`
/// session heading. Returns nil for non-headings and for H4–H6 (already session-safe).
private func demotedHeading(_ line: String) -> String? {
    let hashes = line.prefix { $0 == "#" }.count
    guard hashes >= 1, hashes <= 3 else { return nil }
    let after = line.dropFirst(hashes)
    guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }  // ATX needs a space
    return String(repeating: "#", count: 4) + after
}

/// Normalize freeform note text so it can live safely as a session's prose without altering document
/// structure. Two transforms, matching the app's contract that a note is prose sitting above a session's
/// task list:
/// - **Task checkboxes graduate**: every `- [ ] …` / `- [x] …` line is pulled out of the prose and
///   returned separately (the caller appends them to the session's task list). Their relative
///   indentation is preserved, shifted so the shallowest sits at the root.
/// - **Headings clamp**: any heading shallower than H4 is demoted to H4, so a stray `##`/`### <date>`
///   can't end the Sessions region or split the session.
/// Everything else (prose, plain bullets, callouts, H4–H6, `#` is clamped too) round-trips verbatim.
public func sanitizeSessionNoteProse(_ prose: String) -> (prose: String, taskLines: [String]) {
    var proseLines: [String] = []
    var taskLines: [String] = []
    for line in prose.components(separatedBy: "\n") {
        if matches(rawTaskPattern, line) {
            taskLines.append(line)
        } else if let demoted = demotedHeading(line) {
            proseLines.append(demoted)
        } else {
            proseLines.append(line)
        }
    }
    if !taskLines.isEmpty {
        let minIndent = taskLines.map { leadingSpaces($0) }.min() ?? 0
        if minIndent > 0 { taskLines = taskLines.map { String($0.dropFirst(minIndent)) } }
    }
    let cleanProse = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (cleanProse, taskLines)
}

/// Commit a session note the way the panel editor does: sanitize the freeform text (`sanitizeSessionNoteProse`)
/// so headings can't break structure and any typed checkboxes graduate into real tasks appended to the
/// session's task list, then splice the clean prose and the (existing + graduated) tasks back into the
/// session, preserving everything outside it. Idempotent once the editor adopts the returned clean prose
/// (no checkboxes remain to re-extract). Returns nil if the session can't be located.
public func commitSessionNotePreservingFormat(rawText: String, sessionIndex: Int, prose: String) -> String? {
    let (cleanProse, taskLines) = sanitizeSessionNoteProse(prose)
    var lines = rawText.components(separatedBy: "\n")
    guard let heading = rawSessionHeadingLineNumber(lines, sessionIndex: sessionIndex) else { return nil }
    let end = rawSessionEnd(lines, headingLine: heading)
    let bodyLines = Array(lines[(heading + 1)..<end])
    let firstTaskIdx = bodyLines.firstIndex { matches(rawTaskPattern, $0) }

    // The session's existing tasks (and any trailing lines) are preserved verbatim; trim surrounding
    // blank lines so the joins below normalize to a single blank.
    var tail = firstTaskIdx.map { Array(bodyLines[$0...]) } ?? []
    while tail.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { tail.removeFirst() }
    while tail.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { tail.removeLast() }

    var region: [String] = []
    if !cleanProse.isEmpty {
        region.append("")
        region.append(contentsOf: cleanProse.components(separatedBy: "\n"))
    }
    let tasks = tail + taskLines   // existing tasks, then the newly-graduated ones
    if !tasks.isEmpty {
        region.append("")
        region.append(contentsOf: tasks)
    }
    if end < lines.count { region.append("") }   // one blank before a following heading/section

    lines.replaceSubrange((heading + 1)..<end, with: region)
    return lines.joined(separator: "\n")
}

/// Join edited lines back into a document, keeping whether it ended with a newline.
///
/// `components(separatedBy: "\n")` turns a trailing newline into a final empty element, so a transform
/// that removes lines *to the end of the file* takes that element with them and the document silently
/// loses its last byte. Every other transform here splices somewhere in the middle and never meets the
/// problem — which is why this went unnoticed until deleting the last session left a file with no
/// final newline.
///
/// A format-preserving edit must not change whether a file ends with one. It is a byte nobody asked to
/// change, it shows up in every diff of a vault kept in version control, and "preserving format" has
/// to mean the whole file or it doesn't mean much.
private func joinedPreservingFinalNewline(_ lines: [String], of original: String) -> String {
    let joined = lines.joined(separator: "\n")
    guard original.hasSuffix("\n"), !joined.hasSuffix("\n") else { return joined }
    return joined + "\n"
}

/// Delete a session — its heading and whole body region — preserving format. When deleting the last
/// session, also drops the blank line that separated it from the previous one so the file doesn't end
/// on a dangling blank. Returns nil if the session can't be located.
///
/// Deliberately raw about tasks: it removes the region it is given, whatever is in it. Refusing a
/// session that still holds tasks is `session.delete`'s rule, applied at the API boundary where the
/// refusal has a message to carry — see `ApiDispatch`. Keeping it out of here leaves the primitive
/// usable by anything that means to remove a session and its contents together.
public func deleteSessionPreservingFormat(rawText: String, sessionIndex: Int) -> String? {
    var lines = rawText.components(separatedBy: "\n")
    guard let heading = rawSessionHeadingLineNumber(lines, sessionIndex: sessionIndex) else { return nil }
    let end = rawSessionEnd(lines, headingLine: heading)
    var start = heading
    if end >= lines.count, start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
        start -= 1
    }
    lines.removeSubrange(start..<end)
    return joinedPreservingFinalNewline(lines, of: rawText)
}

/// Delete every *empty* session — one whose body holds nothing but blank lines, so no note and no
/// tasks — preserving format. Sessions with any content at all are left untouched, so this can never
/// take prose or tasks with it. Returns nil when there's nothing to prune, so the caller can skip the
/// write. Sessions are walked back-to-front: each deletion only shifts lines *after* the headings
/// still to be examined.
public func pruneEmptySessionsPreservingFormat(rawText: String) -> (rawText: String, removed: Int)? {
    var lines = rawText.components(separatedBy: "\n")
    var removed = 0
    for heading in rawSessionHeadingLineNumbers(lines).reversed() {
        let end = rawSessionEnd(lines, headingLine: heading)
        let hasContent = lines[(heading + 1)..<end].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if hasContent { continue }
        var start = heading
        if end >= lines.count, start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            start -= 1
        }
        lines.removeSubrange(start..<end)
        removed += 1
    }
    return removed > 0 ? (joinedPreservingFinalNewline(lines, of: rawText), removed) : nil
}

// MARK: - Pasting a block of tasks

/// One task in a block being pasted or dropped into a project.
///
/// `depth` is relative to the block, not to the document: the shallowest line in a pasted selection is
/// depth 0 whatever it was indented to where it came from, and everything else keeps its offset from
/// that. Which document depth the block lands at is the insertion's business, not the block's.
public struct PastedTask: Equatable, Sendable {
    public var depth: Int
    public var text: String
    public var due: String?
    public var checked: Bool

    public init(depth: Int, text: String, due: String? = nil, checked: Bool = false) {
        self.depth = depth
        self.text = text
        self.due = due
        self.checked = checked
    }
}

/// Render a block as task lines at `rootIndent` spaces, in `prefix`'s list style.
private func taskBlockLines(_ block: [PastedTask], rootIndent: Int, prefix: String) -> [String] {
    // The prefix carries the source line's own indent, which is not the indent we want — the block's
    // is computed per line. Strip it back to the bare marker ("- ", "* ", "1. ").
    let marker = prefix.drop { $0 == " " }
    return block.map { task in
        let indent = String(repeating: " ", count: rootIndent + max(0, task.depth) * 2)
        let box = task.checked ? "[x]" : "[ ]"
        let text = task.text.trimmingCharacters(in: .whitespaces)
        let dueSuffix = (task.due?.isEmpty == false) ? " due: \(task.due!)" : ""
        return "\(indent)\(marker)\(box) \(text)\(dueSuffix)"
    }
}

/// Insert `block` immediately after the whole subtree of the task at (anchorSessionIndex,
/// anchorLineIndex), with the block's root at the anchor's own depth.
///
/// After the subtree rather than after the anchor's line, which is where `insertTaskRelative` puts a
/// single task: a paste of several lines dropped between a task and its children would read as having
/// been adopted by it. A block goes after the thing you pasted onto, entire.
///
/// One splice for the whole block, so a paste is one write and one undo step — a batch a person made
/// in one gesture should come back in one. That is also why this exists rather than the app calling
/// `task.add` per line: N contract calls would be N undo steps, and after the first one the app's
/// in-memory tasks no longer describe the document it would have to anchor the second against.
public func insertTaskBlockPreservingFormat(
    rawText: String,
    anchorSessionIndex: Int,
    anchorLineIndex: Int,
    block: [PastedTask]
) -> String? {
    guard !block.isEmpty else { return nil }
    var lines = rawText.components(separatedBy: "\n")
    guard let anchor = rawTaskLineNumber(lines, sessionIndex: anchorSessionIndex,
                                         taskIndex: anchorLineIndex) else { return nil }
    let range = rawSubtreeRange(lines, start: anchor)
    let rendered = taskBlockLines(block, rootIndent: leadingSpaces(lines[anchor]),
                                  prefix: listPrefix(of: lines[anchor]))
    lines.insert(contentsOf: rendered, at: range.upperBound)
    return lines.joined(separator: "\n")
}

/// Append `block` at the end of a session's task list — what a paste means with no task to land beside.
/// Lands in the same slot a newly added task would: after the last task, else after the session's
/// leading prose, else right under the heading.
public func appendTaskBlockToSession(
    rawText: String,
    sessionIndex: Int,
    block: [PastedTask]
) -> String? {
    guard !block.isEmpty else { return nil }
    var lines = rawText.components(separatedBy: "\n")
    guard let slot = rawSessionAppendSlot(lines, sessionIndex: sessionIndex) else { return nil }
    lines.insert(contentsOf: taskBlockLines(block, rootIndent: 0, prefix: slot.prefix), at: slot.line)
    return lines.joined(separator: "\n")
}
