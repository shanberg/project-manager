import AppKit
import WebKit

/// Cross between named workspaces of web tiles, cold, the way `tools/web-perf-bench/run-chrome.mjs`
/// does in Chrome, and write the same events so `report.py` can put the two side by side.
///
/// **Dev only, and inert unless `PM_LAYOUT_BENCH` names a run folder** prepared by
/// `tools/web-perf-bench/run-folio.sh`: it holds `bench.canvas` (one link card per layout and site, so no
/// crossing is a handover), `scenario.json`, and `probe.js`. Events go to `events.jsonl` there.
///
/// A layout is a workspace whose columns are the scenario's. Each step: freeze every page on the boards
/// out of sight (the leaving layout stays live, as it would), forget their resume state, snapshots and
/// visits so the next load is a load, then cross. Per tile it records the card's own milestones
/// (`mark`) and the probe's; then scrolls each tile with real wheel events at its centre.
@MainActor
enum LayoutBench {

    static let folder: URL? = ProcessInfo.processInfo.environment["PM_LAYOUT_BENCH"]
        .map { URL(fileURLWithPath: $0) }

    static var isActive: Bool { folder != nil }

    private static var warm: Bool { ProcessInfo.processInfo.environment["PM_BENCH_WARM"] == "1" }
    /// Experiment: put a loading page on screen at once instead of at alpha 0 until `revealPage`.
    static let showsPagesAtOnce = ProcessInfo.processInfo.environment["PM_BENCH_SHOW_AT_ONCE"] == "1"
    /// The control: plain WKWebViews in a plain window at Folio's tile frames — same WebKit, same
    /// sign-ins, same user agent, none of Folio's boards, cards, block lists or scripts.
    static let bare = ProcessInfo.processInfo.environment["PM_BENCH_BARE"] == "1"
    private static var barePages: [String: WKWebView] = [:]
    private static let bareMarks = BareMarks()
    private static var unfiltered: Bool { ProcessInfo.processInfo.environment["PM_BENCH_UNFILTERED"] == "1" }

    // MARK: Scenario

    private struct Scenario: Decodable {
        struct Site: Decodable { var url: String; var ready: String; var notReady: String? }
        struct Layout: Decodable { var name: String; var columns: [[String]] }
        struct Dwell: Decodable {
            var readyTimeoutSeconds: Double; var scrollSecondsPerTile: Double; var quietSeconds: Double
        }
        var sites: [String: Site]
        var layouts: [Layout]
        var rounds: Int
        var dwell: Dwell
    }

    private static var scenario: Scenario?
    private static var probe = ""
    private static var events: FileHandle?
    private static var canvas: URL? { folder?.appending(path: "bench.canvas") }

    /// The card id for a site in a layout, as `run-folio.sh` wrote it into the canvas.
    private static func cardID(_ layout: String, _ site: String) -> String { "\(layout).\(site)" }

    // MARK: Hooks the card calls

    /// When each card was asked for a page, and each milestone since, in epoch ms.
    private static var native: [String: [String: Double]] = [:]

    static func mark(_ card: String, _ what: String) {
        guard isActive else { return }
        let now = Date().timeIntervalSince1970 * 1000
        if native[card]?[what] == nil { native[card, default: [:]][what] = now }
        // Every transition, not just the first: a page that is asked for twice was restarted.
        log("card", ["card": card, "what": what])
    }

    /// The probe, with the site's ready selector, for every page of every card.
    static func install(in configuration: WKWebViewConfiguration, for host: String?) {
        guard isActive, let scenario, let host else { return }
        let site = scenario.sites.values.first { URL(string: $0.url)?.host() == host }
        let selector = (try? JSONEncoder().encode(site?.ready ?? "body")).flatMap { String(data: $0, encoding: .utf8) }
        let notReady = (try? JSONEncoder().encode(site?.notReady)).flatMap { String(data: $0, encoding: .utf8) }
        let source = "window.__benchReadySelector = \(selector ?? "\"body\"");\n"
            + "window.__benchNotReadySelector = \(notReady ?? "null");\n" + probe
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: Running

