import Foundation

private let sessionHeadingPattern = try! NSRegularExpression(pattern: #"^###\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2}),\s+(\d{4})(?:\s+(.*))?$"#)
private let linkLinePattern = try! NSRegularExpression(pattern: #"^\s*-\s+(.+)$"#)
private let nestedLinkPattern = try! NSRegularExpression(pattern: #"^\s{4}-\s+(.+)$"#)
private let calloutStartPattern = try! NSRegularExpression(pattern: #"^>\s*\[!"#)

private func extractCallout(lines: [String], pattern: NSRegularExpression) -> String {
    var content: [String] = []
    var inBlock = false
    for line in lines {
        if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            inBlock = true
            continue
        }
        if inBlock, calloutStartPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { break }
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
        if inBlock, !line.hasPrefix(">"), !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
    }
    return content.joined(separator: "\n")
}

private func extractGoals(lines: [String]) -> [String] {
    let goalsRe = try! NSRegularExpression(pattern: #"^>\s*\[!info\]\s*Goals"#, options: .caseInsensitive)
    var goals: [String] = []
    var inBlock = false
    for line in lines {
        if goalsRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            inBlock = true
            continue
        }
        if inBlock, calloutStartPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { break }
        if inBlock, line.hasPrefix(">") {
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let numRe = try! NSRegularExpression(pattern: #"^\d+\.\s*(.*)$"#)
            if let m = numRe.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
               let r = Range(m.range(at: 1), in: rest) {
                goals.append(String(rest[r]))
            }
            continue
        }
        if inBlock, !line.hasPrefix(">") { break }
    }
    return goals.isEmpty ? ["", "", ""] : goals
}

private func parseLinksBlock(text: String) -> [LinkEntry] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var entries: [LinkEntry] = []
    var i = 0
    let urlPattern = try! NSRegularExpression(pattern: #"^https?://"#)
    while i < lines.count {
        guard let m = linkLinePattern.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])),
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
        let isUrl = urlPattern.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) != nil
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
                  let nm = nestedLinkPattern.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])),
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

private func parseLearningsBlock(text: String) -> [String] {
    let learningRe = try! NSRegularExpression(pattern: #"^\s*-\s+(.*)$"#)
    let items = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
        let lineStr = String(line)
        guard let m = learningRe.firstMatch(in: lineStr, range: NSRange(lineStr.startIndex..., in: lineStr)),
              let r = Range(m.range(at: 1), in: lineStr) else { return nil }
        return String(lineStr[r])
    }
    return items.isEmpty ? [""] : items
}

private func parseSessionsBlock(text: String) -> [Session] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var sessions: [Session] = []
    var i = 0
    let sectionRe = try! NSRegularExpression(pattern: #"^##\s"#)
    while i < lines.count {
        guard let m = sessionHeadingPattern.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])),
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
              sessionHeadingPattern.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) == nil,
              sectionRe.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) == nil {
            bodyLines.append(lines[i])
            i += 1
        }
        var bodyStr = bodyLines.joined(separator: "\n")
        while bodyStr.hasPrefix("\n") { bodyStr = String(bodyStr.dropFirst()) }
        while bodyStr.hasSuffix("\n") { bodyStr = String(bodyStr.dropLast()) }
        sessions.append(Session(date: date, label: label, body: bodyStr))
    }
    return sessions
}

public func parseNotes(markdown: String) -> ProjectNotes {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? ""

    let summaryRe = try! NSRegularExpression(pattern: #"^>\s*\[!summary\]"#, options: .caseInsensitive)
    let problemRe = try! NSRegularExpression(pattern: #"^>\s*\[!question\]"#, options: .caseInsensitive)
    let approachRe = try! NSRegularExpression(pattern: #"^>\s*\[!info\]\s*Approach"#, options: .caseInsensitive)

    let summary = extractCallout(lines: lines, pattern: summaryRe)
    let problem = extractCallout(lines: lines, pattern: problemRe)
    let goals = extractGoals(lines: lines)
    let approach = extractCallout(lines: lines, pattern: approachRe)

    let linksSectionRe = try! NSRegularExpression(pattern: #"^##\s+Links\s*$"#, options: .caseInsensitive)
    let learningsSectionRe = try! NSRegularExpression(pattern: #"^##\s+Learnings\s*$"#, options: .caseInsensitive)
    let sessionsSectionRe = try! NSRegularExpression(pattern: #"^##\s+Sessions\s*$"#, options: .caseInsensitive)

    let linksStart = lines.firstIndex { linksSectionRe.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? -1
    let learningsStart = lines.firstIndex { learningsSectionRe.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? -1
    let sessionsStart = lines.firstIndex { sessionsSectionRe.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? -1

    let linksText: String
    if linksStart >= 0, learningsStart > linksStart {
        linksText = lines[(linksStart + 1)..<learningsStart].joined(separator: "\n")
    } else {
        linksText = ""
    }
    let learningsText: String
    if learningsStart >= 0, sessionsStart > learningsStart {
        let end = sessionsStart >= 0 ? sessionsStart : lines.count
        learningsText = lines[(learningsStart + 1)..<end].joined(separator: "\n")
    } else {
        learningsText = ""
    }
    let sessionsText: String
    if sessionsStart >= 0 {
        sessionsText = lines[(sessionsStart + 1)...].joined(separator: "\n")
    } else {
        sessionsText = ""
    }

    return ProjectNotes(
        title: title,
        summary: summary,
        problem: problem,
        goals: goals,
        approach: approach,
        links: parseLinksBlock(text: linksText),
        learnings: parseLearningsBlock(text: learningsText),
        sessions: parseSessionsBlock(text: sessionsText)
    )
}
