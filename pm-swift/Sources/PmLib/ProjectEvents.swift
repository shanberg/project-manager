import Foundation

/// The calendars a project shows events from, and what to match in them (views.md, Calendars C2).
///
/// In the notes file's frontmatter under `pm-events`, beside `pm-color`, so it goes wherever the folder
/// goes. Unlike the other `pm-` keys it's a block, not a scalar:
///
/// ```yaml
/// pm-events:
///   - calendar: Work              # the calendar's title
///     account: iCloud             # optional; only when two calendars share a title
///     match: ["1:1 Priya", "Priya / Stuart"]
///   - calendar: Launch            # no match: every event in the calendar
/// ```
///
/// PmLib reads, writes and matches. Where events come from (EventKit, in the app) is not its business,
/// so the matcher takes plain strings.
public struct ProjectEventSource: Equatable, Hashable, Sendable {
    /// The calendar's title, not its `calendarIdentifier`, which isn't stable across Macs.
    public var calendar: String
    /// The account (EventKit's source) title. Nil matches the calendar in any account.
    public var account: String?
    /// Strings an event's title must contain, any one of them, ignoring case. Empty: every event.
    public var match: [String]

    public init(calendar: String, account: String? = nil, match: [String] = []) {
        self.calendar = calendar
        self.account = account
        self.match = match
    }

    public static let frontmatterKey = "pm-events"

    /// Whether an event belongs to this source. Calendar and account titles are compared ignoring case
    /// and surrounding space, since they're typed as often as picked. A blank `match` string is
    /// ignored rather than matching everything.
    public func matches(calendar: String, account: String?, title: String) -> Bool {
        guard same(self.calendar, calendar) else { return false }
        if let wanted = self.account, !same(wanted, account ?? "") { return false }
        let queries = match.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return queries.isEmpty || queries.contains { title.range(of: $0, options: .caseInsensitive) != nil }
    }

    private func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces))
            == .orderedSame
    }
}

extension Array where Element == ProjectEventSource {
    /// Whether an event belongs to a project with these sources: any one of them.
    public func matches(calendar: String, account: String?, title: String) -> Bool {
        contains { $0.matches(calendar: calendar, account: account, title: title) }
    }
}

// MARK: - Reading

/// A project's event sources, read from a notes file's text. Empty when there's no `pm-events`, and
/// entries without a calendar are skipped. Keys other than `calendar`, `account` and `match` are ignored.
public func projectEventSources(rawText: String) -> [ProjectEventSource] {
    let lines = rawText.components(separatedBy: "\n")
    guard let block = eventsBlock(lines) else { return [] }

    var sources: [ProjectEventSource] = []
    var current: [String: String] = [:]
    var currentMatch: [String] = []
    var itemIndent: Int?
    var inMatchList = false

    func flush() {
        if let calendar = current["calendar"], !calendar.isEmpty {
            let account = current["account"].flatMap { $0.isEmpty ? nil : $0 }
            sources.append(ProjectEventSource(calendar: calendar, account: account, match: currentMatch))
        }
        current = [:]
        currentMatch = []
        inMatchList = false
    }

    func take(_ key: String, _ raw: String) {
        inMatchList = false
        switch key {
        case "match":
            if raw.isEmpty {
                inMatchList = true
            } else if raw.hasPrefix("[") {
                currentMatch = yamlFlowList(raw)
            } else {
                currentMatch = [yamlScalar(raw)].filter { !$0.isEmpty }
            }
        default:
            current[key] = yamlScalar(raw)
        }
    }

    for index in block.items {
        let line = lines[index]
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") { continue }
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count

        if text == "-" || text.hasPrefix("- ") {
            let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            if itemIndent == nil { itemIndent = indent }
            if indent == itemIndent {
                if !(current.isEmpty && currentMatch.isEmpty) { flush() }
                inMatchList = false
                if let (key, value) = keyValue(rest) { take(key, value) }
            } else if inMatchList {
                let value = yamlScalar(rest)
                if !value.isEmpty { currentMatch.append(value) }
            }
        } else if let (key, value) = keyValue(text) {
            take(key, value)
        }
    }
    flush()
    return sources
}