    static func startIfAsked() {
        guard let folder, let canvas else { return }
        do {
            scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: folder.appending(path: "scenario.json")))
            probe = try String(contentsOf: folder.appending(path: "probe.js"), encoding: .utf8)
        } catch {
            return Log.write("LAYOUTBENCH declined: \(error)")
        }
        let file = folder.appending(path: "events.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        events = try? FileHandle(forWritingTo: file)
        if unfiltered, let scenario {
            for site in scenario.sites.values {
                if let host = URL(string: site.url)?.host() { CanvasContentBlocker.setFilters(false, host: host) }
            }
        }
        let env = ProcessInfo.processInfo.environment
        let signingIn = env["PM_BENCH_SIGNIN"] == "1"
        if bare {
            let screen = NSScreen.screens.max { $0.frame.width < $1.frame.width } ?? NSScreen.main
            let window = NSWindow(contentRect: screen?.visibleFrame ?? .zero,
                                  styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false, screen: screen)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            if let screen { window.setFrame(screen.visibleFrame, display: true) }
            window.makeKeyAndOrderFront(nil)
            bareWindow = window
            Task { @MainActor in await runBare(in: window) }
            return
        }
        CanvasContentBlocker.onReady {
            _ = WindowManager.shared.open(canvas: canvas) { controller in
                guard let window = controller.window else { return }
                let screen = NSScreen.screens.max { $0.frame.width < $1.frame.width } ?? NSScreen.main
                if let screen { window.setFrame(screen.visibleFrame, display: true) }
                window.makeKeyAndOrderFront(nil)
                Task { @MainActor in
                    // Sign-ins copied from a browser profile (`Site ▸ Copy Sign-In From`, the same code).
                    if let from = env["PM_BENCH_COPY_COOKIES"], let scenario,
                       let source = CanvasCookieImport.sources().first(where: { $0.title == from }) {
                        for host in Set(scenario.sites.values.compactMap { URL(string: $0.url)?.host() }) {
                            let n = (try? await CanvasCookieImport.copy(from: source, host: host,
                                                                       into: CanvasWebSession.store(named: nil))) ?? -1
                            log("cookies", ["host": host, "copied": n])
                        }
                    }
                    // Sign in by hand: the board stays up, untiled, until you quit.
                    if signingIn { return log("signin") }
                    await run(in: window)
                }
            }
        }
    }

    private static func log(_ kind: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["t"] = (Date().timeIntervalSince1970 * 1000).rounded()
        line["kind"] = kind
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
        events?.write(data + Data("\n".utf8))
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func boards(in window: NSWindow) -> [CanvasBoardView] {
        func walk(_ view: NSView) -> [CanvasBoardView] {
            if let board = view as? CanvasBoardView { return [board] }
            return view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk) ?? []
    }

    private static func visibleBoard(in window: NSWindow) -> CanvasBoardView? {
        boards(in: window).first { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func run(in window: NSWindow) async {
        guard let scenario else { return }
        await sleep(2)
        guard let board = visibleBoard(in: window) else { return log("declined", ["why": "no board"]) }
        let screen = window.screen
        log("setup", ["screen": [screen?.frame.width ?? 0, screen?.frame.height ?? 0, screen?.backingScaleFactor ?? 0],
                      "window": [window.frame.width, window.frame.height], "warm": warm, "unfiltered": unfiltered, "showAtOnce": showsPagesAtOnce, "bare": bare,
                      "pid": ProcessInfo.processInfo.processIdentifier])
        // One workspace (and so one tab, one pane, one board) per layout.
        for layout in scenario.layouts {
            let columns = layout.columns.map { column in
                CanvasTiling.Column(column.map { CanvasTiling.Tile([cardID(layout.name, $0)]) })
            }
            let ids = columns.flatMap { $0.tiles.flatMap(\.cards) }
            let plan = CanvasViewState.Tiling(ids: ids, arrangement: .grid,
                                              masterFraction: CanvasTiling.savedMasterFraction,
                                              sizes: nil, columns: columns)
            CanvasWorkspaces.save(plan, as: layout.name, for: board.store.url)
            guard visibleBoard(in: window)?.onTileAsWorkspace(plan) == true else {
                return log("declined", ["why": "workspace \(layout.name) would not open"])
            }
            await sleep(1)
        }
        // Back to the canvas, so the first crossing is one, then put every page out so round 0 starts as
        // cold as the rest.
        visibleBoard(in: window)?.onGoToCanvas()
        await sleep(1)
        await coolEverything(in: window, but: nil)
        var tileFrames: [String: [[String: Any]]] = [:]
        for round in 0..<scenario.rounds {
            for layout in scenario.layouts {
                if !warm { await coolEverything(in: window, but: visibleBoard(in: window)) }
                guard let from = visibleBoard(in: window) else { return log("declined", ["why": "lost the board"]) }
                native = [:]
                let start = Date().timeIntervalSince1970 * 1000
                log("layout-start", ["layout": layout.name, "round": round])
                let host = HostFrames(on: from.window?.contentView ?? from)
                log("cross", ["layout": layout.name, "round": round, "media": CACurrentMediaTime()])
                cross(from, to: layout.name)
                await measure(layout, round: round, start: start, host: host, tileFrames: &tileFrames)
            }
        }
        finish(tileFrames)
    }

    /// The crossing itself, in a frame of its own so a profile can find it by name.
    @inline(never) private static func cross(_ from: CanvasBoardView, to name: String) {
        from.onGoToWorkspace(name)
    }

    /// Everything after the crossing: wait for every tile to settle, idle, scroll each, idle, report.
    private static func measure(_ layout: Scenario.Layout, round: Int, start: Double, host: HostFrames,
                                tileFrames: inout [String: [[String: Any]]]) async {
        guard let scenario else { return }
        do {
            do {
                let sites = layout.columns.flatMap { $0 }
                let ids = sites.map { cardID(layout.name, $0) }
                // Every tile settled, or the timeout.
                let deadline = Date().addingTimeInterval(scenario.dwell.readyTimeoutSeconds)
                while Date() < deadline {
                    var settled = 0
                    for id in ids where await js(id, "window.__bench?.marks?.settled") as? Double != nil { settled += 1 }
                    if settled == ids.count { break }
                    await sleep(0.1)
                }
                let readyMs = Date().timeIntervalSince1970 * 1000 - start
                log("crossing", ["layout": layout.name, "round": round].merging(host.finish()) { a, _ in a })
                log("layout-settled", ["layout": layout.name, "round": round, "ms": readyMs])
                await phase(ids) { _ in "idle" }
                await sleep(scenario.dwell.quietSeconds)
                for id in ids {
                    await phase(ids) { $0 == id ? "scroll" : "bg" }
                    await scroll(id, seconds: scenario.dwell.scrollSecondsPerTile)
                }
                await phase(ids) { _ in "idle2" }
                await sleep(scenario.dwell.quietSeconds)
                for (id, site) in zip(ids, sites) {
                    let report = await js(id, "JSON.stringify(window.__bench?.report() ?? null)") as? String
                    let parsed = report.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                    let status = await js(id, """
                        JSON.stringify({title: document.title, url: location.href.slice(0, 80),
                          canvases: [...document.querySelectorAll('canvas')].map(c => [c.width, c.height]),
                          notReady: !!document.querySelector(window.__benchNotReadySelector || null)})
                        """) as? String
                    let marks = native[id] ?? [:]
                    let opened = marks["asked"] ?? start
                    log("tile", ["layout": layout.name, "round": round, "site": site, "opened": opened,
                                 "native": marks.mapValues { $0 - opened }, "report": parsed ?? NSNull(),
                                 "status": status ?? NSNull()])
                    if round == 0, let web = page(id),
                       let folder, let image = try? await web.takeSnapshot(configuration: nil),
                       let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
                        .representation(using: .png, properties: [:]) {
                        try? png.write(to: folder.appending(path: "\(id).png"))
                    }
                    if round == 0, let web = page(id),
                       let screen = web.window?.screen {
                        let r = web.window!.convertToScreen(web.convert(web.bounds, to: nil))
                        let top = screen.visibleFrame.maxY
                        tileFrames[layout.name, default: []].append(
                            ["site": site, "x": r.minX - screen.visibleFrame.minX, "y": top - r.maxY,
                             "width": r.width, "height": r.height])
                    }
                }
                log("layout-end", ["layout": layout.name, "round": round, "readyMs": readyMs])
            }
        }
    }

    private static func finish(_ tileFrames: [String: [[String: Any]]]) {
        if !bare, let folder, let data = try? JSONSerialization.data(withJSONObject: tileFrames, options: .prettyPrinted) {
            try? data.write(to: folder.appending(path: "tiles.json"))
        }
        log("done")
        try? events?.close()
        NSApp.terminate(nil)
    }

    // MARK: The bare control

    private static var bareWindow: NSWindow?

    /// Tile frames in points from the top-left of the screen's visible frame: Folio's own, from an
    /// earlier run's `tiles.json` copied in as `folio-tiles.json`, else equal columns.
    private static func bareFrames(_ layout: Scenario.Layout, in bounds: NSRect) -> [(site: String, frame: NSRect)] {
        let sites = layout.columns.flatMap { $0 }
        if let folder, let data = try? Data(contentsOf: folder.appending(path: "folio-tiles.json")),
           let all = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]],
           let rects = all[layout.name], rects.count == sites.count {
            return rects.map { r in
                let n = { (k: String) in (r[k] as? NSNumber)?.doubleValue ?? 0 }
                return (r["site"] as? String ?? "",
                        NSRect(x: n("x"), y: bounds.height - n("y") - n("height"), width: n("width"), height: n("height")))
            }
        }
        let gap = 8.0, cols = Double(layout.columns.count)
        let width = (bounds.width - gap * (cols + 1)) / cols
        return layout.columns.enumerated().flatMap { c, column in
            let rows = Double(column.count)
            let height = (bounds.height - gap * (rows + 1)) / rows
            return column.enumerated().map { r, site in
                (site, NSRect(x: gap + Double(c) * (width + gap),
                              y: bounds.height - gap - Double(r + 1) * height - Double(r) * gap,
                              width: width, height: height))
            }
        }
    }

    private static func barePage(_ id: String, site: Scenario.Site, frame: NSRect) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = CanvasWebSession.store(named: nil)
        CanvasWebSession.identify(configuration)
        install(in: configuration, for: URL(string: site.url)?.host())
        let web = WKWebView(frame: frame, configuration: configuration)
        web.navigationDelegate = bareMarks
        bareMarks.ids[ObjectIdentifier(web)] = id
        return web
    }

    private static func runBare(in window: NSWindow) async {
        guard let scenario, let content = window.contentView else { return }
        await sleep(2)
        log("setup", ["screen": [window.screen?.frame.width ?? 0, window.screen?.frame.height ?? 0],
                      "window": [window.frame.width, window.frame.height], "warm": warm, "bare": true,
                      "pid": ProcessInfo.processInfo.processIdentifier])
        var tileFrames: [String: [[String: Any]]] = [:]
        for round in 0..<scenario.rounds {
            for layout in scenario.layouts {
                let ids = layout.columns.flatMap { $0 }.map { cardID(layout.name, $0) }
                if !warm {
                    // Cold, as the Folio run is: everything but the layout being left is already gone.
                    await sleep(2)
                }
                native = [:]
                let start = Date().timeIntervalSince1970 * 1000
                log("layout-start", ["layout": layout.name, "round": round])
                let host = HostFrames(on: content)
                // The crossing: the leaving layout goes (cold) or hides (warm); this one appears.
                for (id, web) in barePages where !ids.contains(id) {
                    if warm { web.isHidden = true } else { web.removeFromSuperview(); barePages[id] = nil }
                }
                for (site, frame) in bareFrames(layout, in: content.bounds) {
                    let id = cardID(layout.name, site)
                    if let web = barePages[id] { web.isHidden = false; continue }
                    guard let info = scenario.sites[site], let url = URL(string: info.url) else { continue }
                    let web = barePage(id, site: info, frame: frame)
                    content.addSubview(web)
                    barePages[id] = web
                    mark(id, "asked")
                    web.load(URLRequest(url: url))
                }
                await measure(layout, round: round, start: start, host: host, tileFrames: &tileFrames)
            }
        }
        finish(tileFrames)
    }

    /// Freeze every page on every board but `keep`, and forget what would let one come back warm.
    private static func coolEverything(in window: NSWindow, but keep: CanvasBoardView?) async {
        guard let canvas, let scenario else { return }
        for board in boards(in: window) where board !== keep { board.pauseAllPages() }
        let keepIDs = Set(keep?.tiling?.ids ?? [])
        for layout in scenario.layouts {
            for site in layout.columns.flatMap({ $0 }) {
                let id = cardID(layout.name, site)
                guard !keepIDs.contains(id) else { continue }
                let key = CanvasPageHandover.key(canvas: canvas, card: id)
                CanvasPageHandover.resumes[key] = nil
                CanvasPageVisits.forget(key)
                CanvasPageSnapshots.forget(key)
            }
        }
        // Teardown finishes in the snapshot callback; give WebKit a moment to let the processes go.
        await sleep(2)
    }

    /// The page for a tile: the card's live page on a board, or the bare view the bare run made.
    private static func page(_ id: String) -> WKWebView? {
        if bare { return barePages[id] }
        guard let canvas else { return nil }
        return CanvasLinkNodeView.card(id, onCanvas: canvas)?.livePage
    }

    @discardableResult
    private static func js(_ id: String, _ source: String) async -> Any? {
        guard let web = page(id) else { return nil }
        return try? await web.evaluateJavaScript(source)
    }

    private static func phase(_ ids: [String], _ name: (String) -> String) async {
        for id in ids { await js(id, "window.__bench?.setPhase('\(name(id))')") }
    }

    /// Real wheel events, aimed at the centre of the tile's page, alternating direction every 30.
    private static func scroll(_ id: String, seconds: Double) async {
        guard let web = page(id), let window = web.window else { return }
        let centre = window.convertPoint(toScreen: web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil))
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: centre.x, y: primary - centre.y)
        let until = Date().addingTimeInterval(seconds)
        var direction: Int32 = -1, count = 0
        while Date() < until {
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                wheel1: 60 * direction, wheel2: 0, wheel3: 0) {
                cg.location = global
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                        value: Int64(window.windowNumber))
                if let event = NSEvent(cgEvent: cg) { web.scrollWheel(with: event) }
            }
            count += 1
            if count % 30 == 0 { direction = -direction }
            await sleep(0.016)
        }
    }
}

