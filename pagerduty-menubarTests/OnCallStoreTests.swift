import XCTest
@testable import pagerduty_menubar

@MainActor
final class OnCallStoreTests: XCTestCase {

    // MARK: - Helpers

    private func ref(_ id: String, _ summary: String? = nil) -> PDReference {
        PDReference(id: id, summary: summary ?? id, html_url: "https://example/\(id)", type: nil)
    }

    private func oc(ep: String, level: Int, user: String, schedule: String? = nil, start: Date? = nil, end: Date? = nil) -> PDOnCall {
        PDOnCall(
            escalation_policy: ref(ep),
            escalation_level: level,
            schedule: schedule.map { ref($0) },
            user: ref(user, "User \(user)"),
            start: start,
            end: end
        )
    }

    // MARK: - Static helpers: condense / firstName

    func test_firstName_extractsFirstSpaceSeparatedToken() {
        XCTAssertEqual(OnCallStore.firstName(of: "Alice Smith"), "Alice")
        XCTAssertEqual(OnCallStore.firstName(of: "Alice"), "Alice")
        XCTAssertEqual(OnCallStore.firstName(of: ""), "")
    }

    func test_condense_emptyReturnsEmpty() {
        XCTAssertEqual(OnCallStore.condense([], maxLength: 24), "")
    }

    func test_condense_singleNameFitsAsIs() {
        XCTAssertEqual(OnCallStore.condense(["Alice"], maxLength: 24), "Alice")
    }

    func test_condense_twoShortNamesFitFully_noOverflowSuffix() {
        XCTAssertEqual(OnCallStore.condense(["Alice", "Bob"], maxLength: 40), "Alice · Bob")
    }

    func test_condense_overflowAppendsPlusN() {
        let s = OnCallStore.condense(["Alice", "Bob", "Carol", "David", "Eve"], maxLength: 15)
        XCTAssertTrue(s.hasSuffix("+3") || s.hasSuffix("+2") || s.hasSuffix("+1"), "got: \(s)")
        XCTAssertTrue(s.contains("Alice"))
    }

    func test_condense_singleOversizeNameIsTruncated() {
        let s = OnCallStore.condense(["Bartholomew"], maxLength: 6)
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertEqual(s.count, 6)
    }

    // MARK: - buildGroups

    func test_buildGroups_groupsByPolicyAndLevel_andSortsAssignmentsByUserSummary() {
        let svc = PDService(id: "S1", name: "Web", html_url: nil, status: "active",
                            escalation_policy: ref("EP1"), teams: nil)
        let oncalls: [PDOnCall] = [
            oc(ep: "EP1", level: 1, user: "Z"),   // Z out of order on purpose
            oc(ep: "EP1", level: 1, user: "A"),
            oc(ep: "EP1", level: 2, user: "M"),
        ]
        let groups = OnCallStore.buildGroups(services: [svc], onCalls: oncalls, allPolicyRefs: [])
        XCTAssertEqual(groups.count, 1)
        let g = groups[0]
        XCTAssertEqual(g.id, "EP1")
        XCTAssertEqual(g.services.first?.id, "S1")
        XCTAssertEqual(g.levels.map(\.level), [1, 2])
        // Level 1 assignments sorted by user.summary
        XCTAssertEqual(g.primaryLevel?.assignments.map { $0.user.id }, ["A", "Z"])
    }

    func test_buildGroups_includesPoliciesFromAllPolicyRefsEvenWithNoShifts() {
        let svc = PDService(id: "S1", name: "Web", html_url: nil, status: "active",
                            escalation_policy: ref("EP1"), teams: nil)
        let groups = OnCallStore.buildGroups(
            services: [svc],
            onCalls: [],
            allPolicyRefs: [ref("EP_OTHER", "Other Policy")]
        )
        let ids = Set(groups.map(\.id))
        XCTAssertTrue(ids.contains("EP1"))
        XCTAssertTrue(ids.contains("EP_OTHER"))
        let other = groups.first { $0.id == "EP_OTHER" }!
        XCTAssertTrue(other.levels.isEmpty)
        XCTAssertNil(other.primaryLevel)
    }

    // MARK: - upcoming indexes / nextAfter

