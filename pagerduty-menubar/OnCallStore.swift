import Foundation
import SwiftUI
import Combine

// MARK: - View-ready models

struct OnCallLevel: Identifiable, Hashable, Codable {
    var id: Int { level }
    let level: Int
    let assignments: [OnCallAssignment]
}

struct OnCallAssignment: Identifiable, Hashable, Codable {
    let user: PDReference
    let schedule: PDReference?
    let end: Date?
    var id: String { "\(user.id)-\(schedule?.id ?? "direct")-\(end?.timeIntervalSince1970 ?? 0)" }

    /// Stable identifier used for hide/show. Falls back to a synthetic key
    /// when no schedule is attached (direct user assignment in an EP).
    var hideKey: String { schedule?.id ?? "user:\(user.id)" }
    var hideLabel: String { schedule?.summary ?? (user.summary ?? "this assignment") }
}

struct EscalationPolicyGroup: Identifiable, Hashable, Codable {
    let policy: PDReference
    let services: [PDService]
    let levels: [OnCallLevel]
    var id: String { policy.id }

    /// The "current responder" level — lowest escalation level present.
    var primaryLevel: OnCallLevel? { levels.first }

    func contains(userID: String, atLevelOne: Bool = true) -> Bool {
        if atLevelOne {
            return primaryLevel?.assignments.contains(where: { $0.user.id == userID }) ?? false
        }
        return levels.contains { $0.assignments.contains(where: { $0.user.id == userID }) }
    }
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded(Date)
    case failed(String)
}

struct HiddenAssignment: Identifiable, Hashable {
    let policy: PDReference
    let level: Int
    let assignment: OnCallAssignment
    var id: String { "\(policy.id)-\(assignment.id)" }
}

struct MyShift: Identifiable, Hashable {
    let policyID: String
    let policySummary: String?
    let level: Int
    let schedule: PDReference?
    let start: Date?
    let end: Date?
    let isCurrent: Bool
    var id: String { "\(policyID)-\(level)-\(schedule?.id ?? "direct")-\(start?.timeIntervalSince1970 ?? 0)" }
}

struct IncidentUndo: Equatable {
    let incidentID: String
    let title: String
    let previousStatus: String
    let newStatus: String
    let expiresAt: Date
}

// MARK: - Store

@MainActor
final class OnCallStore: ObservableObject {
    // Public state
    @Published private(set) var me: PDUser?
    @Published private(set) var groups: [EscalationPolicyGroup] = []
    @Published private(set) var state: LoadState = .idle
    @Published var hasToken: Bool = false
    @Published private(set) var activeIncidents: [PDIncident] = []
    @Published private(set) var otherIncidents: [PDIncident] = []
    @Published private(set) var otherIncidentsLoaded: Bool = false
    @Published private(set) var otherIncidentsLoading: Bool = false
    @Published private(set) var incidentMutationError: String?
    @Published private(set) var pendingIncidentIDs: Set<String> = []
    @Published var recentIncidentAction: IncidentUndo?

    // Settings (refresh interval keeps using @AppStorage — it's a simple Int)
    @AppStorage("refreshMinutes") var refreshMinutes: Int = 20

    // Persistent ordered/visibility state. Use plain UserDefaults backing so
    // mutations from button actions inside a MenuBarExtra popover reliably
    // re-render observers (@AppStorage updates from inside such actions have
    // proven unreliable in practice).
    @Published private(set) var hiddenPolicyIDs: Set<String> = []
    @Published private(set) var policyOrder: [String] = []
    @Published private(set) var pinnedKeys: [String] = []  // ordered

    private static let kHiddenPolicyIDs = "hiddenPolicyIDs"
    private static let kPolicyOrder = "policyOrder"
    private static let kPinnedKeys = "pinnedAssignmentKeys"

