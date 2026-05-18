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

// MARK: - Store

@MainActor
final class OnCallStore: ObservableObject {
    // Public state
    @Published private(set) var me: PDUser?
    @Published private(set) var groups: [EscalationPolicyGroup] = []
    @Published private(set) var state: LoadState = .idle
    @Published var hasToken: Bool = false

    // Settings
    @AppStorage("refreshMinutes") var refreshMinutes: Int = 5

    private let api = PagerDutyAPI()
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    init() {
        self.hasToken = KeychainStore.loadToken() != nil
        if hasToken {
            startTimer()
            refresh()
        }
    }

    // MARK: - Derived UI helpers

    var menuBarTitle: String {
        // Keep the menu bar text short; an icon-only label looks cleanest, but
        // we surface a tiny status hint when something needs attention.
        switch state {
        case .failed: return "!"
        default: return ""
        }
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
        return groups.filter { $0.contains(userID: me.id, atLevelOne: true) }
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
