import AppKit
import WebKit

/// A file a page handed over.
///
/// **Every download used to fail silently.** A response WebKit cannot display — a CSV, a zip, a signed
/// PDF export — arrived, could not be shown, and was dropped: the "Export" button on a dashboard did
/// nothing, twice, and then you opened the browser. WebKit has offered `WKDownload` since Monterey and
/// the card was answering none of it.
///
/// Files go to **Downloads**, under the name the site suggested, uniquified rather than overwritten —
/// the same bargain every browser on the machine has already made with that folder, and the folder
/// somebody will look in without being told. What PM adds is being told: the card's window says what
/// arrived and offers to show it, because a download with no browser window and no progress bar is
/// otherwise indistinguishable from the silence this replaces.
///
/// One of these per download, holding itself alive — `WKDownload` keeps only a weak delegate, so a
/// download whose delegate is a local variable is a download that stops the moment the function
/// returns.
@MainActor
final class CanvasDownload: NSObject, WKDownloadDelegate {
    /// Every download in flight, keeping itself alive until it finishes or fails.
    private static var running: Set<CanvasDownload> = []

    /// What to say when it is over: the message, and the file to reveal if there is one.
    private let report: (String, URL?) -> Void
    private var destination: URL?

    /// Take this download over. The returned object is retained until it ends; the caller keeps
    /// nothing.
    @discardableResult
    static func take(_ download: WKDownload, report: @escaping (String, URL?) -> Void)
        -> CanvasDownload {
        let holder = CanvasDownload(report: report)
        running.insert(holder)
        download.delegate = holder
        return holder
    }

    private init(report: @escaping (String, URL?) -> Void) {
        self.report = report
    }

    private func done(_ message: String, _ file: URL?) {
        report(message, file)
        Self.running.remove(self)
    }

    // MARK: WKDownloadDelegate

    /// Where it lands.
    ///
    /// Never over something already there: a second export of `report.csv` is `report 2.csv`, not the
    /// first one gone. WebKit refuses to write over an existing file anyway — `completionHandler(url)`
    /// on an occupied path fails the download — so the choice is between uniquifying and failing, and
    /// only one of those is what anybody meant by clicking Export twice.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let folder else {
            done("Couldn\u{2019}t find your Downloads folder.", nil)
            return completionHandler(nil)
        }
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let target = unique(name, in: folder)
        destination = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination else { return done("Downloaded.", nil) }
        done("Saved \u{201C}\(destination.lastPathComponent)\u{201D} to Downloads.", destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        // A half-written file is worse than none: it is the right name and the wrong contents, and it
        // will be opened one day by somebody who has forgotten this happened.
        if let destination { try? FileManager.default.removeItem(at: destination) }
        done("Download failed: \(error.localizedDescription)", nil)
    }

    /// A download that redirects to somewhere it needs a name and password for.
    func download(_ download: WKDownload,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: Naming it

    private func unique(_ name: String, in folder: URL) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for n in 2...999 {
            let numbered = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let next = folder.appendingPathComponent(numbered)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return folder.appendingPathComponent("\(base) \(UUID().uuidString).\(ext)")
    }
}
