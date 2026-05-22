import XCTest
@testable import pagerduty_menubar

final class NotificationsCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func ref(_ id: String, _ summary: String? = nil) -> PDReference {
        PDReference(id: id, summary: summary ?? id, html_url: nil, type: nil)
    }

    private func oc(ep: String, level: Int, user: String, epSummary: String? = nil) -> PDOnCall {
        PDOnCall(
            escalation_policy: ref(ep, epSummary),
            escalation_level: level,
            schedule: nil,
            user: ref(user, "User \(user)"),
            start: nil,
            end: nil
        )
    }

    // MARK: - computeOnCallChanges

    func test_compute_handoverEmitsRemovedAndAdded() {
        let prev = ["EP1": [oc(ep: "EP1", level: 1, user: "A")]]
        let curr = ["EP1": [oc(ep: "EP1", level: 1, user: "B")]]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].policyID, "EP1")
        XCTAssertEqual(changes[0].policySummary, "Web")
        XCTAssertEqual(changes[0].level, 1)
        XCTAssertEqual(changes[0].removed.map(\.id), ["A"])
        XCTAssertEqual(changes[0].added.map(\.id), ["B"])
    }

    func test_compute_addedOnly_whenPreviouslyEmpty() {
        let curr = ["EP1": [oc(ep: "EP1", level: 1, user: "A")]]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: [:], current: curr,
            policySummaries: ["EP1": "Web"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].removed.isEmpty)
        XCTAssertEqual(changes[0].added.map(\.id), ["A"])
    }

    func test_compute_removedOnly_fallsBackToPrevSummary() {
        let prev = ["EP1": [oc(ep: "EP1", level: 1, user: "A", epSummary: "Old Name")]]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: [:],
            policySummaries: [:],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].policySummary, "Old Name")
        XCTAssertEqual(changes[0].removed.map(\.id), ["A"])
        XCTAssertTrue(changes[0].added.isEmpty)
    }

    func test_compute_noChange_isEmpty() {
        let prev = ["EP1": [oc(ep: "EP1", level: 1, user: "A")]]
        let curr = ["EP1": [oc(ep: "EP1", level: 1, user: "A")]]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertTrue(changes.isEmpty)
    }

    func test_compute_primaryOnly_usesMinLevelAndIgnoresOthers() {
        // Level 1 unchanged, level 2 swapped — primaryOnly must hide level 2.
        let prev = [
            "EP1": [
                oc(ep: "EP1", level: 1, user: "A"),
                oc(ep: "EP1", level: 2, user: "B"),
            ]
        ]
        let curr = [
            "EP1": [
                oc(ep: "EP1", level: 1, user: "A"),
                oc(ep: "EP1", level: 2, user: "C"),
            ]
        ]
        let primary = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertTrue(primary.isEmpty)

        let all = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web"],
            filterPolicyIDs: nil, primaryOnly: false,
            meOnly: false, myUserID: nil
        )
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].level, 2)
    }

    func test_compute_primaryOnly_minLevelIsRelative_notHardcodedToOne() {
        // EP whose lowest level is 2 (no level 1 present at all).
        let prev = ["EP1": [oc(ep: "EP1", level: 2, user: "A")]]
        let curr = ["EP1": [oc(ep: "EP1", level: 2, user: "B")]]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].level, 2)
    }

    func test_compute_filterPolicyIDs_excludesOthers() {
        let prev = [
            "EP1": [oc(ep: "EP1", level: 1, user: "A")],
            "EP2": [oc(ep: "EP2", level: 1, user: "X")],
        ]
        let curr = [
            "EP1": [oc(ep: "EP1", level: 1, user: "B")],
            "EP2": [oc(ep: "EP2", level: 1, user: "Y")],
        ]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web", "EP2": "Other"],
            filterPolicyIDs: ["EP1"], primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertEqual(changes.map(\.policyID), ["EP1"])
    }

    func test_compute_meOnly_keepsChangesInvolvingMe_dropsOthers() {
        let prev = [
            "EP1": [oc(ep: "EP1", level: 1, user: "ME")],
            "EP2": [oc(ep: "EP2", level: 1, user: "X")],
        ]
        let curr = [
            "EP1": [oc(ep: "EP1", level: 1, user: "B")],
            "EP2": [oc(ep: "EP2", level: 1, user: "Y")],
        ]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web", "EP2": "Other"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: true, myUserID: "ME"
        )
        XCTAssertEqual(changes.map(\.policyID), ["EP1"])
    }

    func test_compute_meOnly_withoutMyUserID_returnsEmpty() {
        let prev = ["EP1": [oc(ep: "EP1", level: 1, user: "A")]]
        let curr = ["EP1": [oc(ep: "EP1", level: 1, user: "B")]]
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Web"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: true, myUserID: nil
        )
        XCTAssertTrue(changes.isEmpty)
    }

    func test_compute_sortedDeterministically() {
        let prev = [
            "EP1": [oc(ep: "EP1", level: 1, user: "A")],
            "EP2": [oc(ep: "EP2", level: 1, user: "A")],
        ]
        let curr = [
            "EP1": [oc(ep: "EP1", level: 1, user: "B")],
            "EP2": [oc(ep: "EP2", level: 1, user: "B")],
        ]
        // "Bravo" sorts after "Alpha".
        let changes = NotificationsCoordinator.computeOnCallChanges(
            previous: prev, current: curr,
            policySummaries: ["EP1": "Bravo", "EP2": "Alpha"],
            filterPolicyIDs: nil, primaryOnly: true,
            meOnly: false, myUserID: nil
        )
        XCTAssertEqual(changes.map(\.policySummary), ["Alpha", "Bravo"])
    }

    // MARK: - formatOnCallChanges

    func test_format_singleChange_scopedTitle_noPolicyInBody() {
        let c = NotificationsCoordinator.OnCallChange(
            policyID: "EP1", policySummary: "Web", level: 1,
            removed: [ref("A", "User A")],
            added: [ref("B", "User B")]
        )
        let (title, body) = NotificationsCoordinator.formatOnCallChanges([c])
        XCTAssertEqual(title, "On-call: Web")
        XCTAssertEqual(body, "User A → User B")
    }

    func test_format_singleChange_addedOnly() {
        let c = NotificationsCoordinator.OnCallChange(
            policyID: "EP1", policySummary: "Web", level: 1,
            removed: [],
            added: [ref("B", "User B")]
        )
        let (_, body) = NotificationsCoordinator.formatOnCallChanges([c])
        XCTAssertEqual(body, "Now on call: User B")
    }

    func test_format_singleChange_removedOnly() {
        let c = NotificationsCoordinator.OnCallChange(
            policyID: "EP1", policySummary: "Web", level: 1,
            removed: [ref("A", "User A")],
            added: []
        )
        let (_, body) = NotificationsCoordinator.formatOnCallChanges([c])
        XCTAssertEqual(body, "Off call: User A")
    }

    func test_format_singleChange_nonPrimaryLevelAnnotated() {
        let c = NotificationsCoordinator.OnCallChange(
            policyID: "EP1", policySummary: "Web", level: 3,
            removed: [ref("A", "User A")],
            added: [ref("B", "User B")]
        )
        let (_, body) = NotificationsCoordinator.formatOnCallChanges([c])
        XCTAssertEqual(body, "User A → User B (L3)")
    }

    func test_format_multipleChanges_includesPolicyName_andCountInTitle() {
        let cs = (0..<3).map { i in
            NotificationsCoordinator.OnCallChange(
                policyID: "EP\(i)", policySummary: "P\(i)", level: 1,
                removed: [ref("A\(i)", "User A\(i)")],
                added: [ref("B\(i)", "User B\(i)")]
            )
        }
        let (title, body) = NotificationsCoordinator.formatOnCallChanges(cs)
        XCTAssertEqual(title, "3 on-call changes")
        let lines = body.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("P0:"))
    }

    func test_format_multipleChanges_truncatesAtFiveWithEllipsisTail() {
        let cs = (0..<8).map { i in
            NotificationsCoordinator.OnCallChange(
                policyID: "EP\(i)", policySummary: "P\(i)", level: 1,
                removed: [], added: [ref("B\(i)", "User B\(i)")]
            )
        }
        let (title, body) = NotificationsCoordinator.formatOnCallChanges(cs)
        XCTAssertEqual(title, "8 on-call changes")
        let lines = body.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 6) // 5 detail + 1 tail
        XCTAssertEqual(lines.last, "…and 3 more")
    }
}
