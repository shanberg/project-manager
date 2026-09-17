import AppKit
import WebKit
import WebKitPrivates

/// The native path: WebKit's C notification provider, the permission SPI on the UI delegate, and the
/// data store delegate for service-worker notifications. One provider for the whole process, since every
/// web view shares one context.
@MainActor
final class NativeNotifications: NSObject {
    static let shared = NativeNotifications()

    private var manager: WKNotificationManagerRef?
    private let provider: UnsafeMutablePointer<WKNotificationProviderV0> = {
        let pointer = UnsafeMutablePointer<WKNotificationProviderV0>.allocate(capacity: 1)
        pointer.initialize(to: WKNotificationProviderV0(
            base: WKNotificationProviderBase(version: 0, clientInfo: nil),
            show: { page, notification, _ in
                MainActor.assumeIsolated { NativeNotifications.shared.show(page: page, notification: notification) }
            },
            cancel: { notification, _ in
                MainActor.assumeIsolated { NativeNotifications.shared.cancel(notification) }
            },
            didDestroyNotification: { _, _ in },
            addNotificationManager: { _, _ in },
            removeNotificationManager: { _, _ in },
            notificationPermissions: { _ in
                MainActor.assumeIsolated { NativeNotifications.shared.permissionsDictionary() }
            },
            clearNotifications: { ids, _ in
                let described = String(describing: ids)
                MainActor.assumeIsolated { EventLog.shared.write("native", "clearNotifications", ["ids": described]) }
            }))
        return pointer
    }()

    /// Origins granted, remembered across launches so a reload finds permission already there.
    private(set) var granted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "grantedOrigins") ?? [])

    var listenerForPage: (WKPageRef) -> Listener? = { _ in nil }

    /// Hook up the provider through this web view's context. Before its first load, so the web process
    /// is created knowing the granted origins.
    func attach(to web: WKWebView, name: String) {
        guard let page = SPI.pointer(web, "_pageRefForTransitionToWKWebView") else {
            EventLog.shared.write(name, "nativeUnavailable", ["reason": "no _pageRefForTransitionToWKWebView"])
            return
        }
        let manager = WKContextGetNotificationManager(WKPageGetContext(page))
        if self.manager != manager {
            provider.withMemoryRebound(to: WKNotificationProviderBase.self, capacity: 1) { base in
                WKNotificationManagerSetProvider(manager, base)
            }
            self.manager = manager
            EventLog.shared.write("native", "providerInstalled", ["grantedOrigins": Array(granted)])
            for origin in granted { tellPolicy(origin, allowed: true) }
        }
    }

    // MARK: Permission

    func grant(_ origin: String, from listener: String) {
        let isNew = granted.insert(origin).inserted
        UserDefaults.standard.set(Array(granted), forKey: "grantedOrigins")
        tellPolicy(origin, allowed: true)
        EventLog.shared.write(listener, "permissionGranted", ["origin": origin, "new": isNew])
    }

    private func tellPolicy(_ origin: String, allowed: Bool) {
        guard let manager else { return }
        let string = WKStringCreateWithCFString(origin as CFString)
        let securityOrigin = WKSecurityOriginCreateFromString(string)
        WKNotificationManagerProviderDidUpdateNotificationPolicy(manager, securityOrigin, allowed)
        WKRelease(securityOrigin)
        WKRelease(string)
    }

    private func permissionsDictionary() -> WKDictionaryRef? {
        let dictionary = WKMutableDictionaryCreate()
        for origin in granted {
            let key = WKStringCreateWithCFString(origin as CFString)
            let yes = WKBooleanCreate(true)
            _ = WKDictionarySetItem(dictionary, key, yes)
            WKRelease(yes)
            WKRelease(key)
        }
        EventLog.shared.write("native", "permissionsAsked", ["origins": Array(granted)])
        return dictionary
    }

    // MARK: Notifications

    private func show(page: WKPageRef?, notification: WKNotificationRef?) {
        guard let notification else { return }
        let id = WKNotificationGetID(notification)
        let listener = page.flatMap(listenerForPage)
        var fields: [String: Any] = [
            "id": NSNumber(value: id),
            "title": Self.string(WKNotificationCopyTitle(notification)) ?? "",
            "body": Self.string(WKNotificationCopyBody(notification)) ?? "",
            "tag": Self.string(WKNotificationCopyTag(notification)) ?? "",
            "icon": Self.string(WKNotificationCopyIconURL(notification)) ?? "",
            "lang": Self.string(WKNotificationCopyLang(notification)) ?? "",
        ]
        if let origin = WKNotificationGetSecurityOrigin(notification) {
            fields["origin"] = Self.string(WKSecurityOriginCopyToString(origin)) ?? ""
        }
        if let listener {
            fields["pageTitle"] = listener.web.title ?? ""
            fields["pageURL"] = listener.web.url?.absoluteString ?? ""
            listener.lastNotification = .native(id)
        }
        EventLog.shared.write(listener?.name ?? "unknown page", "notification (native)", fields)
        if let manager { WKNotificationManagerProviderDidShowNotification(manager, id) }
    }

    private func cancel(_ notification: WKNotificationRef?) {
        guard let notification else { return }
        EventLog.shared.write("native", "notificationClosedByPage", ["id": NSNumber(value: WKNotificationGetID(notification))])
    }

    func click(_ id: UInt64, listener: String) {
        guard let manager else { return }
        WKNotificationManagerProviderDidClickNotification(manager, id)
        EventLog.shared.write(listener, "clickSent (native)", ["id": NSNumber(value: id)])
    }

    private static func string(_ ref: WKStringRef?) -> String? {
        guard let ref else { return nil }
        defer { WKRelease(ref) }
        return WKStringCopyCFString(kCFAllocatorDefault, ref)?.takeRetainedValue() as String?
    }

    // MARK: Service workers, through the data store's delegate

    func watchDataStore(_ store: WKWebsiteDataStore) {
        let installed = SPI.set(store, "set_delegate:", self as AnyObject)
        EventLog.shared.write("native", "dataStoreDelegate", ["installed": installed])
    }

    @objc(websiteDataStore:showNotification:)
    func websiteDataStore(_ store: AnyObject, showNotification data: NSObject) {
        var fields: [String: Any] = [:]
        for key in ["title", "body", "tag", "lang", "origin", "identifier", "serviceWorkerRegistrationURL", "userInfo"] {
            if let value = data.value(forKey: key) { fields[key] = String(describing: value) }
        }
        if let payload = data.value(forKey: "data") as? Data {
            fields["data"] = String(data: payload, encoding: .utf8) ?? "<\(payload.count) bytes>"
        }
        EventLog.shared.write("service worker", "notification (service worker)", fields)
    }

    @objc(notificationPermissionsForWebsiteDataStore:)
    func notificationPermissions(for store: AnyObject) -> NSDictionary {
        NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: granted.map { ($0, NSNumber(value: true)) }))
    }

    @objc(websiteDataStore:workerOrigin:updatedAppBadge:)
    func websiteDataStore(_ store: AnyObject, workerOrigin origin: AnyObject, updatedAppBadge badge: NSNumber?) {
        EventLog.shared.write("service worker", "appBadge", ["origin": String(describing: origin), "count": badge ?? NSNull()])
    }
}
