import Foundation
import SwiftUI
import Combine

// MARK: - View-ready models

struct OnCallLevel: Identifiable, Hashable {
    var id: Int { level }
    let level: Int
    let assignments: [OnCallAssignment]
}

struct OnCallAssignment: Identifiable, Hashable {
    let user: PDReference
    let schedule: PDReference?
    let end: Date?
    var id: String { "\(user.id)-\(schedule?.id ?? "direct")-\(end?.timeIntervalSince1970 ?? 0)" }

    /// Stable identifier used for hide/show. Falls back to a synthetic key
    /// when no schedule is attached (direct user assignment in an EP).
    var hideKey: String { schedule?.id ?? "user:\(user.id)" }
    var hideLabel: String { schedule?.summary ?? (user.summary ?? "this assignment") }
}

struct EscalationPolicyGroup: Identifiable, Hashable {
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

// MARK: - Store

@MainActor
final class OnCallStore: ObservableObject {
    // Public state
    @Published private(set) var me: PDUser?
    @Published private(set) var groups: [EscalationPolicyGroup] = []
    @Published private(set) var state: LoadState = .idle
    @Published var hasToken: Bool = false

    // Settings (refresh interval keeps using @AppStorage — it's a simple Int)
    @AppStorage("refreshMinutes") var refreshMinutes: Int = 5

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
        if hasToken {
            startTimer()
            refresh()
        }
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

    /// Visible groups in user-preferred order.
    var orderedGroups: [EscalationPolicyGroup] {
        orderedGroupsIncludingHidden.filter { !hiddenPolicyIDs.contains($0.id) }
    }

    /// Public read-only view of the full ordered list (including hidden groups)
    /// for use in Settings reordering UI.
    var orderedGroupsIncludingHiddenPublic: [EscalationPolicyGroup] {
        orderedGroupsIncludingHidden
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

    /// Move the policy with `id` one slot up (toward index 0) or down. No-op if at the edge.
    func nudgePolicy(_ id: String, by delta: Int) {
        var order = orderedGroupsIncludingHidden.map(\.id)
        guard let idx = order.firstIndex(of: id) else { return }
        let target = idx + delta
        guard target >= 0, target < order.count else { return }
        order.remove(at: idx)
        order.insert(id, at: target)
        persistPolicyOrder(order)
    }

    func canMovePolicy(_ id: String, by delta: Int) -> Bool {
        let order = orderedGroupsIncludingHidden.map(\.id)
        guard let idx = order.firstIndex(of: id) else { return false }
        let target = idx + delta
        return target >= 0 && target < order.count
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

    // MARK: - Derived UI helpers

    var menuBarTitle: String {
        let pinned = pinnedAssignments
        if !pinned.isEmpty {
            let parts = pinned.map { item -> String in
                let who = item.assignment.user.summary ?? "—"
                let label = item.assignment.schedule?.summary ?? (item.policy.summary ?? "")
                return label.isEmpty ? who : "\(label): \(who)"
            }
            let joined = parts.joined(separator: " · ")
            return Self.truncate(joined, max: 48)
        }
        switch state {
        case .failed: return "!"
        default: return ""
        }
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    var menuBarSymbol: String {
        if !hasToken { return "bell.slash" }
        switch state {
        case .failed: return "exclamationmark.triangle"
        case .loading where groups.isEmpty: return "bell.badge"
        default:
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
        hasToken = false
        timerTask?.cancel()
        timerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        me = nil
        groups = []
        state = .idle
    }

    // MARK: - Refresh

    func refresh() {
        guard hasToken else {
            state = .failed("No PagerDuty API token set.")
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        guard let token = KeychainStore.loadToken() else {
            state = .failed("No PagerDuty API token set.")
            hasToken = false
            return
        }
        state = .loading
        do {
            let me = try await api.currentUser(token: token)
            let teamIDs = (me.teams ?? []).map { $0.id }
            let services = try await api.services(token: token, teamIDs: teamIDs)
            let policyIDs = Array(Set(services.compactMap { $0.escalation_policy?.id }))
            let onCalls = try await api.onCalls(token: token, escalationPolicyIDs: policyIDs)

            let groups = Self.buildGroups(services: services, onCalls: onCalls)
            self.me = me
            self.groups = groups
            self.state = .loaded(Date())
        } catch {
            self.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func buildGroups(services: [PDService], onCalls: [PDOnCall]) -> [EscalationPolicyGroup] {
        // Index services by escalation policy id.
        var servicesByEP: [String: [PDService]] = [:]
        for service in services {
            guard let ep = service.escalation_policy else { continue }
            servicesByEP[ep.id, default: []].append(service)
        }

        // Group on-calls by EP, then by level.
        var ocByEP: [String: [PDOnCall]] = [:]
        var epRefs: [String: PDReference] = [:]
        for oc in onCalls {
            ocByEP[oc.escalation_policy.id, default: []].append(oc)
            epRefs[oc.escalation_policy.id] = oc.escalation_policy
        }

        // Build groups for every EP we have services for.
        let allEPIDs = Set(servicesByEP.keys).union(ocByEP.keys)
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