    func test_buildUpcomingIndexes_keysByScheduleIDOrUserFallback() {
        let now = Date()
        let withSched = oc(ep: "EP1", level: 1, user: "U1", schedule: "SCH1", start: now.addingTimeInterval(3600))
        let withoutSched = oc(ep: "EP2", level: 1, user: "U2", schedule: nil, start: now.addingTimeInterval(7200))
        let (byKey, byPolicy) = OnCallStore.buildUpcomingIndexes(upcoming: [withSched, withoutSched])
        XCTAssertEqual(byKey["SCH1"]?.count, 1)
        XCTAssertEqual(byKey["user:U2"]?.count, 1)
        XCTAssertEqual(byPolicy["EP1"]?.count, 1)
        XCTAssertEqual(byPolicy["EP2"]?.count, 1)
    }

    func test_nextAfter_picksNextShiftAfterEndAndPrefersDifferentUser() {
        let now = Date()
        let cutoff = now.addingTimeInterval(3600)
        let nextSame = oc(ep: "EP1", level: 1, user: "U1", schedule: "SCH1", start: cutoff.addingTimeInterval(60))
        let nextDifferent = oc(ep: "EP1", level: 1, user: "U2", schedule: "SCH1", start: cutoff.addingTimeInterval(120))
        let store = OnCallStore(testUpcomingByKey: ["SCH1": [nextSame, nextDifferent]])
        let assignment = OnCallAssignment(user: ref("U1"), schedule: ref("SCH1"), end: cutoff)
        let next = store.nextAfter(assignment: assignment)
        XCTAssertEqual(next?.user.id, "U2", "should prefer a different user (a real handover)")
    }

    func test_nextAfter_fallsBackToSameUserIfThatIsAllWeHave() {
        let now = Date()
        let cutoff = now.addingTimeInterval(3600)
        let only = oc(ep: "EP1", level: 1, user: "U1", schedule: "SCH1", start: cutoff.addingTimeInterval(60))
        let store = OnCallStore(testUpcomingByKey: ["SCH1": [only]])
        let assignment = OnCallAssignment(user: ref("U1"), schedule: ref("SCH1"), end: cutoff)
        XCTAssertEqual(store.nextAfter(assignment: assignment)?.user.id, "U1")
    }

    // MARK: - orderedGroups / hide / nudge / canMove

    private func makeStoreWithThreeMyPolicies() -> OnCallStore {
        let g = (1...3).map { i in
            EscalationPolicyGroup(policy: ref("EP\(i)", "Policy \(i)"), services: [], levels: [])
        }
        return OnCallStore(
            testGroups: g,
            testMyPolicyIDs: Set(["EP1", "EP2", "EP3"])
        )
    }

    func test_orderedGroups_respectsPolicyOrderThenAlphaForUnranked() {
        let g = (1...3).map { i in
            EscalationPolicyGroup(policy: ref("EP\(i)", "Policy \(i)"), services: [], levels: [])
        }
        let store = OnCallStore(
            testGroups: g,
            testMyPolicyIDs: Set(["EP1", "EP2", "EP3"]),
            testPolicyOrder: ["EP2"]   // EP2 first, EP1 and EP3 follow alphabetically
        )
        XCTAssertEqual(store.orderedGroups.map(\.id), ["EP2", "EP1", "EP3"])
    }

    func test_orderedGroups_excludesHiddenAndOtherPolicies() {
        let g = (1...3).map { i in
            EscalationPolicyGroup(policy: ref("EP\(i)", "Policy \(i)"), services: [], levels: [])
        }
        let store = OnCallStore(
            testGroups: g,
            testMyPolicyIDs: Set(["EP1", "EP2"]),       // EP3 belongs to 'other'
            testHiddenPolicyIDs: Set(["EP1"])
        )
        XCTAssertEqual(store.orderedGroups.map(\.id), ["EP2"])
    }

    func test_otherGroups_returnsPoliciesNotInMine_alphabetically() {
        let g = (1...3).map { i in
            EscalationPolicyGroup(policy: ref("EP\(i)", "Policy \(i)"), services: [], levels: [])
        }
        let store = OnCallStore(
            testGroups: g,
            testMyPolicyIDs: Set(["EP2"])
        )
        XCTAssertEqual(store.otherGroups.map(\.id), ["EP1", "EP3"])
    }

