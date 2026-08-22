import Foundation

// MARK: - What an action changed
//
// The envelope reports a diff rather than each action describing its own effects, for the reason the
// panel's preview already relies on: one comparison of before against after serves every action, and
// it cannot disagree with what the action did, because it is computed from what the action did.

/// Compare a project's tasks before and after an edit.
///
/// Tasks are matched by digest first, so a task that moved — because a session started above it, or
/// something was inserted — is recognised as the same task rather than reported as one disappearing
/// and another appearing. What the digest can't match is matched by position, which is what catches a
/// rename: same line, different text.
func diffTodos(before: [Todo], after: [Todo]) -> [ApiChange] {
    func uniqueByDigest(_ todos: [Todo]) -> [String: Todo] {
        var counts: [String: Int] = [:]
        for t in todos { counts[taskDigest(t.text), default: 0] += 1 }
        var out: [String: Todo] = [:]
        for t in todos where counts[taskDigest(t.text)] == 1 { out[taskDigest(t.text)] = t }
        return out
    }
    func position(_ t: Todo) -> String { "\(t.sessionIndex):\(t.lineIndex)" }

    let beforeByDigest = uniqueByDigest(before), afterByDigest = uniqueByDigest(after)
    var pairs: [(before: Todo, after: Todo)] = []
    var matchedBefore = Set<String>(), matchedAfter = Set<String>()

    for (digest, old) in beforeByDigest {
        if let new = afterByDigest[digest] {
            pairs.append((old, new))
            matchedBefore.insert(position(old))
            matchedAfter.insert(position(new))
        }
    }
    // Leftovers by position: a rename keeps the line and changes the text, which is exactly the pair
    // the digest match can't make.
    let leftoverAfter = Dictionary(
        after.filter { !matchedAfter.contains(position($0)) }.map { (position($0), $0) },
        uniquingKeysWith: { first, _ in first })
    for old in before where !matchedBefore.contains(position(old)) {
        if let new = leftoverAfter[position(old)] {
            pairs.append((old, new))
            matchedBefore.insert(position(old))
            matchedAfter.insert(position(new))
        }
    }

    var changes: [ApiChange] = []
    for (old, new) in pairs {
        if old.text != new.text {
            changes.append(ApiChange(kind: .renamed, ref: reference(to: new), was: old.text, now: new.text))
        }
        if old.checked != new.checked {
            changes.append(ApiChange(kind: new.checked ? .completed : .reopened,
                                     ref: reference(to: new), now: new.text))
        }
        if old.dueDate != new.dueDate {
            changes.append(ApiChange(kind: .retimed, ref: reference(to: new),
                                     was: old.dueDate, now: new.dueDate))
        }
        if old.depth != new.depth {
            changes.append(ApiChange(kind: .moved, ref: reference(to: new), now: new.text))
        }
        if old.isFocused != new.isFocused {
            changes.append(ApiChange(kind: new.isFocused ? .focused : .unfocused,
                                     ref: reference(to: new), now: new.text))
        }
    }
    for new in after where !matchedAfter.contains(position(new)) {
        changes.append(ApiChange(kind: .added, ref: reference(to: new), now: new.text))
        if new.isFocused {
            changes.append(ApiChange(kind: .focused, ref: reference(to: new), now: new.text))
        }
    }
    for old in before where !matchedBefore.contains(position(old)) {
        changes.append(ApiChange(kind: .removed, ref: reference(to: old), was: old.text))
    }
    return changes.sorted {
        ($0.ref?.session ?? "", $0.ref?.line ?? 0, $0.kind.rawValue)
            < ($1.ref?.session ?? "", $1.ref?.line ?? 0, $1.kind.rawValue)
    }
}

/// The reference a caller would need to act on this task next.
func reference(to todo: Todo) -> TaskRefInput {
    TaskRefInput(session: todo.sessionISODate ?? String(todo.sessionIndex),
                 line: todo.lineIndex,
                 digest: todo.digest ?? taskDigest(todo.text))
}

// MARK: - Saying it in a sentence