    private let api = PagerDutyAPI()
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        self.hasToken = KeychainStore.loadToken() != nil
        self.hiddenPolicyIDs = Set(
            (d.string(forKey: Self.kHiddenPolicyIDs) ?? "")
                .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        )
        self.policyOrder = (d.string(forKey: Self.kPolicyOrder) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        self.pinnedKeys = (d.string(forKey: Self.kPinnedKeys) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        // Hydrate from cache if we have one. This populates the menu
        // immediately so the user sees real data without waiting for the
        // first network round-trip.
        var cacheAge: TimeInterval = .infinity
        if let snap = CacheStore.load() {
            self.me = snap.me
            self.groups = snap.groups
            self.myPolicyIDs = snap.myPolicyIDs
            self.currentByPolicy = snap.currentByPolicy
            self.upcomingByPolicy = snap.upcomingByPolicy
            self.upcomingByKey = snap.upcomingByKey
            self.activeIncidents = snap.activeIncidents
            self.state = .loaded(snap.savedAt)
            cacheAge = Date().timeIntervalSince(snap.savedAt)
        }

        if hasToken {
            // Hydrate the API's ETag cache from disk so the first refresh
            // benefits from 304 Not Modified responses.
            if let etags = CacheStore.loadEtags() {
                Task { [api] in await api.importEtagCache(etags) }
            }
            startTimer()
            // Only kick off an immediate refresh if the cached snapshot is
            // older than the configured interval. Otherwise wait for the
            // periodic timer to do the next pull.
            let interval = TimeInterval(max(1, refreshMinutes) * 60)
            if cacheAge >= interval {
                refresh()
            }
        }
    }

    /// Test seam: build a store with pre-baked state, no Keychain access,
    /// no timer, no network. Used only by the test bundle (internal).
    init(
        testMe: PDUser? = nil,
        testGroups: [EscalationPolicyGroup] = [],
        testMyPolicyIDs: Set<String> = [],
        testCurrentByPolicy: [String: [PDOnCall]] = [:],
        testUpcomingByPolicy: [String: [PDOnCall]] = [:],
        testUpcomingByKey: [String: [PDOnCall]] = [:],
        testPolicyOrder: [String] = [],
        testHiddenPolicyIDs: Set<String> = [],
        testPinnedKeys: [String] = []
    ) {
        self.hasToken = false
        self.me = testMe
        self.groups = testGroups
        self.myPolicyIDs = testMyPolicyIDs
        self.currentByPolicy = testCurrentByPolicy
        self.upcomingByPolicy = testUpcomingByPolicy
        self.upcomingByKey = testUpcomingByKey
        self.policyOrder = testPolicyOrder
        self.hiddenPolicyIDs = testHiddenPolicyIDs
        self.pinnedKeys = testPinnedKeys
        // Do NOT touch Keychain / UserDefaults / start timers.
    }

    // MARK: - Policy visibility

    func isPolicyHidden(_ id: String) -> Bool { hiddenPolicyIDs.contains(id) }

    func setPolicyHidden(_ id: String, hidden: Bool) {
        var next = hiddenPolicyIDs
        if hidden { next.insert(id) } else { next.remove(id) }
        hiddenPolicyIDs = next
        UserDefaults.standard.set(next.sorted().joined(separator: ","), forKey: Self.kHiddenPolicyIDs)
        objectWillChange.send()
    }

    func resetHiddenPolicies() {
        hiddenPolicyIDs = []
        UserDefaults.standard.set("", forKey: Self.kHiddenPolicyIDs)
    }

    var hiddenPolicyCount: Int { hiddenPolicyIDs.count }

    /// Hidden policy groups resolved against current data, in their stored order.
    var hiddenPolicies: [EscalationPolicyGroup] {
        orderedGroupsIncludingHidden.filter { hiddenPolicyIDs.contains($0.id) }
    }

    /// Visible groups in user-preferred order (MY policies only — the ones
    /// attached to services owned by my teams).
    var orderedGroups: [EscalationPolicyGroup] {
        orderedGroupsIncludingHidden.filter { myPolicyIDs.contains($0.id) && !hiddenPolicyIDs.contains($0.id) }
    }

    /// Other escalation policies on the account (not tied to my teams).
    /// Always sorted alphabetically; not subject to drag-reorder.
    var otherGroups: [EscalationPolicyGroup] {
        groups.filter { !myPolicyIDs.contains($0.id) }
            .sorted { ($0.policy.summary ?? "") < ($1.policy.summary ?? "") }
    }

    /// Public read-only view of the full ordered list (including hidden groups)
    /// for use in Settings reordering UI. Only includes 'my' groups.
    var orderedGroupsIncludingHiddenPublic: [EscalationPolicyGroup] {
        orderedGroupsIncludingHidden.filter { myPolicyIDs.contains($0.id) }
    }

    private var orderedGroupsIncludingHidden: [EscalationPolicyGroup] {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [EscalationPolicyGroup] = []
        for id in policyOrder {
            if let g = byID[id], !seen.contains(id) {
                result.append(g); seen.insert(id)
            }
        }
        for g in groups where !seen.contains(g.id) {
            result.append(g)
        }
        return result
    }

    func resetPolicyOrder() {
        policyOrder = []
        UserDefaults.standard.set("", forKey: Self.kPolicyOrder)
    }

    /// Replace the entire policy ordering. Useful for List.onMove handlers
    /// that compute the new order in one step.
    func setOrder(_ order: [String]) {
        persistPolicyOrder(order)
    }

    /// Move the policy with `id` one slot up (toward index 0) or down. The
    /// movement is computed relative to the user's *visible* "My" list (so
    /// hidden or out-of-section policies don't make the click appear to do
    /// nothing). The full underlying `policyOrder` is then rewritten to
    /// reflect the swap.
    func nudgePolicy(_ id: String, by delta: Int) {
        // Visible "My" ids in current order.
        let visible = orderedGroups.map(\.id)
        guard let vIdx = visible.firstIndex(of: id) else { return }
        let vTarget = vIdx + delta
        guard vTarget >= 0, vTarget < visible.count else { return }
        let neighborID = visible[vTarget]

        // Apply the swap to the full ordering so the relative position of
        // every other (hidden / other) policy is preserved.
        var full = orderedGroupsIncludingHidden.map(\.id)
        guard let fromFull = full.firstIndex(of: id),
              let toFull = full.firstIndex(of: neighborID) else { return }
        full.remove(at: fromFull)
        // After removal, the neighbour index may have shifted by one if it
        // sat after the source.
        let adjusted = toFull > fromFull ? toFull - 1 : toFull
        // Moving up = land before neighbour; moving down = land after.
        let insertAt = delta < 0 ? adjusted : adjusted + 1
        full.insert(id, at: insertAt)
        persistPolicyOrder(full)
    }

    func canMovePolicy(_ id: String, by delta: Int) -> Bool {
        let visible = orderedGroups.map(\.id)
        guard let idx = visible.firstIndex(of: id) else { return false }
        let target = idx + delta
        return target >= 0 && target < visible.count
    }

    private func persistPolicyOrder(_ order: [String]) {
        policyOrder = order
        UserDefaults.standard.set(order.joined(separator: "\n"), forKey: Self.kPolicyOrder)
    }

    // MARK: - Menu bar pins

    func isPinned(key: String) -> Bool { pinnedKeys.contains(key) }

    func setPinned(key: String, pinned: Bool) {
        var next = pinnedKeys
        if pinned {
            if !next.contains(key) { next.append(key) }
        } else {
            next.removeAll { $0 == key }
        }
        pinnedKeys = next
        UserDefaults.standard.set(next.joined(separator: "\n"), forKey: Self.kPinnedKeys)
    }

    func resetPinned() {
        pinnedKeys = []
        UserDefaults.standard.set("", forKey: Self.kPinnedKeys)
    }

    /// Pinned assignments resolved against the latest data, in the user's pin order.
    var pinnedAssignments: [HiddenAssignment] {
        var byKey: [String: HiddenAssignment] = [:]
        for group in groups {
            for level in group.levels {
                for a in level.assignments {
                    if pinnedKeys.contains(a.hideKey) {
                        byKey[a.hideKey] = HiddenAssignment(policy: group.policy, level: level.level, assignment: a)
                    }
                }
            }
        }
        return pinnedKeys.compactMap { byKey[$0] }
    }

    /// My upcoming shifts across every escalation policy in the lookahead window,
    /// sorted chronologically. Includes the current shift first if I'm on call now.
    var myUpcomingShifts: [MyShift] {
        guard let me else { return [] }
        var result: [MyShift] = []
        // Currently on call now: surface as "Now" entries first.
        for (policyID, list) in currentByPolicy {
            for oc in list where oc.user.id == me.id {
                let policySummary = oc.escalation_policy.summary ?? policyGroup(for: policyID)?.policy.summary
                result.append(MyShift(
                    policyID: policyID,
                    policySummary: policySummary,
                    level: oc.escalation_level,
                    schedule: oc.schedule,
                    start: oc.start,
                    end: oc.end,
                    isCurrent: true
                ))
            }
        }
        for (_, list) in upcomingByPolicy {
            for oc in list where oc.user.id == me.id {
                result.append(MyShift(
                    policyID: oc.escalation_policy.id,
                    policySummary: oc.escalation_policy.summary,
                    level: oc.escalation_level,
                    schedule: oc.schedule,
                    start: oc.start,
                    end: oc.end,
                    isCurrent: false
                ))
            }
        }
        return result.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    // MARK: - Derived UI helpers

    var menuBarTitle: String {
        let pinned = pinnedAssignments
        guard !pinned.isEmpty else {
            if case .failed = state { return "!" }
            return ""
        }
        let names = pinned.map { Self.firstName(of: $0.assignment.user.summary ?? "—") }
        return Self.condense(names, maxLength: 40)
    }

    static func firstName(of full: String) -> String {
        full.split(separator: " ").first.map(String.init) ?? full
    }

    /// Join names with " · ". If the joined string exceeds maxLength, drop the
    /// tail names and append "+N" so the menu bar stays compact regardless of
    /// how many schedules the user pins.
    static func condense(_ names: [String], maxLength: Int) -> String {
        guard !names.isEmpty else { return "" }
        let separator = " · "
        var included: [String] = []
        for n in names {
            let trial = (included + [n]).joined(separator: separator)
            if trial.count <= maxLength {
                included.append(n)
            } else {
                break
            }
        }
        if included.isEmpty {
            // Single name longer than the budget — hard truncate.
            let n = names[0]
            return String(n.prefix(max(1, maxLength - 1))) + "…"
        }
        let omitted = names.count - included.count
        let base = included.joined(separator: separator)
        if omitted > 0 {
            return "\(base) +\(omitted)"
        }
        return base
    }

    var menuBarSymbol: String {
        if !hasToken { return "bell.slash" }
        switch state {
        case .failed: return "exclamationmark.triangle"
        case .loading where groups.isEmpty: return "bell.badge"
        default:
            if activeIncidents.contains(where: { $0.status == "triggered" }) {
                return "exclamationmark.bubble.fill"
            }
            if let me, iAmOnCall(userID: me.id) { return "bell.fill" }
            return "bell"
        }
    }

    func iAmOnCall(userID: String) -> Bool {
        groups.contains { $0.contains(userID: userID, atLevelOne: true) }
    }

    var myOnCallGroups: [EscalationPolicyGroup] {
        guard let me else { return [] }
        return orderedGroups.filter { $0.contains(userID: me.id, atLevelOne: true) }
    }

    // MARK: - Token

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = KeychainStore.saveToken(trimmed)
        hasToken = true
        startTimer()
        refresh()
    }

    func clearToken() {
        KeychainStore.deleteToken()
        CacheStore.clear()
        hasToken = false
        timerTask?.cancel()
        timerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        me = nil
        groups = []
        activeIncidents = []
        otherIncidents = []
        otherIncidentsLoaded = false
        currentByPolicy = [:]
        upcomingByPolicy = [:]
        upcomingByKey = [:]
        state = .idle
    }

    // MARK: - Refresh

    func refresh() {
        guard hasToken else {
            state = .failed("No PagerDuty API token set.")
            return
        }
        resetOtherIncidents()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    // Calendar / "next" lookahead window in days
    static let lookaheadDays: Int = 14

    @Published private(set) var upcomingByKey: [String: [PDOnCall]] = [:]
    @Published private(set) var upcomingByPolicy: [String: [PDOnCall]] = [:]
    @Published private(set) var currentByPolicy: [String: [PDOnCall]] = [:]
    @Published private(set) var myPolicyIDs: Set<String> = []

    private func performRefresh() async {
        guard let token = KeychainStore.loadToken() else {
            state = .failed("No PagerDuty API token set.")
            hasToken = false
            return
        }
        // Apply the same rate-limit guard as the popover poll. If we're low on
        // quota, surface that and skip — the next periodic tick will retry.
        if let rl = await api.lastRateLimit, rl.remaining < 100, rl.reset > Date() {
            state = .failed("Throttling to respect PagerDuty rate limit (resets \(Self.shortRelative.localizedString(for: rl.reset, relativeTo: Date())))")
            return
        }
        state = .loading
        do {
            let me = try await api.currentUser(token: token)
            let teamIDs = (me.teams ?? []).map { $0.id }

            // Services + policies first so we know what "mine" means.
            async let servicesTask = api.services(token: token, teamIDs: teamIDs)
            async let allPoliciesTask = api.allEscalationPolicies(token: token)
            let services = try await servicesTask
            let allPolicies = try await allPoliciesTask

            let myEPIDs = Set(services.compactMap { $0.escalation_policy?.id })
            let myServiceIDs = services.map(\.id)
            let allEPIDs = Set(allPolicies.map(\.id)).union(myEPIDs)

            // Scope incidents to MINE only to keep request volume sane on
            // large accounts. Union of (assignee=me) ∪ (service in my teams).
            // PagerDuty AND's filters per request, so we issue two and dedupe.
            async let assignedTask = api.incidents(token: token, userIDs: [me.id])
            async let serviceTask = api.incidents(token: token, serviceIDs: myServiceIDs)
            let assigned = try await assignedTask
            let serviceScoped = try await serviceTask
            var byID: [String: PDIncident] = [:]
            for inc in assigned { byID[inc.id] = inc }
            for inc in serviceScoped { byID[inc.id] = inc }
            let mineIncidents = Array(byID.values)

            let now = Date()
            let until = Calendar.current.date(byAdding: .day, value: Self.lookaheadDays, to: now) ?? now.addingTimeInterval(7 * 86400)
            let windowed = try await api.onCalls(token: token, escalationPolicyIDs: Array(allEPIDs), since: now, until: until)

            let current = windowed.filter { oc in
                (oc.start.map { $0 <= now } ?? true) && (oc.end.map { $0 > now } ?? true)
            }
            let upcoming = windowed.filter { ($0.start ?? .distantPast) > now }

            let groups = Self.buildGroups(services: services, onCalls: current, allPolicyRefs: allPolicies)
            let (byKey, upByPolicy) = Self.buildUpcomingIndexes(upcoming: upcoming)
            var curByPolicy: [String: [PDOnCall]] = [:]
            for oc in current {
                curByPolicy[oc.escalation_policy.id, default: []].append(oc)
            }

            self.me = me
            self.myPolicyIDs = myEPIDs
            self.groups = groups
            self.upcomingByKey = byKey
            self.upcomingByPolicy = upByPolicy
            self.currentByPolicy = curByPolicy
            self.activeIncidents = Self.sortIncidents(mineIncidents)
            self.state = .loaded(Date())
            persistCacheSnapshot()

            // Phase 3: post macOS notifications for any newly-triggered
            // incidents assigned to me.
            NotificationsCoordinator.shared.diffAndNotify(
                incidents: self.activeIncidents,
                myUserID: me.id
            )
        } catch {
            self.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Faster, incidents-only refresh used by the popover so the inbox
    /// reflects new pages within a minute while the user is looking. Scoped
    /// to MINE only — same as the main refresh — to keep request volume low.
    func refreshIncidents() async {
        guard let token = KeychainStore.loadToken(), let me = self.me else { return }
        // Throttle when PagerDuty is signalling we're close to the limit.
        if let rl = await api.lastRateLimit, rl.remaining < 100, rl.reset > Date() {
            return
        }
        let myServiceIDs = groups.filter { myPolicyIDs.contains($0.id) }.flatMap { $0.services.map(\.id) }
        do {
            async let assignedTask = api.incidents(token: token, userIDs: [me.id])
            async let serviceTask = api.incidents(token: token, serviceIDs: myServiceIDs)
            let assigned = try await assignedTask
            let serviceScoped = try await serviceTask
            var byID: [String: PDIncident] = [:]
            for inc in assigned { byID[inc.id] = inc }
            for inc in serviceScoped { byID[inc.id] = inc }
            self.activeIncidents = Self.sortIncidents(Array(byID.values))
            NotificationsCoordinator.shared.diffAndNotify(incidents: self.activeIncidents, myUserID: me.id)
            persistCacheSnapshot()
        } catch {
            // Stay silent on transient incident refresh failures.
        }
    }

    /// Lazy load: the full account-wide active incident list, used to power
    /// the "Other active incidents" search. We don't auto-refresh this; the
    /// user pulls it once and we keep the snapshot until next manual refresh.
    func loadOtherIncidentsIfNeeded() {
        guard !otherIncidentsLoaded, !otherIncidentsLoading,
              let token = KeychainStore.loadToken(), let me = self.me else { return }
        otherIncidentsLoading = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.otherIncidentsLoading = false } }
            do {
                guard let all = try await self?.api.incidents(token: token) else { return }
                let myIDs = Set(self?.activeIncidents.map(\.id) ?? [])
                await MainActor.run {
                    let other = all.filter { !myIDs.contains($0.id) && !($0.assignments?.contains(where: { $0.assignee.id == me.id }) ?? false) }
                    self?.otherIncidents = OnCallStore.sortIncidents(other)
                    self?.otherIncidentsLoaded = true
                }
            } catch {
                // Surface as a banner if the user tried to load.
                await MainActor.run {
                    self?.incidentMutationError = "Couldn't load other incidents: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }

    /// Reset other-incident snapshot so the next search triggers a fresh fetch.
    func resetOtherIncidents() {
        otherIncidents = []
        otherIncidentsLoaded = false
    }

    private static func sortIncidents(_ list: [PDIncident]) -> [PDIncident] {
        list.sorted {
            // High urgency first, then most recent first.
            if $0.urgency != $1.urgency { return $0.urgency == "high" }
            return ($0.created_at ?? .distantPast) > ($1.created_at ?? .distantPast)
        }
    }

    // MARK: - Incidents: my vs other

    func isMyIncident(_ inc: PDIncident) -> Bool {
        guard let me else { return false }
        if inc.assignments?.contains(where: { $0.assignee.id == me.id }) == true { return true }
        if let sid = inc.service?.id, let myServiceIDs = self.myServiceIDs, myServiceIDs.contains(sid) { return true }
        return false
    }

    private var myServiceIDs: Set<String>? {
        let ids = Set(groups.filter { myPolicyIDs.contains($0.id) }.flatMap { $0.services.map(\.id) })
        return ids.isEmpty ? nil : ids
    }

    var myActiveIncidents: [PDIncident] { activeIncidents }
    var otherActiveIncidents: [PDIncident] { otherIncidents }

    // MARK: - Incidents: mutations

    /// Optimistically mark an incident as acknowledged/resolved and start an
    /// undo window. Reverts on API failure.
    func updateIncidentStatus(_ id: String, to newStatus: String) {
        guard let token = KeychainStore.loadToken(), let me else {
            incidentMutationError = "Need an API token + user email to update incidents."
            return
        }
        guard let email = me.email else {
            incidentMutationError = "Your PagerDuty user has no email on file; can't mutate incidents."
            return
        }
        guard let idx = activeIncidents.firstIndex(where: { $0.id == id }) else { return }
        let original = activeIncidents[idx]
        pendingIncidentIDs.insert(id)

        // Optimistic update.
        var optimistic = original
        optimistic = PDIncident(
            id: original.id, incident_number: original.incident_number,
            title: original.title, status: newStatus, urgency: original.urgency,
            created_at: original.created_at, service: original.service,
            assignments: original.assignments, html_url: original.html_url
        )
        if newStatus == "resolved" {
            // Resolved drops out of the active list immediately.
            activeIncidents.remove(at: idx)
        } else {
            activeIncidents[idx] = optimistic
        }
        recentIncidentAction = IncidentUndo(
            incidentID: id, title: original.title,
            previousStatus: original.status, newStatus: newStatus,
            expiresAt: Date().addingTimeInterval(5)
        )

        Task { [weak self] in
            do {
                _ = try await self?.api.updateIncident(token: token, id: id, status: newStatus, from: email)
                await MainActor.run { self?.pendingIncidentIDs.remove(id) }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.pendingIncidentIDs.remove(id)
                    self.incidentMutationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    // Revert optimistic mutation.
                    if newStatus == "resolved" {
                        self.activeIncidents.insert(original, at: min(idx, self.activeIncidents.count))
                    } else {
                        if let i = self.activeIncidents.firstIndex(where: { $0.id == id }) {
                            self.activeIncidents[i] = original
                        }
                    }
                    self.recentIncidentAction = nil
                }
            }
        }
    }

    func undoLastIncidentAction() {
        guard let undo = recentIncidentAction else { return }
        recentIncidentAction = nil
        updateIncidentStatus(undo.incidentID, to: undo.previousStatus)
    }

    func dismissIncidentError() { incidentMutationError = nil }

    func dismissUndoIfExpired() {
        if let u = recentIncidentAction, u.expiresAt < Date() { recentIncidentAction = nil }
    }

    private func persistCacheSnapshot() {
        CacheStore.save(CacheSnapshot(
            savedAt: Date(),
            me: me,
            groups: groups,
            myPolicyIDs: myPolicyIDs,
            currentByPolicy: currentByPolicy,
            upcomingByPolicy: upcomingByPolicy,
            upcomingByKey: upcomingByKey,
            activeIncidents: activeIncidents
        ))
        // Also persist the ETag cache so 304s work across restarts.
        Task { [api] in
            let etags = await api.exportEtagCache()
            CacheStore.saveEtags(etags)
        }
    }

    private static let shortRelative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Test seam: inject a raw incident list and apply the production sort.
    /// Marked internal so @testable import can reach it.
    func _setActiveIncidentsForTesting(_ raw: [PDIncident]) {
        activeIncidents = Self.sortIncidents(raw)
    }

    static func upcomingKey(for oncall: PDOnCall) -> String {
        oncall.schedule?.id ?? "user:\(oncall.user.id)"
    }

    static func buildUpcomingIndexes(upcoming: [PDOnCall]) -> (byKey: [String: [PDOnCall]], byPolicy: [String: [PDOnCall]]) {
        var byKey: [String: [PDOnCall]] = [:]
        var byPolicy: [String: [PDOnCall]] = [:]
        for oc in upcoming {
            byKey[upcomingKey(for: oc), default: []].append(oc)
            byPolicy[oc.escalation_policy.id, default: []].append(oc)
        }
        for k in byKey.keys {
            byKey[k]?.sort { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        }
        for k in byPolicy.keys {
            byPolicy[k]?.sort { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        }
        return (byKey, byPolicy)
    }

    /// Next on-call period for the schedule/user that owns `assignment`.
    /// Returns the closest upcoming shift after the assignment's end, preferring
    /// a different user (i.e. an actual handover) when one is available.
    func nextAfter(assignment: OnCallAssignment) -> PDOnCall? {
        let key = assignment.schedule?.id ?? "user:\(assignment.user.id)"
        let list = upcomingByKey[key] ?? []
        let cutoff = assignment.end ?? Date()
        return list.first { ($0.start ?? .distantPast) >= cutoff && $0.user.id != assignment.user.id }
            ?? list.first { ($0.start ?? .distantPast) >= cutoff }
    }

    /// Current + upcoming oncalls for a policy in chronological order, used by the calendar.
    func calendarEntries(for policyID: String) -> [PDOnCall] {
        var entries: [PDOnCall] = []
        entries.append(contentsOf: currentByPolicy[policyID] ?? [])
        entries.append(contentsOf: upcomingByPolicy[policyID] ?? [])
        return entries.sorted {
            (($0.escalation_level, $0.start ?? .distantPast)) < (($1.escalation_level, $1.start ?? .distantPast))
        }
    }

    /// Lookup a policy group by id (works for hidden ones too).
    func policyGroup(for policyID: String) -> EscalationPolicyGroup? {
        orderedGroupsIncludingHidden.first { $0.id == policyID }
    }

    static func buildGroups(services: [PDService], onCalls: [PDOnCall], allPolicyRefs: [PDReference]) -> [EscalationPolicyGroup] {
        var servicesByEP: [String: [PDService]] = [:]
        for service in services {
            guard let ep = service.escalation_policy else { continue }
            servicesByEP[ep.id, default: []].append(service)
        }

        var ocByEP: [String: [PDOnCall]] = [:]
        var epRefs: [String: PDReference] = [:]
        for oc in onCalls {
            ocByEP[oc.escalation_policy.id, default: []].append(oc)
            epRefs[oc.escalation_policy.id] = oc.escalation_policy
        }
        // Seed refs from the canonical EP list so EPs with no current shifts
        // still appear (under 'Other policies').
        for ref in allPolicyRefs where epRefs[ref.id] == nil {
            epRefs[ref.id] = ref
        }

        let allEPIDs = Set(servicesByEP.keys)
            .union(ocByEP.keys)
            .union(allPolicyRefs.map(\.id))

        var groups: [EscalationPolicyGroup] = []
        for epID in allEPIDs {
            let policyRef = epRefs[epID]
                ?? servicesByEP[epID]?.first?.escalation_policy
                ?? PDReference(id: epID, summary: "Escalation Policy", html_url: nil, type: "escalation_policy_reference")

            let levelsDict = Dictionary(grouping: ocByEP[epID] ?? [], by: { $0.escalation_level })
            let levels = levelsDict.keys.sorted().map { lvl -> OnCallLevel in
                let assignments = (levelsDict[lvl] ?? [])
                    .map { OnCallAssignment(user: $0.user, schedule: $0.schedule, end: $0.end) }
                    .sorted { ($0.user.summary ?? "") < ($1.user.summary ?? "") }
                return OnCallLevel(level: lvl, assignments: assignments)
            }

            let services = (servicesByEP[epID] ?? []).sorted { $0.name < $1.name }
            groups.append(EscalationPolicyGroup(policy: policyRef, services: services, levels: levels))
        }
        return groups.sorted { ($0.policy.summary ?? "") < ($1.policy.summary ?? "") }
    }

    // MARK: - Timer

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = self?.refreshMinutes ?? 5
                let seconds = UInt64(max(1, minutes) * 60)
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }
}
