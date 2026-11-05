import Foundation

/// Work that each costs a main-thread stall, run one item at a time with the run loop let through
/// between them.
///
/// The case it exists for: when the block lists arrive, every card that showed its page before them
/// rebuilds its web view. Each rebuild launches a web process, and WebKit fetches the user's fonts
/// from fontd synchronously on the main thread while doing it — about a second on a busy Mac. Run in
/// one pass, a board of cards froze the app for the sum of them (folio-hang-3, 2026-11-05). One per
/// pause, the same total arrives as separate hitches with events and drawing in between.
///
/// Items that say they come first — cards you can see — run before the rest. Asked once, as the run
/// starts, so the order is fixed.
@MainActor
enum CanvasStaggeredRun {
    struct Item {
        var first: () -> Bool
        var work: () -> Void
    }

    /// Long enough for the run loop to take a turn and draw a frame; short against the stall each
    /// item costs.
    static let pause: Duration = .milliseconds(100)

    /// The order the items run in: those that come first, then the rest, each group as queued.
    static func order(_ items: [Item]) -> [Item] {
        let flags = items.map { $0.first() }
        return zip(items, flags).filter { $0.1 }.map(\.0) + zip(items, flags).filter { !$0.1 }.map(\.0)
    }

    /// Run every item, pausing between each and the next. `wait` stands in for the pause in tests.
    static func run(_ items: [Item],
                    wait: () async -> Void = { try? await Task.sleep(for: pause) }) async {
        for (index, item) in order(items).enumerated() {
            if index > 0 { await wait() }
            item.work()
        }
    }
}