// MARK: - Writing

/// `rawText` with its `pm-events` block replaced by `sources`, or removed when they're empty. Every
/// other byte stays. Unrecognised keys inside the old block are not carried over.
public func settingProjectEventSources(_ sources: [ProjectEventSource], in rawText: String) -> String {
    var lines = rawText.components(separatedBy: "\n")
    let entry = sources.isEmpty ? nil : eventsLines(sources)

    if let block = eventsBlock(lines) {
        let removed = block.key..<block.end
        if let entry {
            lines.replaceSubrange(removed, with: entry)
            return lines.joined(separator: "\n")
        }
        lines.removeSubrange(removed)
        // The last key gone takes its block with it, as settingFrontmatterValue does.
        if let close = lines.indices.dropFirst().first(where: { isFence(lines[$0]) }),
           lines[1..<close].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeSubrange(0...close)
        }
        return lines.joined(separator: "\n")
    }

    guard let entry else { return rawText }
    guard let first = lines.first, isFence(first),
          let close = lines.indices.dropFirst().first(where: { isFence(lines[$0]) }) else {
        lines.insert(contentsOf: ["---"] + entry + ["---"], at: 0)
        return lines.joined(separator: "\n")
    }
    lines.insert(contentsOf: entry, at: close)
    return lines.joined(separator: "\n")
}

/// Set or clear a project's event sources, touching nothing in the file but the `pm-events` block.
public func setProjectEventSources(project: String, to sources: [ProjectEventSource]) throws {
    let handle = try resolveNotesHandle(project: project)
    let raw = try handle.io.readContent(path: handle.notesPath)
    let updated = settingProjectEventSources(sources, in: raw)
    guard updated != raw else { return }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}

private func eventsLines(_ sources: [ProjectEventSource]) -> [String] {
    var lines = ["\(ProjectEventSource.frontmatterKey):"]
    for source in sources {
        lines.append("  - calendar: \(yamlWriting(source.calendar))")
        if let account = source.account { lines.append("    account: \(yamlWriting(account))") }
        let match = source.match.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !match.isEmpty {
            // Always quoted in a flow list: a query is short, and "1:1 Priya" would otherwise read as a map.
            lines.append("    match: [\(match.map(yamlQuoted).joined(separator: ", "))]")
        }
    }
    return lines
}

// MARK: - The block

private func isFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }

/// Where `pm-events` sits in the frontmatter: its key line, the lines under it, and the index after the
/// last of them. The block runs until the next top-level key, the closing fence, or the end.
private func eventsBlock(_ lines: [String]) -> (key: Int, items: Range<Int>, end: Int)? {
    guard let first = lines.first, isFence(first),
          let close = lines.indices.dropFirst().first(where: { isFence(lines[$0]) }),
          let key = (1..<close).first(where: { lines[$0].hasPrefix("\(ProjectEventSource.frontmatterKey):") })
    else { return nil }
    var end = key + 1
    while end < close {
        let line = lines[end]
        // A sequence may sit at the key's own indent (`- calendar: …` at column 0), so a dash continues it.
        let continues = line.first.map { $0 == " " || $0 == "\t" || $0 == "-" || $0 == "#" } ?? true
        guard continues else { break }
        end += 1
    }
    // Trailing blank lines belong to whatever follows, not to the block.
    while end > key + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
    return (key, (key + 1)..<end, end)
}

// MARK: - YAML, as much as this block needs

