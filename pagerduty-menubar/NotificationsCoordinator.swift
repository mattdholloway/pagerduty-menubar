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

    // On-call change notification settings. Bound from SettingsView via
    // SwiftUI's @AppStorage on the same keys.
    @AppStorageDefault("notifyOnCallChanges") private var notifyOnCallChangesEnabled: Bool = true
    @AppStorageDefault("notifyOnCallChangesPrimaryOnly") private var notifyOnCallChangesPrimaryOnly: Bool = true
    @AppStorageDefault("notifyOnCallChangesMeOnly") private var notifyOnCallChangesMeOnly: Bool = false

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

    // MARK: - On-call change notifications

    /// One per (policy, level) where the set of users on call changed.
    struct OnCallChange: Equatable {
        let policyID: String
        let policySummary: String
        let level: Int
        let removed: [PDReference]
        let added: [PDReference]
    }

    /// Diffs the previous vs current per-policy on-call snapshot and posts a
    /// single batched notification covering everything that changed in this
    /// refresh tick. Caller is responsible for staleness checks (don't call
    /// after waking from a long sleep — see `OnCallStore.notifyOnCallChangesIfFresh`).
    func notifyOnCallChanges(
        previous: [String: [PDOnCall]],
        current: [String: [PDOnCall]],
        groups: [EscalationPolicyGroup],
        hiddenPolicyIDs: Set<String>,
        myPolicyIDs: Set<String>,
        myUserID: String?
    ) {
        guard notifyOnCallChangesEnabled else { return }

        var summaries: [String: String] = [:]
        for g in groups {
            if let s = g.policy.summary { summaries[g.id] = s }
        }

        let changes = Self.computeOnCallChanges(
            previous: previous,
            current: current,
            policySummaries: summaries,
            filterPolicyIDs: myPolicyIDs.subtracting(hiddenPolicyIDs),
            primaryOnly: notifyOnCallChangesPrimaryOnly,
            meOnly: notifyOnCallChangesMeOnly,
            myUserID: myUserID
        )
        guard !changes.isEmpty else { return }

        let (title, body) = Self.formatOnCallChanges(changes)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let id = "pd-oncall-change-\(Int(Date().timeIntervalSince1970 * 1000))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Pure diff. Compares the user-id set per (policy, level) and emits one
    /// `OnCallChange` per level where the set differs. Marked `nonisolated`
    /// so tests don't need to hop onto MainActor just to exercise the math.
    nonisolated static func computeOnCallChanges(
        previous: [String: [PDOnCall]],
        current: [String: [PDOnCall]],
        policySummaries: [String: String],
        filterPolicyIDs: Set<String>?,
        primaryOnly: Bool,
        meOnly: Bool,
        myUserID: String?
    ) -> [OnCallChange] {
        // "Only when I'm involved" without a known user id = suppress
        // everything, rather than silently widening to all changes.
        if meOnly && (myUserID?.isEmpty ?? true) { return [] }

        let policyIDs = Set(previous.keys).union(current.keys)
        var result: [OnCallChange] = []

        for pid in policyIDs {
            if let filter = filterPolicyIDs, !filter.contains(pid) { continue }

            let prev = previous[pid] ?? []
            let curr = current[pid] ?? []
            let prevByLevel = Dictionary(grouping: prev, by: { $0.escalation_level })
            let currByLevel = Dictionary(grouping: curr, by: { $0.escalation_level })

            let allLevels = Set(prevByLevel.keys).union(currByLevel.keys)
            let levelsToCheck: Set<Int>
            if primaryOnly {
                if let minLevel = allLevels.min() {
                    levelsToCheck = [minLevel]
                } else {
                    levelsToCheck = []
                }
            } else {
                levelsToCheck = allLevels
            }

            // Build the summary lookup with a fallback chain so removal-only
            // changes (policy now absent from `groups`) still get a name.
            let summary = policySummaries[pid]
                ?? prev.first?.escalation_policy.summary
                ?? curr.first?.escalation_policy.summary
                ?? "Escalation policy"

            for level in levelsToCheck {
                let prevUsers = (prevByLevel[level] ?? []).map(\.user)
                let currUsers = (currByLevel[level] ?? []).map(\.user)
                let prevIDs = Set(prevUsers.map(\.id))
                let currIDs = Set(currUsers.map(\.id))
                if prevIDs == currIDs { continue }

                let removed = prevUsers
                    .filter { !currIDs.contains($0.id) }
                    .sorted { ($0.summary ?? "") < ($1.summary ?? "") }
                let added = currUsers
                    .filter { !prevIDs.contains($0.id) }
                    .sorted { ($0.summary ?? "") < ($1.summary ?? "") }

                if meOnly, let me = myUserID {
                    let involvesMe = removed.contains { $0.id == me } || added.contains { $0.id == me }
                    if !involvesMe { continue }
                }

                result.append(OnCallChange(
                    policyID: pid,
                    policySummary: summary,
                    level: level,
                    removed: removed,
                    added: added
                ))
            }
        }

        // Stable order so notifications + tests are deterministic.
        return result.sorted {
            if $0.policySummary != $1.policySummary { return $0.policySummary < $1.policySummary }
            if $0.policyID != $1.policyID { return $0.policyID < $1.policyID }
            return $0.level < $1.level
        }
    }

    /// Render a batch of changes into a single notification title + body.
    /// Single-change notifications are scoped to the policy; multi-change
    /// notifications include up to 5 detail lines.
    nonisolated static func formatOnCallChanges(_ changes: [OnCallChange]) -> (title: String, body: String) {
        if changes.count == 1 {
            let c = changes[0]
            return ("On-call: \(c.policySummary)", describe(c, includePolicyName: false))
        }
        let title = "\(changes.count) on-call changes"
        let maxLines = 5
        let head = changes.prefix(maxLines).map { describe($0, includePolicyName: true) }
        var body = head.joined(separator: "\n")
        if changes.count > maxLines {
            body += "\n…and \(changes.count - maxLines) more"
        }
        return (title, body)
    }

    nonisolated private static func describe(_ c: OnCallChange, includePolicyName: Bool) -> String {
        let removedNames = c.removed.map { $0.summary ?? $0.id }.joined(separator: ", ")
        let addedNames = c.added.map { $0.summary ?? $0.id }.joined(separator: ", ")
        let lvl = c.level > 1 ? " (L\(c.level))" : ""

        let core: String
        if !removedNames.isEmpty && !addedNames.isEmpty {
            core = "\(removedNames) → \(addedNames)\(lvl)"
        } else if !addedNames.isEmpty {
            core = "Now on call: \(addedNames)\(lvl)"
        } else if !removedNames.isEmpty {
            core = "Off call: \(removedNames)\(lvl)"
        } else {
            core = ""
        }
        return includePolicyName ? "\(c.policySummary): \(core)" : core
    }
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
