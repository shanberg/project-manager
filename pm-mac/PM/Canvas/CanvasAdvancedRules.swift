import AppKit
import WebKit

/// The filtering a content blocker cannot express: scriptlets and extended CSS.
///
/// `WKContentRuleList` can refuse a request and hide a selector. It cannot set the cookie a site
/// reads to decide whether to nag you, and it cannot select "the block that says Advertisement".
/// Filter lists carry thousands of both, and on a dashboard card they are the rules that matter most,
/// because what covers a small card is usually a consent dialog rather than a banner ad.
///
/// AdGuard publish reference implementations of both halves. Both are GPL-3.0 and together about
/// 3 MB of JavaScript, which would reopen the licensing question the rest of this feature is arranged
/// to avoid, and put three megabytes of somebody else's code into every page PM shows. Neither is
/// needed: across the four lists PM ships, three scriptlets account for 93% of scriptlet uses and one
/// pseudo-class for 91% of extended CSS. `Resources/AdvancedRules/advanced.js` implements that
/// subset — 90% of the rules — and `scripts/pack-advanced.py` prints what it drops so the number
/// stays honest.
@MainActor
enum CanvasAdvancedRules {
    /// The interpreter with the rule table baked into it, or nil if it could not be built.
    private static var script: WKUserScript?

    /// Read the table and interpreter out of the bundle and fuse them into one user script.
    ///
    /// Done once: the table is the same for every card, and `WKUserScript` is immutable and cheap to
    /// hand to any number of configurations.
    static func prepare() {
        guard let js = Bundle.main.url(forResource: "advanced", withExtension: "js",
                                       subdirectory: "AdvancedRules"),
              let table = Bundle.main.url(forResource: "advanced", withExtension: "json.deflate",
                                          subdirectory: "AdvancedRules") else {
            return Log.write("canvas blocking: no advanced rules in the bundle")
        }
        guard let source = try? String(contentsOf: js, encoding: .utf8),
              let packed = try? Data(contentsOf: table),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data else {
            return Log.write("canvas blocking: advanced rules would not load")
        }
        // Injected in the page's own world, which is where scriptlets are meant to run: a cookie set
        // for a page's benefit has to be one the page can read. The file defines no globals.
        script = WKUserScript(source: source.replacingOccurrences(of: "__PM_RULES__",
                                                                  with: String(decoding: raw, as: UTF8.self)),
                              injectionTime: .atDocumentStart,
                              forMainFrameOnly: false)
        Log.write(String(format: "canvas blocking: advanced rules ready (%.2f MB)",
                         Double(raw.count) / 1e6))
    }

    /// Give a configuration the interpreter, on the same terms as the rule lists — a site excused
    /// from filtering is excused from all of it, which is the only version anyone could reason about.
    static func attach(to configuration: WKWebViewConfiguration, for host: String?) {
        guard let script,
              CanvasBlockPolicy.filters(host, unfiltered: CanvasContentBlocker.unfilteredSites) else { return }
        configuration.userContentController.addUserScript(script)
    }
}
