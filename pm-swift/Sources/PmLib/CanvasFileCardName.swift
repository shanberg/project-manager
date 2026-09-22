import Foundation

// What a file card is called and what stands beside it — the other half of `canvasCardSummary`, here
// for the same reason (docs/items.md D2): a lens that runs without the app still names a card the way
// the board does.

/// What a file card is called when it is one line: the file's name without its extension.
///
/// A project's notes file is named for the project, so the `Notes - ` prefix is the one part of the
/// filename that says nothing — and at this zoom the card is one line of text, which makes eight
/// wasted characters a third of it. Every board of projects otherwise reads as a row of cards all
/// starting with the same word.
///
/// Shared by the card's zoomed-out face and Add Card from Canvas, so the list names a card the way the
/// board does. A folder keeps its whole name: a dot in one isn't an extension.
public func canvasFileCardName(_ path: String, isFolder: Bool = false) -> String {
    if isFolder { return (path as NSString).lastPathComponent }
    let name = ((path as NSString).deletingPathExtension as NSString).lastPathComponent
    guard projectFolder(ofNotesPath: path) != nil, name.hasPrefix("Notes - ") else { return name }
    return String(name.dropFirst("Notes - ".count))
}

/// The SF Symbol a file card draws when it is one line, by the kind of file it is.
public func canvasFileSymbol(_ path: String, isFolder: Bool = false) -> String {
    if isFolder { return "folder" }
    switch (path as NSString).pathExtension.lowercased() {
    case "md", "markdown", "txt": return "doc.text"
    case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return "photo"
    case "pdf": return "doc.richtext"
    default: return "doc"
    }
}
