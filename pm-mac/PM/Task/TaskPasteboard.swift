import AppKit
import UniformTypeIdentifiers
import PmLib

/// A task selection's identity outside the app — what it becomes on the pasteboard and on a drag.
///
/// Tasks travel as two representations at once:
///
///   * **`pmTaskKeys`** (private, own-process): the `"session:line"` keys of the dragged tasks. This
///     is what the task list's own drop delegate recognizes, so an in-app reorder is never confused
///     with a text drag from another app.
///   * **`public.utf8-plain-text`**: the tasks rendered as markdown (`PMStore.markdown(for:)`) — real
///     checkbox lines with their nesting, so a drag into any editor, or a ⌘C into any document, lands
///     as something a person (and these notes) can read back.
///
/// The private type comes first, so our own list prefers it while every other app sees the markdown.
enum TaskPasteboard {
    /// The private drag type carrying task keys. Declared in the app's `Info.plist`
    /// (`UTExportedTypeDeclarations`, generated from `project.yml`) so the system knows it's ours.
    static let taskKeysType = UTType(exportedAs: "com.stuarthanberg.pm.task-keys", conformingTo: .data)

    /// Keys are joined one per line — the same shape both ends of the drag agree on.
    private static func encode(keys: [String]) -> Data { Data(keys.joined(separator: "\n").utf8) }

    static func decode(keys data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// The item provider for a drag of `keys`, whose public face is `markdown`.
    static func itemProvider(keys: [String], markdown: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: taskKeysType.identifier,
                                            visibility: .ownProcess) { completion in
            completion(encode(keys: keys), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                            visibility: .all) { completion in
            completion(Data(markdown.utf8), nil)
            return nil
        }
        return provider
    }

    /// Put a task selection on the general pasteboard as markdown. Only the public representation is
    /// written: the keys are positions within one document, so they'd mean nothing on paste.
    static func copy(markdown: String) {
        guard !markdown.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    // MARK: Reading text back in

    /// Turn text into tasks — the inverse of `PMStore.markdown(for:)`, and the reason ⌘C had nothing
    /// to answer it.
    ///
    /// Deliberately lenient about what it accepts, because the text is as likely to have come from a
    /// meeting note or a chat message as from this app. A checkbox line keeps its state and its
    /// nesting; a bare list item becomes an open task; a plain line becomes an open task of its own.
    /// What it will not do is invent structure: a paragraph is one task, not a guess at three.
    ///
    /// Indentation is read in whatever unit the text actually uses rather than assumed to be two
    /// spaces — an editor set to four, or to tabs, is the common case and would otherwise land every
    /// child at the same depth as its parent.
    static func parse(_ text: String) -> [PastedTask] {
        struct Raw {
            var indent: Int
            var text: String
            var due: String?
            var checked: Bool
        }

        var rows: [Raw] = []
        for line in text.components(separatedBy: .newlines) {
            // Tabs first, so a tab-indented file measures in the same unit as a space-indented one.
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let indent = expanded.prefix { $0 == " " }.count
            var body = expanded.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            // A list marker, if there is one: "- ", "* ", "+ ", "1. ".
            body = stripListMarker(body)

            // A checkbox, if there is one.
            var checked = false
            if body.count >= 3, body.hasPrefix("[") {
                let box = body[body.index(body.startIndex, offsetBy: 1)]
                if body[body.index(body.startIndex, offsetBy: 2)] == "]",
                   box == " " || box == "x" || box == "X" {
                    checked = (box != " ")
                    body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            }

            // A trailing `due: YYYY-MM-DD`, which is how this app writes one.
            var due: String?
            if let range = body.range(of: #"\s+due:\s*\d{4}-\d{2}-\d{2}\s*$"#,
                                      options: [.regularExpression]) {
                due = String(body[range]).replacingOccurrences(of: "due:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                body = String(body[body.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }

            // The focus marker this app appends. A pasted task doesn't carry the project's attention
            // with it — there is one focused task and pasting five shouldn't nominate one of them.
            if body.hasSuffix(" @") { body = String(body.dropLast(2)).trimmingCharacters(in: .whitespaces) }

            guard !body.isEmpty else { continue }
            rows.append(Raw(indent: indent, text: body, due: due, checked: checked))
        }
        guard !rows.isEmpty else { return [] }

        // Indents to depths. The step is the smallest non-zero gap between a line and the shallowest
        // one, which reads two-space, four-space and tab files alike without being told which it is.
        let base = rows.map(\.indent).min() ?? 0
        let offsets = Set(rows.map { $0.indent - base }).filter { $0 > 0 }
        let step = offsets.min() ?? 2
        return rows.map {
            PastedTask(depth: ($0.indent - base) / step, text: $0.text, due: $0.due, checked: $0.checked)
        }
    }

    private static func stripListMarker(_ body: String) -> String {
        for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) {
            return String(body.dropFirst(marker.count))
        }
        // "1. ", "12) " — an ordered list. The number is the editor's, not the task's.
        if let range = body.range(of: #"^\d+[.)]\s+"#, options: [.regularExpression]) {
            return String(body[range.upperBound...])
        }
        return body
    }

    /// What's on the general pasteboard, as tasks. Empty when there's nothing paste-able there.
    static func tasksOnPasteboard() -> [PastedTask] {
        guard let text = NSPasteboard.general.string(forType: .string) else { return [] }
        return parse(text)
    }
}

/// Async reads of a dropped item, so a drop handler can `await` what arrived instead of nesting
/// completion handlers inside a `DropDelegate` that has to answer synchronously.
extension NSItemProvider {
    /// The dropped file's URL, or nil if this provider isn't carrying one.
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// The dropped text. `NSString` rather than `String`, because `String` isn't an
    /// `NSItemProviderReading` — the bridged class is what the pasteboard actually vends.
    func loadText() async -> String? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSString.self) { text, _ in
                continuation.resume(returning: (text as? NSString) as String?)
            }
        }
    }
}