private func keyValue(_ text: String) -> (String, String)? {
    guard let colon = text.firstIndex(of: ":") else { return nil }
    let key = text[..<colon].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty, !key.contains(" ") else { return nil }
    return (key, text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
}

/// A plain or quoted scalar. A plain one loses a trailing ` # comment`; a quoted one keeps everything
/// inside its quotes, with `\"` and `\\` unescaped in double quotes and `''` in single.
private func yamlScalar(_ raw: String) -> String {
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard let quote = text.first, quote == "\"" || quote == "'" else {
        let plain = text.range(of: " #").map { String(text[..<$0.lowerBound]) } ?? text
        return plain.trimmingCharacters(in: .whitespaces)
    }
    var out = ""
    var index = text.index(after: text.startIndex)
    while index < text.endIndex {
        let char = text[index]
        let next = text.index(after: index)
        if quote == "\"", char == "\\", next < text.endIndex {
            out.append(text[next])
            index = text.index(after: next)
            continue
        }
        if char == quote {
            if quote == "'", next < text.endIndex, text[next] == "'" {
                out.append("'")
                index = text.index(after: next)
                continue
            }
            break
        }
        out.append(char)
        index = next
    }
    return out
}

/// `[a, "b, c", 'd']` → its items, splitting on commas outside quotes. Blank items are dropped.
private func yamlFlowList(_ raw: String) -> [String] {
    var text = Substring(raw.trimmingCharacters(in: .whitespaces))
    guard text.hasPrefix("[") else { return [] }
    text = text.dropFirst()
    var items: [String] = []
    var piece = ""
    var quote: Character?
    var escaped = false
    for char in text {
        if let open = quote {
            piece.append(char)
            if escaped { escaped = false } else if open == "\"" && char == "\\" { escaped = true } else if char == open { quote = nil }
            continue
        }
        if char == "\"" || char == "'" { quote = char; piece.append(char); continue }
        if char == "," || char == "]" {
            items.append(yamlScalar(piece))
            piece = ""
            if char == "]" { break }
            continue
        }
        piece.append(char)
    }
    return items.filter { !$0.isEmpty }
}

private func yamlQuoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Plain when YAML would read it back unchanged, quoted otherwise.
private func yamlWriting(_ text: String) -> String {
    let special: Set<Character> = [":", "#", "[", "]", "{", "}", ",", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`", "\\"]
    let plain = !text.isEmpty
        && text == text.trimmingCharacters(in: .whitespaces)
        && !text.contains(where: { special.contains($0) })
        && !text.hasPrefix("-") && !text.hasPrefix("?")
        && !["true", "false", "yes", "no", "null", "~", "on", "off"].contains(text.lowercased())
        && Double(text) == nil
    return plain ? text : yamlQuoted(text)
}

// MARK: - Choosing calendars

/// One calendar in the app's Show Events From… sheet: a calendar on this Mac, or a saved entry this Mac
/// doesn't have. Rows go in, sources come out — the sheet itself only draws them.
public struct ProjectEventChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Nil only for a saved entry that names no account and matched nothing here.
    public let account: String?
    public let isOnThisMac: Bool
    public var isOn: Bool
    public var queries: [String]
    /// The saved entry named its account, so saving keeps naming it.
    public let namesAccount: Bool
    /// Its place in the file, so saving keeps the file's order. New ones go last.
    public let order: Int
}

/// A row per calendar on this Mac, in the order given and checked where a source names it, then a row
/// per source that names none of them.
public func projectEventChoices(calendars: [(title: String, account: String)],
                                sources: [ProjectEventSource]) -> [ProjectEventChoice] {
    func names(_ source: ProjectEventSource, _ calendar: (title: String, account: String)) -> Bool {
        ProjectEventSource(calendar: source.calendar, account: source.account)
            .matches(calendar: calendar.title, account: calendar.account, title: "")
    }
    var choices = calendars.map { calendar in
        let index = sources.firstIndex { names($0, calendar) }
        let source = index.map { sources[$0] }
        return ProjectEventChoice(id: choiceID(calendar.title, calendar.account), title: calendar.title,
                                  account: calendar.account, isOnThisMac: true, isOn: source != nil,
                                  queries: source?.match ?? [], namesAccount: source?.account != nil,
                                  order: index ?? Int.max)
    }
    for (index, source) in sources.enumerated() where !calendars.contains(where: { names(source, $0) }) {
        choices.append(ProjectEventChoice(id: choiceID(source.calendar, source.account), title: source.calendar,
                                          account: source.account, isOnThisMac: false, isOn: true,
                                          queries: source.match, namesAccount: source.account != nil,
                                          order: index))
    }
    return choices
}

/// What saving the rows writes: the checked ones, in the file's order, blank queries dropped.
///
/// An account is written only when it's needed (C2): the file named one, or two calendars here share
/// the title and aren't checked alike. Two rows found through one account-less entry and left as they
/// were go back as that one entry, so opening the sheet and saving changes nothing.
public func projectEventSources(from choices: [ProjectEventChoice]) -> [ProjectEventSource] {
    func key(_ title: String) -> String { title.trimmingCharacters(in: .whitespaces).lowercased() }
    func cleaned(_ queries: [String]) -> [String] {
        queries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    let byTitle = Dictionary(grouping: choices, by: { key($0.title) })
    var entries: [(order: Int, source: ProjectEventSource)] = []
    for (position, choice) in choices.enumerated() where choice.isOn {
        let twins = byTitle[key(choice.title)] ?? [choice]
        let alike = twins.allSatisfy { !$0.namesAccount && $0.isOn && cleaned($0.queries) == cleaned(choice.queries) }
        let account = choice.namesAccount || (twins.count > 1 && !alike) ? choice.account : nil
        let source = ProjectEventSource(calendar: choice.title, account: account, match: cleaned(choice.queries))
        guard !entries.contains(where: { $0.source == source }) else { continue }
        entries.append((choice.order == Int.max ? Int.max / 2 + position : choice.order, source))
    }
    return entries.sorted { $0.order < $1.order }.map(\.source)
}

private func choiceID(_ title: String, _ account: String?) -> String {
    "\(account?.lowercased() ?? "")\u{1f}\(title.lowercased())"
}

// MARK: - Across the vault

/// A project that shows events, and what it takes them from — what a view needs to fetch its events and
/// draw them in the project's colours (views.md C3).
public struct ProjectEventLink: Equatable, Sendable {
    public let projectFolder: String
    public let projectName: String
    public let projectColor: String?
    public let projectIcon: String?
    public let sources: [ProjectEventSource]
}

/// Every project with `pm-events`, among `projects` (named as `sessionList` takes them; nil for all).
///
/// Unlike sittings, all means the active projects and areas: an archived project's calendar is still
/// someone's calendar, and a meeting next week isn't the archived work's. Named, the archive counts.
///
/// **Only frontmatter is read, and only when the file changed.** A view asks every little while, and
/// the answer changes when a notes file does, so each file's links are kept against its modified date.
public func projectEventLinks(projects: [String]? = nil) throws -> [ProjectEventLink] {
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    let only = try projects.map(projectFolders(named:))

    var links: [ProjectEventLink] = []
    var seen = Set<String>()
    for scope in ProjectScope.allCases where only != nil || !scope.isArchived {
        let base = scope.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            if let only, !only.contains(folder) { continue }
            let projectPath = (base as NSString).appendingPathComponent(folder)
            guard seen.insert(projectPath).inserted,
                  let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil,
                  let link = EventLinkCache.shared.link(folder: folder, notesPath: notesPath) else { continue }
            links.append(link)
        }
    }
    return links
}

private final class EventLinkCache: @unchecked Sendable {
    static let shared = EventLinkCache()
    private let lock = NSLock()
    private var entries: [String: (modified: Date?, link: ProjectEventLink?)] = [:]

    func link(folder: String, notesPath: String) -> ProjectEventLink? {
        let modified = notesLastEdited(path: notesPath)
        lock.lock()
        let hit = entries[notesPath]
        lock.unlock()
        if let hit, hit.modified == modified, modified != nil, hit.link?.projectFolder ?? folder == folder {
            return hit.link
        }
        var link: ProjectEventLink?
        if let raw = try? String(contentsOfFile: notesPath, encoding: .utf8) {
            let sources = projectEventSources(rawText: raw)
            if !sources.isEmpty {
                link = ProjectEventLink(projectFolder: folder, projectName: projectTitle(fromFolderName: folder),
                                        projectColor: projectColor(rawText: raw)?.value,
                                        projectIcon: projectIcon(rawText: raw, notesPath: notesPath)?.value,
                                        sources: sources)
            }
        }
        lock.lock()
        entries[notesPath] = (modified, link)
        lock.unlock()
        return link
    }
}

// MARK: - An event, placed

/// A calendar event as a view draws it: which project's, and where it falls. The app fills these from
/// EventKit; everything after that — which days it's on, what it says as text — is here, and tested.
public struct ProjectEvent: Equatable, Hashable, Sendable, Identifiable {
    /// The occurrence: an event's identifier and its start, since a series shares one identifier.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let projectFolder: String
    public let projectName: String
    public let projectColor: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool,
                projectFolder: String, projectName: String, projectColor: String?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.projectFolder = projectFolder
        self.projectName = projectName
        self.projectColor = projectColor
    }

    /// The local days it's on, `YYYY-MM-DD`: an all-day event's end is the midnight after its last day,
    /// and a timed one ending at midnight doesn't reach into the next.
    public func days(calendar: Calendar = .current) -> [String] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(start, end.addingTimeInterval(-1)))
        var days: [String] = []
        var day = first
        while day <= last, days.count < 366 {
            days.append(Self.iso(day, calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// Minutes past midnight it starts on `day`: 0 when it began on an earlier day. Nil all day.
    public func startMinute(on day: String, calendar: Calendar = .current) -> Int? {
        guard !isAllDay else { return nil }
        guard Self.iso(start, calendar) == day else { return 0 }
        let parts = calendar.dateComponents([.hour, .minute], from: start)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Minutes past midnight it ends on `day`: 1440 when it runs on past it. Nil all day.
    public func endMinute(on day: String, calendar: Calendar = .current) -> Int? {
        guard !isAllDay else { return nil }
        let endDay = Self.iso(end.addingTimeInterval(-1), calendar)
        guard endDay == day else { return 24 * 60 }
        let parts = calendar.dateComponents([.hour, .minute], from: end)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute == 0 ? 24 * 60 : minute
    }

    /// "9:00–9:30 AM", "11:30 AM–12:15 PM", "All day".
    public func timeLabel(calendar: Calendar = .current) -> String {
        guard !isAllDay else { return "All day" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        formatter.dateFormat = "a"
        let sameHalf = formatter.string(from: start) == formatter.string(from: end)
            && calendar.isDate(start, inSameDayAs: end)
        formatter.dateFormat = sameHalf ? "h:mm" : "h:mm a"
        let from = formatter.string(from: start)
        formatter.dateFormat = "h:mm a"
        return "\(from)–\(formatter.string(from: end))"
    }

    private static func iso(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension Array where Element == ProjectEvent {
    /// The events on `day`, all-day first, then by start.
    public func on(_ day: String, calendar: Calendar = .current) -> [ProjectEvent] {
        filter { $0.days(calendar: calendar).contains(day) }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start != b.start ? a.start < b.start : a.title < b.title
            }
    }
}

// MARK: - As text

extension ViewMarkdown {
    /// A view's events for Copy as Text (views.md D10, C4): a section after its answer, a heading per
    /// day in `days`, and a line per event. Empty when none of them has any.
    public static func events(_ events: [ProjectEvent], days: [String], calendar: Calendar = .current) -> String {
        var out: [String] = []
        for day in days {
            let on = events.on(day, calendar: calendar)
            guard !on.isEmpty else { continue }
            out += ["", "### \(longDay(day, calendar: calendar))", ""]
            out += on.map { "- \($0.timeLabel(calendar: calendar)) · \($0.title) · \(link($0.projectFolder))" }
        }
        guard !out.isEmpty else { return "" }
        return (["## Events"] + out).joined(separator: "\n") + "\n"
    }
}
