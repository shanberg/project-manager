import Foundation

private func escapeCalloutLine(_ s: String) -> String {
    s.isEmpty ? "> " : "> \(s)"
}

private func serializeCallout(type: String, label: String, content: String) -> String {
    let block = calloutContentLines(content).joined(separator: "\n")
    return "> [!\(type)] \(label)\n\(block)"
}

/// Content lines of a callout (the `> ...` body lines, excluding the `> [!type] Label` header).
/// Empty content yields a single `> ` line. Reused by format-preserving section splicing.
func calloutContentLines(_ content: String) -> [String] {
    let lines = content.isEmpty ? [""] : content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return lines.map(escapeCalloutLine)
}

/// Two spaces after the number (e.g. "> 1.  ") for round-trip consistency with parse (num regex).
func serializeGoals(_ goals: [String]) -> String {
    var items = goals
    if items.count < 3 {
        items.append(contentsOf: [String](repeating: "", count: 3 - items.count))
    } else {
        items = Array(items.prefix(3))
    }
    return items.enumerated().map { "> \($0.offset + 1).  \($0.element)" }.joined(separator: "\n")
}

func serializeLinks(_ entries: [LinkEntry]) -> String {
    if entries.isEmpty { return "- \n" }
    let parts = entries.compactMap { e -> String? in
        if let children = e.children, !children.isEmpty {
            let childLines = children.compactMap { c in c.url.map { "    - \($0)" } }
            return e.label.map { "- \($0)\n\(childLines.joined(separator: "\n"))" }
        }
        if let label = e.label, let url = e.url { return "- \(label): \(url)" }
        if let url = e.url { return "- \(url)" }
        return "- "
    }
    return parts.joined(separator: "\n").isEmpty ? "- \n" : parts.joined(separator: "\n") + "\n"
}

func serializeLearnings(_ items: [String]) -> String {
    let list = items.isEmpty ? [""] : items
    return list.map { "- \($0)" }.joined(separator: "\n")
}

private func serializeSessions(_ sessions: [Session]) -> String {
    if sessions.isEmpty { return "" }
    return sessions.map { s in
        let heading = s.label.isEmpty ? "### \(s.date)" : "### \(s.date) \(s.label)"
        return s.body.isEmpty ? heading : "\(heading)\n\n\(s.body)"
    }.joined(separator: "\n\n")
}

/// Write a whole notes document from the model.
///
/// The header is whatever `kind` says it is, plus anything already written that the kind leaves out.
/// The first half of that is the rule — an Area has no Problem and no Approach and shouldn't grow
/// empty ones. The second half is what keeps the rule from destroying anything: this function is the
/// fallback the format-preserving writer drops to, so a Problem somebody typed into an Area by hand
/// in Obsidian would otherwise disappear on the next unrelated edit, with nothing to say it had.
///
/// Which means omission is a *write-side* rule and not a parsing one. `parseNotes` reads every
/// section it finds, for both kinds, and always has.
public func serializeNotes(_ notes: ProjectNotes, kind: ProjectKind) -> String {
    var parts: [String] = []
    parts.append("# \(notes.title)\n")
    // allCases is in document order, so this writes the sections where a reader expects them
    // regardless of what order the kind happens to list them in.
    for section in HeaderSection.allCases where kind.headerSections.contains(section) || !notes.isEmpty(section) {
        switch notes.content(section) {
        case .prose(let text):
            parts.append(serializeCallout(type: section.calloutType, label: section.label, content: text))
        case .numbered(let items):
            parts.append("> [!\(section.calloutType)] \(section.label)\n\(serializeGoals(items))")
        }
        parts.append("\n")
    }
    parts.append("## Links\n\n")
    parts.append(serializeLinks(notes.links))
    parts.append("\n\n## Learnings\n\n")
    parts.append(serializeLearnings(notes.learnings))
    parts.append("\n\n## Sessions\n\n")
    parts.append(serializeSessions(notes.sessions))
    return parts.joined()
}
