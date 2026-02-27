import Foundation

public func parseTodos(notes: ProjectNotes) throws -> [Todo] {
    let todoLinePattern: NSRegularExpression
    do {
        todoLinePattern = try NSRegularExpression(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
    } catch {
        throw PmError.notesRegexError(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
    }
    var todos: [Todo] = []
    for session in notes.sessions {
        let context = session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            guard let m = todoLinePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r1 = Range(m.range(at: 1), in: line),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else { continue }
            _ = String(line[r1])
            let checked = line[r2].lowercased() == "x"
            let text = String(line[r3])
            todos.append(Todo(
                text: text,
                checked: checked,
                rawLine: line,
                context: context
            ))
        }
    }
    return todos
}
