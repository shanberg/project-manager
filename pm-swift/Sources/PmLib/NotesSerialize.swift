import Foundation

private func escapeCalloutLine(_ s: String) -> String {
    s.isEmpty ? "> " : "> \(s)"
}

private func serializeCallout(type: String, label: String, content: String) -> String {
    let lines = content.isEmpty ? [""] : content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let block = lines.map(escapeCalloutLine).joined(separator: "\n")
    return "> [!\(type)] \(label)\n\(block)"
}

/// Two spaces after the number (e.g. "> 1.  ") for round-trip consistency with parse (num regex).
private func serializeGoals(_ goals: [String]) -> String {
    var items = goals
    if items.count < 3 {
        items.append(contentsOf: [String](repeating: "", count: 3 - items.count))
    } else {
        items = Array(items.prefix(3))
    }
    return items.enumerated().map { "> \($0.offset + 1).  \($0.element)" }.joined(separator: "\n")
}

private func serializeLinks(_ entries: [LinkEntry]) -> String {
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

private func serializeLearnings(_ items: [String]) -> String {
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

public func serializeNotes(_ notes: ProjectNotes) -> String {
    // #region agent log
    debugLog(location: "NotesSerialize.swift:serializeNotes", message: "Serializing notes to markdown", data: ["title": notes.title], hypothesisId: "D")
    // #endregion
    var parts: [String] = []
    parts.append("# \(notes.title)\n")
    parts.append(serializeCallout(type: "summary", label: "Summary", content: notes.summary))
    parts.append("\n")
    parts.append(serializeCallout(type: "question", label: "Problem", content: notes.problem))
    parts.append("\n")
    parts.append("> [!info] Goals\n\(serializeGoals(notes.goals))")
    parts.append("\n")
    parts.append(serializeCallout(type: "info", label: "Approach", content: notes.approach))
    parts.append("\n")
    parts.append("## Links\n\n")
    parts.append(serializeLinks(notes.links))
    parts.append("\n\n## Learnings\n\n")
    parts.append(serializeLearnings(notes.learnings))
    parts.append("\n\n## Sessions\n\n")
    parts.append(serializeSessions(notes.sessions))
    return parts.joined()
}
