import AppKit

/// The page in front of a web browser, as the quick bar's page chip carries it into a project.
struct BrowserPage: Equatable {
    let url: URL
    let title: String
    /// The browser's name, for the chip's spoken description.
    let browser: String

    /// What the chip shows: the page's title, or its host when the page has none.
    var label: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed
    }
}

/// Reads the front tab of the browser the quick bar was summoned over.
///
/// **Apple Events, not Accessibility.** The scripting dictionaries of Safari and the Chromium browsers
/// answer "the front window's current tab" directly, and macOS asks once per browser. Accessibility
/// would reach Firefox too, but it is a grant over every app on the Mac, which is too much to ask for
/// this. Firefox has no scripting dictionary, so a page there gets no chip.
///
/// **Off the main queue.** The first read from each browser waits on the consent prompt, and any read
/// waits on a browser that may be busy; the bar must be up and typing before either answers.
enum BrowserTab {
    enum Family: Equatable {
        /// `current tab`, and `name` for its title.
        case safari
        /// `active tab`, and `title` for its title. Chrome, Brave, Edge, Arc, Vivaldi.
        case chromium
    }

    static func family(of bundleID: String) -> Family? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
             "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
             "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium":
            return .chromium
        default:
            return nil
        }
    }

    /// A browser that isn't on the list, by its scripting dictionary: Chromium's derivatives — Helium,
    /// Thorium, the ungoogled builds — keep Chrome's `active tab`, and Safari's keep `current tab`.
    static func family(ofAppAt app: URL) -> Family? {
        guard let info = Bundle(url: app)?.infoDictionary,
              let name = info["OSAScriptingDefinition"] as? String,
              let sdef = try? String(contentsOf: app.appending(path: "Contents/Resources/\(name)"),
                                     encoding: .utf8) else { return nil }
        guard sdef.contains("name=\"URL\"") else { return nil }
        if sdef.contains("name=\"active tab\"") { return .chromium }
        if sdef.contains("name=\"current tab\"") { return .safari }
        return nil
    }

    /// The script that returns `{URL, title}` of the front tab, or an empty list with no window open.
    static func script(for bundleID: String) -> String? {
        family(of: bundleID).map { script(for: bundleID, family: $0) }
    }

    static func script(for bundleID: String, family: Family) -> String {
        let tab = family == .safari ? "current tab" : "active tab"
        let title = family == .safari ? "name" : "title"
        return """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return {}
            set theTab to \(tab) of front window
            return {URL of theTab, \(title) of theTab}
        end tell
        """
    }

    /// A page from the script's two strings. Nil for anything a card can't show: a new-tab page, a
    /// settings page, `about:blank`.
    static func page(url: String?, title: String?, browser: String) -> BrowserPage? {
        guard let url, let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
        return BrowserPage(url: parsed, title: title ?? "", browser: browser)
    }

    /// Read `app`'s front tab and hand it to `then` on the main queue — nil when `app` isn't a browser
    /// this can read, has no window, shows no web page, or was refused permission.
    @MainActor
    static func read(from app: NSRunningApplication,
                     then: @escaping @MainActor (BrowserPage?) -> Void) {
        guard let bundleID = app.bundleIdentifier,
              let family = family(of: bundleID) ?? app.bundleURL.flatMap(family(ofAppAt:)) else {
            then(nil)
            return
        }
        let source = script(for: bundleID, family: family)
        let browser = app.localizedName ?? bundleID
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let page: BrowserPage?
            if let result, result.numberOfItems == 2 {
                page = Self.page(url: result.atIndex(1)?.stringValue,
                                 title: result.atIndex(2)?.stringValue, browser: browser)
            } else {
                page = nil
            }
            DispatchQueue.main.async {
                if let error {
                    // -1743 is "not authorised", the answer once somebody has said no in System Settings.
                    Log.write("browser tab: \(bundleID) refused: \(error[NSAppleScript.errorNumber] ?? "?")")
                }
                then(page)
            }
        }
    }

    /// One at a time: `NSAppleScript` is not safe to run on two threads at once.
    private static let queue = DispatchQueue(label: "Folio.BrowserTab", qos: .userInitiated)
}
