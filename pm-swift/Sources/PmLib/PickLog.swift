import Foundation

// MARK: - What got picked up
//
// A task has an origin — the sitting it was written in, in the sentence it was written beside — and,
// separately, whether you're working on it now. The notes file can only say the first, because a task
// is one line in one place. Moving the line to today's session says the second by destroying the
// first. This log says the second without touching the line: "this task, written on the 2nd, was
// picked up into the sitting of the 17th". See docs/sessions.md D2.
//
// ## Beside the done log, for the same reasons
//
// One append-only file per project folder, dot-prefixed so Obsidian and Finder leave it alone, moving
// with the folder through renames and archiving and syncing with the vault. Unlike the done log it is
// *written*, not observed: a pick is something you did in PM, and there is nothing in the notes for a
// look to find.
//
// ## A record, not a claim about the file
//
// Each pick names its task with a `TaskRef` and its sitting with a `SessionRef`, and a read resolves
// both with the usual three outcomes. A pick whose task was renamed in Obsidian, deleted, or whose
// sitting was deleted doesn't resolve, and is **not drawn** — never guessed at, and never an error.
// Nothing is ever removed from the log: a `released` cancels a pick by naming it, the way a reopening
// cancels a completion.

/// A task as a pick names it: the stable half of a `TaskRef`, plus a copy of the text so the log reads
/// on its own.
public struct PickedTask: Codable, Equatable, Sendable {
    /// The ISO date of the session the task was written in.
    public var session: String
    /// Which session of that date. Almost always 0.
    public var ordinal: Int
    /// Its ordinal among that session's task lines, when the pick was made.
    public var line: Int
    public var digest: String
    public var text: String

    public init(session: String, ordinal: Int = 0, line: Int, digest: String, text: String) {
        self.session = session
        self.ordinal = ordinal
        self.line = line
        self.digest = digest
        self.text = text
    }

    var ref: TaskRef {
        TaskRef(sessionDate: session, sessionOrdinal: ordinal, lineIndex: line, digest: digest)
    }
}

/// A sitting as a pick names it: a `SessionRef` by date.
public struct PickedInto: Codable, Equatable, Sendable {
    public var session: String
    public var ordinal: Int
    public var digest: String

    public init(session: String, ordinal: Int = 0, digest: String) {
        self.session = session
        self.ordinal = ordinal
        self.digest = digest
    }

    var ref: SessionRef { SessionRef(date: session, ordinal: ordinal, digest: digest) }
}

/// One line of the log.
public struct PickEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A task from an older sitting was taken up in this one.
        case picked
        /// A pick was taken back — Put Back, or undo. Names the pick it cancels in `reverses`.
        case released
        /// A picked task was renamed through PM. Carries the new digest and text, and the picks it
        /// applies to, so a rename doesn't strand them.
        case retargeted
    }

    public var id: String
    /// When it happened, ISO 8601 in UTC.
    public var at: String
    public var event: Kind
    public var task: PickedTask
    /// The sitting a pick went into. On `released`, the sitting the cancelled pick went into.
    public var into: PickedInto?
    /// `released`: the id of the pick it cancels.
    public var reverses: String?
    /// `retargeted`: the ids of the picks whose task this is.
    public var retargets: [String]?
    /// `retargeted`: the task's new digest. `task.digest` is the old one.
    public var to: String?
    /// Which surface did it — "app", "cli", "raycast", a model.
    public var source: String?

    public init(id: String = PickLog.newID(), at: String, event: Kind, task: PickedTask,
                into: PickedInto? = nil, reverses: String? = nil, retargets: [String]? = nil,
                to: String? = nil, source: String? = nil) {
        self.id = id
        self.at = at
        self.event = event
        self.task = task
        self.into = into
        self.reverses = reverses
        self.retargets = retargets
        self.to = to
        self.source = source
    }
}

/// A pick that still stands and still resolves, as a read reports it: where the task is now and which
/// sitting it was picked up into, both as positions in the document just read.
public struct TaskPick: Codable, Equatable, Sendable {
    /// The pick's id — what Put Back and undo name when they take it back.
    public var id: String
    public var at: String
    /// Where the task is now.
    public var sessionIndex: Int
    public var lineIndex: Int
    /// The sitting it was picked up into: its ISO date, and its index in this read.
    public var into: String
    public var intoIndex: Int
}

/// The one fact every task read carries about its picks: the latest sitting it was picked up into.
public struct PickMark: Codable, Equatable, Sendable {
    /// The ISO date of that sitting.
    public var into: String
    /// When it was picked up, ISO 8601 in UTC.
    public var at: String

    public init(into: String, at: String) {
        self.into = into
        self.at = at
    }
}

public enum PickLog {
    static let logName = ".pm-picked.ndjson"

    public static func logPath(projectPath: String) -> String {
        (projectPath as NSString).appendingPathComponent(logName)
    }

    public static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    // MARK: Writing