/// The one line a surface shows: the panel's receipt, Raycast's HUD, what a model reads back.
///
/// Built from the diff rather than written per action, so an action that turns out to touch more
/// than its name suggests — completing a task completes its subtree and moves focus — says so.
///
/// Both tenses, because a dry run has to say what *would* happen and English won't let you derive
/// that from "Completed" by lowercasing it.
struct Phrase: Equatable {
    var past: String
    var future: String
    /// A phrase that reads the same either way, because nothing is going to happen. "Would today's
    /// session is already there" is what taking the tenses literally gets you.
    var isStatement = false

    /// A finding rather than an effect — an action that turned out to have nothing to do.
    static func statement(_ text: String) -> Phrase {
        Phrase(past: text, future: text, isStatement: true)
    }

    /// The sentence for a real write, or for a preview of one.
    func sentence(dryRun: Bool) -> String {
        (dryRun && !isStatement ? "Would \(future)" : past) + "."
    }

    func appending(past clause: String, future participle: String) -> Phrase {
        Phrase(past: past + ". " + clause, future: future + ", " + participle)
    }
}

func summarize(action: String, changes: [ApiChange]) -> Phrase {
    func quoted(_ kind: ApiChange.Kind) -> String? {
        changes.first { $0.kind == kind }.flatMap { $0.now ?? $0.was }.map { "\u{201C}\($0)\u{201D}" }
    }
    func count(_ kind: ApiChange.Kind) -> Int { changes.filter { $0.kind == kind }.count }
    func extra(_ n: Int) -> String { n > 1 ? " and \(n - 1) subtask\(n == 2 ? "" : "s")" : "" }

    var phrase: Phrase
    switch action {
    case "task.complete":
        let what = "\(quoted(.completed) ?? "the task")\(extra(count(.completed)))"
        phrase = Phrase(past: "Completed \(what)", future: "complete \(what)")
    case "task.reopen":
        let what = quoted(.reopened) ?? "the task"
        phrase = Phrase(past: "Re-opened \(what)", future: "re-open \(what)")
    case "task.add":
        let what = quoted(.added) ?? "the task"
        phrase = Phrase(past: "Added \(what)", future: "add \(what)")
    case "task.setText":
        let what = quoted(.renamed) ?? "the new text"
        phrase = Phrase(past: "Renamed to \(what)", future: "rename it to \(what)")
    case "task.setDue":
        if let when = changes.first(where: { $0.kind == .retimed })?.now {
            phrase = Phrase(past: "Due \(when)", future: "set it due \(when)")
        } else {
            phrase = Phrase(past: "Cleared the due date", future: "clear the due date")
        }
    case "task.wrap":
        let n = count(.moved)
        let what = "\(n) task\(n == 1 ? "" : "s") under \(quoted(.added) ?? "a new parent")"
        phrase = Phrase(past: "Wrapped \(what)", future: "wrap \(what)")
    case "task.unwrap":
        let what = quoted(.removed) ?? "the parent"
        phrase = Phrase(past: "Dissolved \(what)", future: "dissolve \(what)")
    case "task.delete":
        let what = "\(quoted(.removed) ?? "the task")\(extra(count(.removed)))"
        phrase = Phrase(past: "Deleted \(what)", future: "delete \(what)")
    case "task.focus", "task.diveIn":
        let what = quoted(.focused) ?? "nothing"
        phrase = Phrase(past: "Focus on \(what)", future: "put focus on \(what)")
    default:
        let n = changes.count
        let what = n == 0 ? "Nothing changed" : "\(n) change\(n == 1 ? "" : "s")"
        phrase = Phrase(past: what, future: "make \(n) change\(n == 1 ? "" : "s")")
    }

    // A completion moves focus, and where it went is what you want to know next — but not when the
    // sentence is already about focus, and not when focus landed on the very task being described,
    // which is what adding a child task does.
    let subject = quoted(.completed) ?? quoted(.added) ?? quoted(.renamed)
    if action != "task.focus", action != "task.diveIn",
       let landed = quoted(.focused), landed != subject {
        phrase = phrase.appending(past: "Focus moves to \(landed)", future: "moving focus to \(landed)")
    }
    return phrase
}
