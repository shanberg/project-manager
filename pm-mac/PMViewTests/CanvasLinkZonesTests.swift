import XCTest
import AppKit
import SwiftUI

/// Where a card's links are drawn, as the card reports them to the board (`CanvasLinkZones`).
///
/// The board decides everything about a press on a link from these zones — whether the pointer is a
/// hand, whether a click opens a page, whether a drag carries one off — so the zones are what is
/// asserted, and asserted against AppKit's own measurement of the same string rather than against the
/// numbers the zone itself produced.
///
/// **No clicks.** A hostless test bundle's app never becomes active, and SwiftUI takes no click in an
/// inactive app — a plain `Button` in this harness counted none, with the window claiming to be key and
/// the hosting view accepting first mouse. That is also why the one question these can't answer is
/// whether a click on a note's link reaches it through the row gestures around it in the project
/// window; on a board it no longer has to, since the board takes the press first.
@MainActor
final class CanvasLinkZonesTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 12.5)

    private func host<V: View>(_ view: V, zones: CanvasLinkZones?,
                               size: NSSize = NSSize(width: 360, height: 200)) -> NSHostingView<AnyView> {
        TestApp.start()
        let root = zones.map { AnyView(view.canvasLinkZones($0)) } ?? AnyView(view)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        settle()
        addTeardownBlock { window.orderOut(nil) }
        return hosting
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func width(_ string: String) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }

    /// A note's prose, pinned to the top-left of the card at a known inset.
    private func note(_ prose: String) -> some View {
        RenderedNote(prose: prose, font: font, noteURL: nil)
            .padding(.leading, 12)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Prose

    /// A link in the middle of a line is found exactly where it was drawn, and the words either side
    /// of it are not the link.
    func testAProseLinkIsFoundWhereItWasDrawn() {
        let zones = CanvasLinkZones()
        _ = host(note("Some words then [Second](https://example.com/two) and a tail"), zones: zones)
        let x = 12 + width("Some words then ")
        let w = width("Second")
        XCTAssertEqual(zones.link(at: CGPoint(x: x + w / 2, y: 27))?.absoluteString,
                       "https://example.com/two", "the link isn't where AppKit draws its label")
        XCTAssertNil(zones.link(at: CGPoint(x: x - 6, y: 27)), "the words before the link answered for it")
        XCTAssertNil(zones.link(at: CGPoint(x: x + w + 6, y: 27)), "the words after the link answered for it")
        XCTAssertNil(zones.link(at: CGPoint(x: x + w / 2, y: 60)), "the line below answered for it")
    }

    /// A link long enough to wrap is a link on both of its lines.
    func testALinkThatWrapsIsALinkOnBothLines() {
        let zones = CanvasLinkZones()
        _ = host(note("[a link label long enough that it has to wrap onto a second line](https://example.com/w)"),
                 zones: zones, size: NSSize(width: 160, height: 200))
        XCTAssertEqual(zones.link(at: CGPoint(x: 18, y: 27))?.absoluteString, "https://example.com/w",
                       "the first line of a wrapped link isn't the link")
        XCTAssertEqual(zones.link(at: CGPoint(x: 18, y: 27 + 17))?.absoluteString, "https://example.com/w",
                       "the second line of a wrapped link isn't the link")
    }

    /// Prose with no links reports none — and is drawn by the one `Text` it always was.
    func testProseWithoutLinksReportsNothing() {
        let zones = CanvasLinkZones()
        _ = host(note("Nothing to follow in this sentence at all"), zones: zones)
        for x in stride(from: 12.0, to: 300, by: 10) {
            XCTAssertNil(zones.link(at: CGPoint(x: x, y: 27)), "plain prose answered as a link at x=\(x)")
        }
    }

    /// Marking the links changes nothing about how the text is laid out: the marked text and the
    /// plain one come out the same size at two widths, one of which wraps it.
    func testMarkingLinksDrawsTheSameText() {
        let attributed = renderedMarkdown(
            "A [first](https://example.com/1) link, some **bold** words, and a [second](https://example.com/2) one",
            base: font, baseColor: .labelColor)
        for widthLimit in [600.0, 140.0] {
            let marked = NSHostingView(rootView: linkMarkedText(attributed)
                .frame(width: widthLimit).fixedSize(horizontal: false, vertical: true))
            let plain = NSHostingView(rootView: Text(attributed)
                .frame(width: widthLimit).fixedSize(horizontal: false, vertical: true))
            XCTAssertEqual(marked.fittingSize, plain.fittingSize,
                           "marking the links changed the layout at width \(widthLimit)")
        }
    }

    // MARK: Views

    /// A brief's link row is a view, and the whole of it — the favicon too — is the link.
    func testALinkRowReportsItsWholeFrame() {
        let zones = CanvasLinkZones()
        let url = URL(string: "https://example.com/row")!
        _ = host(
            HStack(spacing: 6) {
                Color.gray.frame(width: 16, height: 16)
                Text("Example").font(.system(size: 12))
            }
            .reportsLinkZone(url)
            .padding(.leading, 30)
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
            zones: zones)
        XCTAssertEqual(zones.link(at: CGPoint(x: 34, y: 48)), url, "the favicon isn't part of the link")
        XCTAssertEqual(zones.link(at: CGPoint(x: 30 + 22 + 10, y: 48)), url, "the label isn't the link")
        XCTAssertNil(zones.link(at: CGPoint(x: 20, y: 48)), "the margin before the row answered for it")
    }

    // MARK: Staying true

    /// A card scrolled is a card whose links have moved: the zone goes with the text.
    func testAZoneFollowsItsTextWhenTheCardScrolls() throws {
        let zones = CanvasLinkZones()
        let hosting = host(
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 150)
                    RenderedNote(prose: "[Scrolled](https://example.com/s)", font: font, noteURL: nil)
                        .padding(.leading, 12)
                    Color.clear.frame(height: 400)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            },
            zones: zones)
        XCTAssertNotNil(zones.link(at: CGPoint(x: 20, y: 157)), "the link isn't where it starts out")

        let scroller = try XCTUnwrap(firstScrollView(in: hosting), "SwiftUI built no NSScrollView")
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroller.reflectScrolledClipView(scroller.contentView)
        settle()
        XCTAssertNotNil(zones.link(at: CGPoint(x: 20, y: 57)), "the zone didn't follow the scroll")
        XCTAssertNil(zones.link(at: CGPoint(x: 20, y: 157)), "the zone stayed where the link used to be")
    }

    /// Text that goes takes its links with it.
    func testAZoneGoesWithItsText() {
        let zones = CanvasLinkZones()
        let model = Shown()
        _ = host(Toggled(model: model, font: font), zones: zones)
        XCTAssertNotNil(zones.link(at: CGPoint(x: 20, y: 27)), "the link never reported")
        model.isShown = false
        settle()
        XCTAssertNil(zones.link(at: CGPoint(x: 20, y: 27)), "a link that has gone still answers")
    }

    // MARK: Off a board

    /// The same note with no card around it reports nowhere and draws as it always did — the project
    /// window's case. Its links are still links: the text carries them either way.
    func testWithoutACardTheNoteKeepsItsLinks() {
        let attributed = renderedMarkdown("[Example](https://example.com/x)", base: font, baseColor: .labelColor)
        let links = attributed.runs[\.link].compactMap(\.0)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/x"])
        let hosting = host(note("[Example](https://example.com/x)"), zones: nil)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView { return scroller }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}

private final class Shown: ObservableObject {
    @Published var isShown = true
}

private struct Toggled: View {
    @ObservedObject var model: Shown
    let font: NSFont

    var body: some View {
        VStack(alignment: .leading) {
            if model.isShown {
                RenderedNote(prose: "[Going](https://example.com/g)", font: font, noteURL: nil)
            }
        }
        .padding(.leading, 12)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