    /// Append events, under the same lock discipline the done log uses: the app and a `pm` call can
    /// write the same project at once, and two appends interleaving mid-line would corrupt both.
    ///
    /// Throws, where the done log's look never does. A look that fails loses a record of something the
    /// notes still show; a pick that fails to append *is* the whole action failing, and saying it
    /// happened would be a lie.
    public static func append(_ events: [PickEvent], projectPath: String) throws {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = ""
        for event in events {
            lines += String(decoding: try encoder.encode(event), as: UTF8.self) + "\n"
        }
        let path = logPath(projectPath: projectPath)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw ApiError(.writeFailed, "couldn't open \(logName) in \(projectPath)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw ApiError(.writeFailed, "couldn't lock \(logName) in \(projectPath)")
        }
        defer { flock(fd, LOCK_UN) }
        let bytes = Array(lines.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else {
            throw ApiError(.writeFailed, "couldn't write \(logName) in \(projectPath)")
        }
    }

    // MARK: Reading

    public static func events(projectPath: String) -> [PickEvent] {
        guard let text = try? String(contentsOfFile: logPath(projectPath: projectPath), encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(PickEvent.self, from: Data($0.utf8)) }
    }

    /// The picks still standing, oldest first, each carrying the task's latest digest and text.
    ///
    /// A `released` cancels exactly the pick it names, and nothing else — so undoing today's pick of a
    /// task leaves yesterday's pick of the same task alone. One without a name (hand-written, or from
    /// an older writer) cancels the latest standing pick of the same task into the same sitting.
    static func standing(_ events: [PickEvent]) -> [PickEvent] {
        var kept: [PickEvent?] = []
        for event in events {
            switch event.event {
            case .picked:
                kept.append(event)
            case .released:
                let index = event.reverses.flatMap { id in kept.lastIndex { $0?.id == id } }
                    ?? kept.lastIndex { pick in
                        guard let pick else { return false }
                        return pick.task.session == event.task.session
                            && pick.task.ordinal == event.task.ordinal
                            && pick.task.digest == event.task.digest
                            && pick.into == event.into
                    }
                if let index { kept[index] = nil }
            case .retargeted:
                guard let to = event.to, let ids = event.retargets else { continue }
                for i in kept.indices where kept[i].map({ ids.contains($0.id) }) == true {
                    kept[i]?.task.digest = to
                    kept[i]?.task.text = event.task.text
                    kept[i]?.task.session = event.task.session
                    kept[i]?.task.ordinal = event.task.ordinal
                    kept[i]?.task.line = event.task.line
                }
            }
        }
        return kept.compactMap { $0 }
    }

    /// A standing pick, resolved against one read of the document.
    struct Resolved: Equatable {
        let event: PickEvent
        let sessionIndex: Int
        let lineIndex: Int
        let intoIndex: Int

        var pick: TaskPick {
            TaskPick(id: event.id, at: event.at, sessionIndex: sessionIndex, lineIndex: lineIndex,
                     into: event.into?.session ?? "", intoIndex: intoIndex)
        }
    }

    /// The standing picks that still name a task and a sitting in this document, oldest first. A pick
    /// that resolves to nothing — its task renamed outside PM or deleted, its sitting gone — is left
    /// out without a word: the log is a record of what happened, not a claim about the file.
    ///
    /// Two picks of the same task into the same sitting (picked, put back, picked again, with an older
    /// writer's release in between) are one pick, the latest.
    static func resolve(_ standing: [PickEvent], notes: ProjectNotes, todos: [Todo]) -> [Resolved] {
        var out: [Resolved] = []
        for event in standing {
            guard let into = event.into,
                  let task = try? resolveTaskRef(event.task.ref, notes: notes, todos: todos),
                  let sitting = try? resolveSessionRef(into.ref, notes: notes),
                  // A task can't be picked up into the sitting it was written in; a pick that has come to
                  // say so (the task was moved there by hand) says nothing worth drawing.
                  task.sessionIndex != sitting.index else { continue }
            out.removeAll { $0.sessionIndex == task.sessionIndex && $0.lineIndex == task.lineIndex
                && $0.intoIndex == sitting.index }
            out.append(Resolved(event: event, sessionIndex: task.sessionIndex, lineIndex: task.lineIndex,
                                intoIndex: sitting.index))
        }
        return out
    }

    static func resolved(projectPath: String, notes: ProjectNotes, todos: [Todo]) -> [Resolved] {
        resolve(standing(events(projectPath: projectPath)), notes: notes, todos: todos)
    }

    // MARK: Naming things

    /// How a pick names a task just read, or nil for one under a heading PM can't date — a hand-edited
    /// heading still holds tasks, it just can't be named back by date, and a pick by index would come to
    /// name a different task the first time a sitting was started.
    static func task(_ todo: Todo, in notes: ProjectNotes) -> PickedTask? {
        guard let iso = todo.sessionISODate, todo.sessionIndex < notes.sessions.count else { return nil }
        let heading = notes.sessions[todo.sessionIndex].date
        let ordinal = notes.sessions[..<todo.sessionIndex].filter { $0.date == heading }.count
        return PickedTask(session: iso, ordinal: ordinal, line: todo.lineIndex,
                          digest: todo.digest ?? taskDigest(todo.text), text: todo.text)
    }

    /// How a pick names a sitting just read, or nil for one PM can't date.
    static func sitting(at index: Int, in notes: ProjectNotes) -> PickedInto? {
        guard index >= 0, index < notes.sessions.count else { return nil }
        let ref = SessionRef(session: notes.sessions[index], at: index, in: notes)
        guard let date = ref.date else { return nil }
        return PickedInto(session: date, ordinal: ref.ordinal, digest: ref.digest ?? "")
    }
}

extension NotesShowOutput {
    /// This read with the project's picks attached: every standing pick, and on each task the latest
    /// sitting it was picked up into.
    func attachingPicks(projectPath: String) -> NotesShowOutput {
        let resolved = PickLog.resolved(projectPath: projectPath, notes: notes, todos: todos)
        guard !resolved.isEmpty else { return self }
        var out = self
        out.picks = resolved.map(\.pick)
        for pick in resolved {
            guard let i = out.todos.firstIndex(where: {
                $0.sessionIndex == pick.sessionIndex && $0.lineIndex == pick.lineIndex
            }) else { continue }
            // Oldest first, so the last one written wins. By when it happened rather than by which
            // sitting is newer: picking an old task back into an older sitting is odd, but it's what
            // was last done to it.
            out.todos[i].picked = PickMark(into: pick.event.into?.session ?? "", at: pick.event.at)
        }
        return out
    }
}
