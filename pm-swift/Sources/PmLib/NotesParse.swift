import Foundation

private func compileRegex(_ pattern: String, options: NSRegularExpression.Options = []) throws -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        throw PmError.notesRegexError(pattern: pattern)
    }
}

private struct NotesPatterns {
    let sessionHeading: NSRegularExpression
    let linkLine: NSRegularExpression
    let nestedLink: NSRegularExpression
    let calloutStart: NSRegularExpression
    let goals: NSRegularExpression
    let num: NSRegularExpression
    let url: NSRegularExpression
    let learning: NSRegularExpression
    let section: NSRegularExpression
    let summary: NSRegularExpression
    let problem: NSRegularExpression
    let approach: NSRegularExpression
    let linksSection: NSRegularExpression
    let learningsSection: NSRegularExpression
    let sessionsSection: NSRegularExpression

    init() throws {
        sessionHeading = try compileRegex(#"^###\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2}),\s+(\d{4})(?:\s+(.*))?$"#)
        linkLine = try compileRegex(#"^\s*-\s+(.+)$"#)
        nestedLink = try compileRegex(#"^\s{4}-\s+(.+)$"#)
        calloutStart = try compileRegex(#"^>\s*\[!"#)
        goals = try compileRegex(#"^>\s*\[!info\]\s*Goals"#, options: .caseInsensitive)
        num = try compileRegex(#"^\d+\.\s*(.*)$"#)
        url = try compileRegex(#"^https?://"#)
        learning = try compileRegex(#"^\s*-\s+(.*)$"#)
        section = try compileRegex(#"^##\s"#)
        summary = try compileRegex(#"^>\s*\[!summary\]"#, options: .caseInsensitive)
        problem = try compileRegex(#"^>\s*\[!question\]"#, options: .caseInsensitive)
        approach = try compileRegex(#"^>\s*\[!info\]\s*Approach"#, options: .caseInsensitive)
        linksSection = try compileRegex(#"^##\s+Links\s*$"#, options: .caseInsensitive)
        learningsSection = try compileRegex(#"^##\s+Learnings\s*$"#, options: .caseInsensitive)
        sessionsSection = try compileRegex(#"^##\s+Sessions\s*$"#, options: .caseInsensitive)
    }
}

/// Lazy, thread-safe cache so regexes are compiled once per process.
private enum NotesPatternsCache {
    private static var cached: NotesPatterns?
    private static let lock = NSLock()

    static func get() throws -> NotesPatterns {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached { return c }
        let p = try NotesPatterns()
        cached = p
        return p
    }
}

// #region agent log
/// Preserves blank lines inside callouts (append "" when inBlock and line is blank) so round-trip keeps formatting.
private func extractCallout(lines: [String], pattern: NSRegularExpression, calloutStart: NSRegularExpression, calloutLabel: String? = nil) -> String {
    var content: [String] = []
    var inBlock = false
    var blankLinesPreserved = 0
    for line in lines {
        if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            inBlock = true
            continue
        }
        if inBlock, calloutStart.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { break }
        if inBlock, line.hasPrefix(">") {
            // Drop "> " (two chars) so round-trip preserves single space after >
            let rest = line.dropFirst()
            if rest.first == " " {
                content.append(String(rest.dropFirst()))
            } else {
                content.append(String(rest))
            }
            continue
        }
        if inBlock, !line.hasPrefix(">") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                content.append("")
                blankLinesPreserved += 1
            } else { break }
        }
    }
    if let label = calloutLabel, blankLinesPreserved > 0 {
        debugLog(location: "NotesParse.swift:extractCallout", message: "Blank lines preserved in callout", data: ["callout": label, "count": blankLinesPreserved], hypothesisId: "A")
    }
    return content.joined(separator: "\n")
}
// #endregion

private func extractGoals(lines: [String], p: NotesPatterns) -> [String] {
    var goals: [String] = []
    var inBlock = false
    for line in lines {
        if p.goals.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            inBlock = true
            continue
        }
        if inBlock, p.calloutStart.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { break }
        if inBlock, line.hasPrefix(">") {
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if let m = p.num.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
               let r = Range(m.range(at: 1), in: rest) {
                goals.append(String(rest[r]))
            }
            continue
        }
        if inBlock, !line.hasPrefix(">") { break }
    }
    return goals.isEmpty ? ["", "", ""] : goals
}

private func parseLinksBlock(text: String, p: NotesPatterns) -> [LinkEntry] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let emptyLineCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    if emptyLineCount > 0 {
        debugLog(location: "NotesParse.swift:parseLinksBlock", message: "Empty/blank lines in Links block", data: ["emptyLineCount": emptyLineCount, "totalLines": lines.count], hypothesisId: "C")
    }
    var entries: [LinkEntry] = []
    var i = 0
    while i < lines.count {
        guard let m = p.linkLine.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])),
              let r = Range(m.range(at: 1), in: lines[i]) else {
            i += 1
            continue
        }
        let part = String(lines[i][r])
        if part.trimmingCharacters(in: .whitespaces).isEmpty {
            entries.append(LinkEntry())
            i += 1
            continue
        }
        let colonIdx = part.firstIndex(of: ":")
        let isUrl = p.url.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) != nil
        if let ci = colonIdx, ci > part.startIndex, !isUrl {
            let label = String(part[..<ci])
            let url = String(part[part.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
            entries.append(LinkEntry(label: label, url: url.isEmpty ? nil : url))
        } else if isUrl {
            entries.append(LinkEntry(url: part))
        } else {
            var children: [LinkEntry] = []
            i += 1
            while i < lines.count,
                  let nm = p.nestedLink.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])),
                  let nr = Range(nm.range(at: 1), in: lines[i]) {
                children.append(LinkEntry(url: String(lines[i][nr])))
                i += 1
            }
            entries.append(LinkEntry(label: part, children: children))
            continue
        }
        i += 1
    }
    return entries.isEmpty ? [LinkEntry()] : entries
}

/// Parse learnings list; empty bullets ("- " or "-  ") are normalized to "" so round-trip matches default ProjectNotes.
private func parseLearningsBlock(text: String, p: NotesPatterns) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let emptyLineCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    if emptyLineCount > 0 {
        debugLog(location: "NotesParse.swift:parseLearningsBlock", message: "Empty/blank lines in Learnings block", data: ["emptyLineCount": emptyLineCount, "totalLines": lines.count], hypothesisId: "C")
    }
    let items = lines.compactMap { line -> String? in
        let lineStr = String(line)
        guard let m = p.learning.firstMatch(in: lineStr, range: NSRange(lineStr.startIndex..., in: lineStr)),
              let r = Range(m.range(at: 1), in: lineStr) else { return nil }
        return String(lineStr[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return items.isEmpty ? [""] : items
}

private func parseSessionsBlock(text: String, p: NotesPatterns) -> [Session] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var sessions: [Session] = []
    var i = 0
    while i < lines.count {
        guard let m = p.sessionHeading.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])),
              let r1 = Range(m.range(at: 1), in: lines[i]),
              let r2 = Range(m.range(at: 2), in: lines[i]),
              let r3 = Range(m.range(at: 3), in: lines[i]),
              let r4 = Range(m.range(at: 4), in: lines[i]) else {
            i += 1
            continue
        }
        let date = "\(lines[i][r1]), \(lines[i][r2]) \(lines[i][r3]), \(lines[i][r4])"
        let label: String
        if m.numberOfRanges > 5, let r5 = Range(m.range(at: 5), in: lines[i]) {
            label = String(lines[i][r5]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            label = ""
        }
        i += 1
        var bodyLines: [String] = []
        while i < lines.count,
              p.sessionHeading.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) == nil,
              p.section.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) == nil {
            bodyLines.append(lines[i])
            i += 1
        }
        var bodyStr = bodyLines.joined(separator: "\n")
        // Trim at most one leading and one trailing newline so multiple blank lines at start/end are preserved.
        if bodyStr.hasPrefix("\n") { bodyStr = String(bodyStr.dropFirst()) }
        if bodyStr.hasSuffix("\n") { bodyStr = String(bodyStr.dropLast()) }
        sessions.append(Session(date: date, label: label, body: bodyStr))
    }
    return sessions
}

public func parseNotes(markdown: String) throws -> ProjectNotes {
    let patterns = try NotesPatternsCache.get()
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? ""

    let summary = extractCallout(lines: lines, pattern: patterns.summary, calloutStart: patterns.calloutStart, calloutLabel: "summary")
    let problem = extractCallout(lines: lines, pattern: patterns.problem, calloutStart: patterns.calloutStart, calloutLabel: "problem")
    let goals = extractGoals(lines: lines, p: patterns)
    let approach = extractCallout(lines: lines, pattern: patterns.approach, calloutStart: patterns.calloutStart, calloutLabel: "approach")

    let linksStart = lines.firstIndex { patterns.linksSection.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    let learningsStart = lines.firstIndex { patterns.learningsSection.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    let sessionsStart = lines.firstIndex { patterns.sessionsSection.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }

    let linksText: String
    if let ls = linksStart, let lns = learningsStart, lns > ls {
        linksText = lines[(ls + 1)..<lns].joined(separator: "\n")
    } else {
        linksText = ""
    }
    let learningsText: String
    if let lns = learningsStart {
        let end = sessionsStart ?? lines.count
        if end > lns {
            learningsText = lines[(lns + 1)..<end].joined(separator: "\n")
        } else {
            learningsText = ""
        }
    } else {
        learningsText = ""
    }
    let sessionsText: String
    if let ss = sessionsStart {
        sessionsText = lines[(ss + 1)...].joined(separator: "\n")
    } else {
        sessionsText = ""
    }

    return ProjectNotes(
        title: title,
        summary: summary,
        problem: problem,
        goals: goals,
        approach: approach,
        links: parseLinksBlock(text: linksText, p: patterns),
        learnings: parseLearningsBlock(text: learningsText, p: patterns),
        sessions: parseSessionsBlock(text: sessionsText, p: patterns)
    )
}
