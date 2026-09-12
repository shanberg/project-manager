import Foundation
import PmLib

/// What a linked page calls itself, for the label on a link nobody typed a label for.
///
/// Adding a link to a project is a URL and, optionally, a label — and the label is the half people
/// skip, because they have just pasted a URL of a page whose name is right there in its tab. So the
/// name is asked for rather than left blank, and the row reads as the thing it points at instead of as
/// a hostname and a path.
///
/// **Three answers, and the first two cost nothing.** A page any web card has ever loaded is already
/// named in `CanvasPageTitles`, which is keyed by address and shared across boards; a link dragged out
/// of a browser arrives with its name on the pasteboard beside it. The fetch is the third answer and
/// only the third — most links added inside PM never reach it.
///
/// **It is the favicon fetch's switch, and deliberately so.** This goes to the linked site, asks it for
/// its own front page, and reads one tag — the same claim `FaviconLoader` makes, to the same host, for
/// the same reason, and the pane already carries the sentence explaining it. A second toggle would be a
/// second decision about one thing. The session is ephemeral and the user agent is not spoofed, both
/// for `FaviconLoader`'s reasons: an icon and a title are public, and nothing about fetching either
/// should carry who you are or pretend to be a browser.
@MainActor
final class LinkTitleLoader {
    static let shared = LinkTitleLoader()

    private var inflight: [String: Task<String?, Never>] = [:]
    /// Addresses that came back with nothing worth calling them. Kept so a details brief full of
    /// unnamed links doesn't retry the same dead host on every redraw.
    private var misses: Set<String> = []

    private init() {}

    /// The name of the page at `address` — what is already known, then what the page says.
    ///
    /// Nil when the page doesn't say, when the fetch fails, and when the name it gives is the address
    /// or the host: `CanvasPageTitles.adds` is what decides that, and it is the same test a card uses
    /// before putting a title under its own hostname. A label that repeats the URL beside it is worse
    /// than no label.
    func title(for address: String) async -> String? {
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // A page some card has loaded, on this board or any other. No network, no waiting.
        if let known = CanvasPageTitles.of(key) { return known }
        guard FaviconLoader.isEnabled, !misses.contains(key), let url = URL(string: key),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if let task = inflight[key] { return await task.value }

        let task = Task<String?, Never> { await Self.fetch(url) }
        inflight[key] = task
        let found = await task.value
        inflight[key] = nil
        guard let found, CanvasPageTitles.adds(found, to: key) else {
            misses.insert(key)
            return nil
        }
        // Written where the cards read it too, so naming a link also names every card on that page.
        CanvasPageTitles.remember(found, for: key)
        return found
    }

    // MARK: The fetch

    /// A session with no cookie jar of its own and no share in anyone else's — see `FaviconLoader`,
    /// which explains at length why a title fetch must not be able to carry your Jira session.
    nonisolated private static let anonymous = URLSession(configuration: .ephemeral)

    /// How much of a page is read before giving up on finding its head.
    ///
    /// The title is in the first tag of the document or it is somewhere this has no business reading
    /// to. The stream also stops at `</head>`, which on a normal page arrives long before this does —
    /// the cap is for the page that never closes its head, not for the ordinary case.
    private static let limit = 128 * 1024

    nonisolated private static func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await anonymous.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                  type.contains("html") else { return nil }
            return HTMLTitle.read(decode(try await head(of: stream), as: type))
        } catch {
            return nil
        }
    }

    /// Read until the document's head closes, or until `limit`.
    ///
    /// Byte at a time because that is what `URLSession.bytes` gives, and a rolling match rather than
    /// re-examining the buffer, which would be quadratic in the size of the page for the sake of a
    /// seven-character needle. The fold by `0x20` is an ASCII lower-case and exact for every character
    /// in `</head>`.
    nonisolated private static func head(of stream: URLSession.AsyncBytes) async throws -> [UInt8] {
        let needle = Array("</head>".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(8 * 1024)
        var matched = 0
        for try await byte in stream {
            bytes.append(byte)
            let folded = byte | 0x20
            if folded == needle[matched] | 0x20 {
                matched += 1
                if matched == needle.count { break }
            } else {
                matched = folded == needle[0] | 0x20 ? 1 : 0
            }
            if bytes.count >= limit { break }
        }
        return bytes
    }

    /// Text out of bytes, in the encoding the response claimed.
    ///
    /// UTF-8 unless the header says otherwise, which covers everything written this decade; the named
    /// fallback is there because the pages that predate that are exactly the ones still linked out of
    /// somebody's notes. A page whose bytes don't decode gives a mangled title rather than none, which
    /// is a label to correct rather than a blank to fill in.
    nonisolated private static func decode(_ bytes: [UInt8], as contentType: String) -> String {
        guard let mark = contentType.range(of: "charset=") else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let name = contentType[mark.upperBound...]
            .prefix { !$0.isWhitespace && $0 != ";" && $0 != "\"" }
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding(String(name) as CFString))
        guard encoding != kCFStringEncodingInvalidId,
              let text = String(data: Data(bytes), encoding: .init(rawValue: encoding)) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        return text
    }
}