    func test_nudgePolicy_movesUpAndDown_andHonoursEdges() {
        let store = makeStoreWithThreeMyPolicies()
        // Initial alpha order: EP1, EP2, EP3
        XCTAssertTrue(store.canMovePolicy("EP1", by: 1))
        XCTAssertFalse(store.canMovePolicy("EP1", by: -1))
        store.nudgePolicy("EP3", by: -1)
        XCTAssertEqual(store.orderedGroups.map(\.id), ["EP1", "EP3", "EP2"])
        store.nudgePolicy("EP3", by: -1)
        XCTAssertEqual(store.orderedGroups.map(\.id), ["EP3", "EP1", "EP2"])
        // No-op at top
        store.nudgePolicy("EP3", by: -1)
        XCTAssertEqual(store.orderedGroups.map(\.id), ["EP3", "EP1", "EP2"])
    }

    // MARK: - calendarEntries

    func test_calendarEntries_combinesCurrentAndUpcoming_sortedByLevelThenStart() {
        let now = Date()
        let cur1 = oc(ep: "EP1", level: 1, user: "U1", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        let upL1 = oc(ep: "EP1", level: 1, user: "U2", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))
        let upL2 = oc(ep: "EP1", level: 2, user: "U3", start: now.addingTimeInterval(60), end: now.addingTimeInterval(7200))
        let store = OnCallStore(
            testCurrentByPolicy: ["EP1": [cur1]],
            testUpcomingByPolicy: ["EP1": [upL1, upL2]]
        )
        let entries = store.calendarEntries(for: "EP1")
        XCTAssertEqual(entries.map(\.escalation_level), [1, 1, 2])
        XCTAssertEqual(entries.map(\.user.id), ["U1", "U2", "U3"])
    }

    // MARK: - myUpcomingShifts / menuBarTitle

    func test_myUpcomingShifts_collatesCurrentThenUpcomingForMe_sortedByStart() {
        let now = Date()
        let me = PDUser(id: "ME", name: "Me", email: nil, html_url: nil, avatar_url: nil, time_zone: nil, teams: nil)
        let curMe = oc(ep: "EP1", level: 1, user: "ME", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(1800))
        let curOther = oc(ep: "EP1", level: 1, user: "U1", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(1800))
        let upMeLater = oc(ep: "EP1", level: 2, user: "ME", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(10800))
        let upMeSooner = oc(ep: "EP2", level: 1, user: "ME", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))
        let upOther = oc(ep: "EP1", level: 1, user: "U2", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))
        let store = OnCallStore(
            testMe: me,
            testCurrentByPolicy: ["EP1": [curMe, curOther]],
            testUpcomingByPolicy: ["EP1": [upMeLater, upOther], "EP2": [upMeSooner]]
        )
        let shifts = store.myUpcomingShifts
        XCTAssertEqual(shifts.count, 3)
        XCTAssertEqual(shifts.map(\.policyID), ["EP1", "EP2", "EP1"])  // sorted by start asc
        XCTAssertTrue(shifts[0].isCurrent)
        XCTAssertFalse(shifts[1].isCurrent)
    }

    func test_menuBarTitle_emptyWhenNoPinsAndNoError() {
        let store = OnCallStore()
        XCTAssertEqual(store.menuBarTitle, "")
    }

    func test_menuBarTitle_twoPinnedRendersBothFirstNames() {
        let p1 = oc(ep: "EP1", level: 1, user: "U1", schedule: "SCH1")
        let p2 = oc(ep: "EP2", level: 1, user: "U2", schedule: "SCH2")
        // Override the user summary to a multi-word name
        let p1b = PDOnCall(escalation_policy: p1.escalation_policy, escalation_level: 1,
                           schedule: p1.schedule,
                           user: PDReference(id: "U1", summary: "Alice Smith", html_url: nil, type: nil),
                           start: nil, end: nil)
        let p2b = PDOnCall(escalation_policy: p2.escalation_policy, escalation_level: 1,
                           schedule: p2.schedule,
                           user: PDReference(id: "U2", summary: "Bob Jones", html_url: nil, type: nil),
                           start: nil, end: nil)
        let store = OnCallStore(
            testGroups: [
                EscalationPolicyGroup(
                    policy: ref("EP1"),
                    services: [],
                    levels: [OnCallLevel(level: 1, assignments: [OnCallAssignment(user: p1b.user, schedule: p1b.schedule, end: nil)])]
                ),
                EscalationPolicyGroup(
                    policy: ref("EP2"),
                    services: [],
                    levels: [OnCallLevel(level: 1, assignments: [OnCallAssignment(user: p2b.user, schedule: p2b.schedule, end: nil)])]
                ),
            ],
            testPinnedKeys: ["SCH1", "SCH2"]
        )
        XCTAssertEqual(store.menuBarTitle, "Alice · Bob")
    }
}