/// The app's own frames from the moment a crossing starts until every tile has settled: what the
/// window delivered, not what the pages did. A gap of one refresh is a frame; more is frames missed.
@MainActor
private final class HostFrames: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var nominal: CFTimeInterval = 1.0 / 60

    init(on view: NSView) {
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if link.duration > 0 { nominal = link.duration }
    }

    func finish() -> [String: Any] {
        link?.invalidate()
        link = nil
        let gaps = zip(stamps, stamps.dropFirst()).map { $1 - $0 }
        guard !gaps.isEmpty else { return ["frames": stamps.count] }
        let first2s = zip(stamps, gaps).filter { $0.0 - stamps[0] < 2 }.map(\.1)
        func missed(_ xs: [Double]) -> Int { xs.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) } }
        return ["frames": stamps.count, "hz": (1 / nominal).rounded(),
                "dropped": missed(gaps), "dropped2s": missed(first2s),
                "worstMs": ((gaps.max() ?? 0) * 1000).rounded(),
                "over50": gaps.filter { $0 > 0.05 }.count,
                // Every late frame as [media time it ended, gap ms], to line up with a profile.
                "late": zip(stamps.dropFirst(), gaps).filter { $0.1 > nominal * 1.5 }
                    .map { [$0.0, ($0.1 * 1000).rounded()] }]
    }
}

/// The bare run's navigation milestones, under the same names the cards use.
@MainActor
private final class BareMarks: NSObject, WKNavigationDelegate {
    var ids: [ObjectIdentifier: String] = [:]

    private func mark(_ web: WKWebView, _ what: String) {
        if let id = ids[ObjectIdentifier(web)] { LayoutBench.mark(id, what) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { mark(webView, "start") }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { mark(webView, "commit") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { mark(webView, "finish") }
}
