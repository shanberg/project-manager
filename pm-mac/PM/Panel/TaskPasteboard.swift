import AppKit
import UniformTypeIdentifiers

/// A task selection's identity outside the panel — what it becomes on the pasteboard and on a drag.
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
}
