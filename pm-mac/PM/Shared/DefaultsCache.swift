import Foundation

/// A value read out of `UserDefaults`, kept until the defaults change.
///
/// **Reading a defaults dictionary is not free.** Every `dictionary(forKey:)` bridges the whole stored
/// property list into new Swift values, hashing every key on the way, and a JSON value inside it is
/// decoded again on top. That is nothing once and a great deal per frame: profiled 2026-11-27, a window
/// resize re-evaluated the Spaces sidebar every frame, each card row's menu asked `CanvasWorkspaces.of`
/// and each title asked `CanvasPageTitles.stored`, and between them they were most of the main thread.
///
/// Thrown away whenever this process changes any default (`UserDefaults.didChangeNotification`, which
/// covers a test removing the key directly) and by the owner's own writes, which call `invalidate`.
/// Another process writing the same defaults is not seen until then — neither store is shared.
final class DefaultsCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private let read: () -> Value
    private var observer: NSObjectProtocol?

    init(_ read: @escaping () -> Value) {
        self.read = read
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.invalidate() }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    var current: Value {
        lock.lock()
        if let value { lock.unlock(); return value }
        lock.unlock()
        let fresh = read()
        lock.lock()
        value = fresh
        lock.unlock()
        return fresh
    }

    func invalidate() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

/// A mutable value behind a lock, for a cache that fills in piece by piece.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
