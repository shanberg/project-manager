import Foundation
import UserNotifications

/// Schedules local notifications for the focused project and handles their actions:
///   * Stale nudges — the focused task has been focused for 1h / 2h (from `task-timing.json`).
///   * Due alerts — an open task in the focused project reaches its due date.
///
/// Notifications carry Complete / Dive In / Snooze actions that drive `PMStore` directly. Scheduling
/// is idempotent: it reschedules only when the relevant state (focused task, its seen-at, or due
/// dates) actually changes, and only ever schedules future triggers (no backfill spam on launch).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private weak var store: PMStore?
    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    private var lastSignature = ""

    private static let staleCategory = "pm.stale"
    private static let dueCategory = "pm.due"
    private static let completeAction = "pm.action.complete"
    private static let diveInAction = "pm.action.diveIn"
    private static let snoozeAction = "pm.action.snooze"
    private static let snoozeInterval: TimeInterval = 30 * 60

    init(store: PMStore) {
        self.store = store
        super.init()
        center.delegate = self
        registerCategories()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                self?.lastSignature = ""   // force a schedule now that permission is known
                self?.sync()
            }
        }
    }

    private func registerCategories() {
        let complete = UNNotificationAction(identifier: Self.completeAction, title: "Complete", options: [])
        let diveIn = UNNotificationAction(identifier: Self.diveInAction, title: "Dive In", options: [.foreground])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 30 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.staleCategory, actions: [complete, diveIn, snooze],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.dueCategory, actions: [complete, snooze],
                                   intentIdentifiers: [], options: []),
        ])
    }

    // MARK: Scheduling

    /// Called on every store change; reschedules only when the relevant state changed.
    func sync() {
        guard authorized, let store else { return }
        let seenAt = TaskTiming.load()?.seenAt ?? 0
        let dueSig = store.todos
            .filter { !$0.checked }
            .compactMap { todo -> String? in
                guard let d = todo.dueDate else { return nil }
                return "\(todo.sessionIndex):\(todo.lineIndex)=\(d)"
            }
            .joined(separator: ",")
        let signature = "\(store.focusedKey ?? "")|\(seenAt)|\(dueSig)"
        guard signature != lastSignature else { return }
        lastSignature = signature

        center.removeAllPendingNotificationRequests()   // this app owns all pending requests
        let now = Date().timeIntervalSince1970
        let title = store.notes?.title ?? store.projectName ?? "PM"

        // Stale nudges for the focused task.
        if let focused = store.focusedTodo, seenAt > 0 {
            let name = truncate(focused.text)
            schedule(id: "pm.stale.1", after: seenAt + 3600 - now, title: title,
                     body: "You've been focused on “\(name)” for an hour.", category: Self.staleCategory)
            schedule(id: "pm.stale.2", after: seenAt + 7200 - now, title: title,
                     body: "Still on “\(name)” — over two hours now.", category: Self.staleCategory)
        }

        // Due alerts for open tasks with a future due date.
        for todo in store.todos where !todo.checked {
            guard let dueStr = todo.dueDate, let due = RelativeDue.parse(dueStr) else { continue }
            schedule(id: "pm.due.\(todo.sessionIndex):\(todo.lineIndex)", after: due.timeIntervalSince1970 - now,
                     title: title, body: "“\(truncate(todo.text))” is due.", category: Self.dueCategory)
        }
    }

    private func schedule(id: String, after seconds: TimeInterval, title: String, body: String, category: String) {
        guard seconds > 0 else { return }   // future only; never backfill past thresholds
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])   // deliver even though the agent app is "frontmost-less"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let request = response.notification.request
        let id = request.identifier
        let title = request.content.title
        let body = request.content.body
        let category = request.content.categoryIdentifier
        Task { @MainActor in
            self.handle(action: action, requestID: id, title: title, body: body, category: category)
            completionHandler()
        }
    }

    private func handle(action: String, requestID: String, title: String, body: String, category: String) {
        guard let store else { return }
        switch action {
        case Self.completeAction:
            if let focused = store.focusedTodo { store.complete(focused) }
        case Self.diveInAction:
            store.diveIn()
        case Self.snoozeAction:
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.snoozeInterval, repeats: false)
            center.add(UNNotificationRequest(identifier: requestID + ".snoozed", content: content, trigger: trigger))
        default:
            break   // default tap: nothing (opening the panel would require a foreground hop)
        }
    }

    private func truncate(_ s: String, _ n: Int = 40) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}
