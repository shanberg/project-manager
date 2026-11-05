import Foundation

/// Files on a cloud drive — iCloud Drive, Google Drive, any File Provider — read without freezing Folio.
///
/// - An online-only file is a placeholder (`ls -lO` says `dataless`). Reading it downloads it.
/// - A stalled provider holds that read in the kernel indefinitely; on the main thread, the app freezes
///   (2026-11-05, a launch hang in `read()` of a `.canvas`).
/// - `stat` and xattrs still answer for such a file. Contents don't.
/// - So: ask `isCloudOnly` before reading anything the user didn't open, and read contents through
///   `BackgroundFileRead`, never on main.
enum CloudFile {
    /// Whether `url` is a placeholder for a file that is in the cloud and not on this Mac. The file's
    /// `SF_DATALESS` flag, from `stat`, which never triggers a download.
    nonisolated static func isCloudOnly(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }
}

/// A file's bytes read off the main thread, answered on main.
///
/// - Concurrent: a read that never returns holds its own thread, not the others' reads.
/// - The answer is nil for a file that can't be read.
@MainActor
enum BackgroundFileRead {
    nonisolated static let queue = DispatchQueue(label: "Folio.file-reads", qos: .userInitiated,
                                                 attributes: .concurrent)

    /// How a file is read when the caller doesn't say. A test stands in a slow or stuck one.
    nonisolated(unsafe) static var reader: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }

    static func read(_ url: URL, with reader: (@Sendable (URL) -> Data?)? = nil,
                     then answer: @escaping @MainActor (Data?) -> Void) {
        let reader = reader ?? Self.reader
        queue.async {
            let data = reader(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { answer(data) }
            }
        }
    }
}
