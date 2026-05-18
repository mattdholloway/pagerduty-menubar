import Foundation
import UserNotifications
import AppKit

/// Tracks which triggered incidents we've already notified the user about and
/// posts macOS notifications for newly-arrived ones assigned to them. Lives
/// outside `OnCallStore` so notification responses can route back via
/// `NotificationCenter` regardless of the store's lifecycle.
@MainActor
final class NotificationsCoordinator: NSObject {
    static let shared = NotificationsCoordinator()

    static let actionAck = "PD_ACK"
    static let actionResolve = "PD_RESOLVE"
    static let actionOpen = "PD_OPEN"
    static let categoryIncident = "PD_INCIDENT"

    /// Sent when the user picks Ack on an incident notification.
    /// userInfo: ["id": String]
    static let didRequestAcknowledge = Notification.Name("PDDidRequestAcknowledge")
    /// Sent when the user picks Resolve.
    static let didRequestResolve = Notification.Name("PDDidRequestResolve")

    @AppStorageDefault("notifiedIncidentIDs") private var rawNotifiedIDs: String = ""
    private var notifiedIDs: Set<String> {
        get { Set(rawNotifiedIDs.split(separator: ",").map(String.init)) }
        set { rawNotifiedIDs = newValue.sorted().joined(separator: ",") }
    }

    private var authorized = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategory()
    }

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self?.authorized = granted }
                }
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in self?.authorized = true }
            case .denied:
                Task { @MainActor in self?.authorized = false }
            @unknown default:
                break
            }
        }
    }

    private func registerCategory() {
        let ack = UNNotificationAction(identifier: Self.actionAck, title: "Acknowledge", options: [])
        let res = UNNotificationAction(identifier: Self.actionResolve, title: "Resolve", options: [.destructive])
        let open = UNNotificationAction(identifier: Self.actionOpen, title: "Open in PagerDuty", options: [.foreground])
        let cat = UNNotificationCategory(
            identifier: Self.categoryIncident,
            actions: [ack, res, open],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    /// Diffs against the last-notified set and posts notifications for new
    /// `triggered` incidents assigned to the given user. Idempotent.
    func diffAndNotify(incidents: [PDIncident], myUserID: String) {
        let candidates = incidents.filter { inc in
            inc.status == "triggered" &&
            (inc.assignments?.contains { $0.assignee.id == myUserID } ?? false)
        }
        var seen = notifiedIDs
        var newOnes: [PDIncident] = []
        for inc in candidates where !seen.contains(inc.id) {
            seen.insert(inc.id)
            newOnes.append(inc)
        }
        // Garbage-collect IDs that have left the active list.
        let stillActive = Set(incidents.map(\.id))
        seen.formIntersection(stillActive.union(Set(newOnes.map(\.id))))
        notifiedIDs = seen
        for inc in newOnes { post(inc) }
    }

    private func post(_ inc: PDIncident) {
        let content = UNMutableNotificationContent()
        content.title = inc.urgency == "high" ? "🚨 " + inc.title : inc.title
        let svc = inc.service?.summary ?? "PagerDuty"
        content.subtitle = svc
        content.body = "Triggered \(Self.relative.localizedString(for: inc.created_at ?? Date(), relativeTo: Date()))"
        content.sound = inc.urgency == "high" ? .defaultCritical : .default
        content.categoryIdentifier = Self.categoryIncident
        content.userInfo = ["id": inc.id, "url": inc.html_url ?? ""]
        let req = UNNotificationRequest(identifier: "pd-\(inc.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

extension NotificationsCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let id = info["id"] as? String else { completionHandler(); return }
        let urlString = info["url"] as? String
        switch response.actionIdentifier {
        case NotificationsCoordinator.actionAck:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NotificationsCoordinator.didRequestAcknowledge,
                                                object: nil, userInfo: ["id": id])
            }
        case NotificationsCoordinator.actionResolve:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NotificationsCoordinator.didRequestResolve,
                                                object: nil, userInfo: ["id": id])
            }
        case NotificationsCoordinator.actionOpen, UNNotificationDefaultActionIdentifier:
            if let s = urlString, let u = URL(string: s) {
                DispatchQueue.main.async { NSWorkspace.shared.open(u) }
            }
        default:
            break
        }
        completionHandler()
    }
}

/// Lightweight property wrapper providing a UserDefaults-backed string, used
/// by NotificationsCoordinator without needing SwiftUI's @AppStorage (which
/// requires a View context).
@propertyWrapper
struct AppStorageDefault<Value> {
    let key: String
    let defaultValue: Value
    init(_ key: String, wrappedValue: Value) {
        self.key = key
        self.defaultValue = wrappedValue
    }
    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }
    var wrappedValue: Value {
        get { (UserDefaults.standard.object(forKey: key) as? Value) ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
