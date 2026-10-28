import XCTest

/// What the quick bar asks a browser for, and which answers become a page chip.
final class BrowserTabTests: XCTestCase {
    func testKnowsSafariAndChromiumFamilies() {
        XCTAssertEqual(BrowserTab.family(of: "com.apple.Safari"), .safari)
        XCTAssertEqual(BrowserTab.family(of: "com.google.Chrome"), .chromium)
        XCTAssertEqual(BrowserTab.family(of: "com.brave.Browser"), .chromium)
        XCTAssertEqual(BrowserTab.family(of: "company.thebrowser.Browser"), .chromium)
        // No scripting dictionary: no chip, rather than a script that fails every summon.
        XCTAssertNil(BrowserTab.family(of: "org.mozilla.firefox"))
        XCTAssertNil(BrowserTab.script(for: "com.apple.finder"))
    }

    func testUnlistedBrowsersAreKnownByTheirDictionary() throws {
        // Helium, a Chromium derivative that isn't on the list; skipped where it isn't installed.
        guard let helium = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.imput.helium")
        else { throw XCTSkip("Helium isn't installed") }
        XCTAssertEqual(BrowserTab.family(ofAppAt: helium), .chromium)
        let safari = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"))
        XCTAssertEqual(BrowserTab.family(ofAppAt: safari), .safari)
        let finder = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        XCTAssertNil(BrowserTab.family(ofAppAt: finder))
    }

    func testScriptsCompile() throws {
        for id in ["com.apple.Safari", "com.google.Chrome"] {
            let source = try XCTUnwrap(BrowserTab.script(for: id))
            var error: NSDictionary?
            // Compiling needs the app's dictionary; skipped where the browser isn't installed.
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { continue }
            XCTAssertTrue(NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false,
                          "\(id): \(String(describing: error))")
        }
    }

    func testOnlyWebPagesBecomeChips() {
        XCTAssertNotNil(BrowserTab.page(url: "https://example.com/a", title: "A", browser: "Safari"))
        XCTAssertNil(BrowserTab.page(url: "chrome://newtab/", title: "New Tab", browser: "Chrome"))
        XCTAssertNil(BrowserTab.page(url: "about:blank", title: "", browser: "Safari"))
        XCTAssertNil(BrowserTab.page(url: nil, title: nil, browser: "Safari"))
    }

    func testLabelFallsBackToHost() {
        let untitled = BrowserTab.page(url: "https://example.com/a", title: "  ", browser: "Safari")
        XCTAssertEqual(untitled?.label, "example.com")
    }
}
