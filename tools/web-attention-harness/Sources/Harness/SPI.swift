import AppKit
import WebKit

/// Calling Objective-C SPI by selector, checked first, so a missing one is logged rather than a crash.
enum SPI {
    static func has(_ object: NSObject, _ name: String) -> Bool { object.responds(to: NSSelectorFromString(name)) }

    static func pointer(_ object: NSObject, _ name: String) -> OpaquePointer? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> OpaquePointer?
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
    }

    static func integer(_ object: NSObject, _ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
    }

    static func bool(_ object: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
    }

    @discardableResult
    static func set(_ object: NSObject, _ name: String, _ value: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
        return true
    }

    @discardableResult
    static func set(_ object: NSObject, _ name: String, _ value: AnyObject?) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
        return true
    }
}

/// WebKit holds a script message handler strongly.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
