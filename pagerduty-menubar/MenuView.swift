import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings

    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .onChange(of: search) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.loadOtherIncidentsIfNeeded()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await store.refreshIncidents()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: store.menuBarSymbol)
                .foregroundStyle(.tint)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle).font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(!store.hasToken || store.state == .loading)

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        if let me = store.me { return me.name }
        return "PagerDuty"
    }

    private var headerSubtitle: String {
        switch store.state {
        case .idle: return store.hasToken ? "Ready" : "Add an API token in Settings"
        case .loading: return "Refreshing…"
        case .loaded(let date): return "Updated \(Self.relative.localizedString(for: date, relativeTo: Date()))"
        case .failed(let msg): return msg
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !store.hasToken {
            emptyState(
                icon: "key.horizontal",
                title: "No API token",
                message: "Open Settings and paste a PagerDuty REST API user token.",
                actionTitle: "Open Settings"
            ) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        } else if case .failed(let msg) = store.state, store.groups.isEmpty {
            emptyState(
                icon: "exclamationmark.triangle",
                title: "Couldn't fetch on-calls",
                message: msg,
                actionTitle: "Try again",
                action: { store.refresh() }
            )
        } else if store.groups.isEmpty && store.state == .loading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading on-calls…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else if store.groups.isEmpty {
            emptyState(
                icon: "person.2.slash",
                title: "Nothing to show yet",
                message: "No services or escalation policies found via your teams.",
                actionTitle: "Refresh",
                action: { store.refresh() }
            )
        } else {
            VStack(spacing: 0) {
                searchBar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        incidentErrorBanner
                        incidentUndoStrip
                        myIncidentsSection
                        myUpcomingSection
                        myOnCallSection
                        allGroupsSection
                        otherPoliciesSection
                        otherIncidentsSection
                        hiddenSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(minHeight: 460, maxHeight: 840)
            }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Filter services, people, or policies", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Sections

    @ViewBuilder
    private var myUpcomingSection: some View {
        let shifts = filteredShifts(store.myUpcomingShifts)
        sectionHeader(
            symbol: "person.crop.circle.badge.clock",
            title: "Your on-call schedule",
            count: shifts.count,
            tint: .accentColor
        )
        if shifts.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text("No on-calls in the next \(OnCallStore.lookaheadDays) days")
                        .font(.system(size: 11, weight: .medium))
                    if store.me == nil {
                        Text("Waiting for user info…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("You're free until at least \(Self.windowEndLabel)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(spacing: 4) {
                ForEach(shifts) { shift in
                    MyShiftRow(shift: shift)
                }
            }
        }
    }

    private static var windowEndLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: OnCallStore.lookaheadDays, to: Date()) ?? Date()
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: end)
    }

    // MARK: - Incidents

    @ViewBuilder
    private var incidentErrorBanner: some View {
        if let err = store.incidentMutationError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 11))
                    .lineLimit(2)
                Spacer()
                Button("Dismiss") { store.dismissIncidentError() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var incidentUndoStrip: some View {
        if let undo = store.recentIncidentAction {
            HStack(spacing: 8) {
                Image(systemName: undo.newStatus == "resolved" ? "checkmark.seal.fill" : "bell.badge")
                    .foregroundStyle(undo.newStatus == "resolved" ? .green : .blue)
                Text("\(undo.newStatus.capitalized) “\(undo.title)”")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
                Button("Undo") { store.undoLastIncidentAction() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .task(id: undo.incidentID) {
                try? await Task.sleep(nanoseconds: 5_500_000_000)
                store.dismissUndoIfExpired()
            }
        }
    }

    @ViewBuilder
    private var myIncidentsSection: some View {
        let mine = filteredIncidents(store.myActiveIncidents)
        if !mine.isEmpty {
            sectionHeader(symbol: "exclamationmark.bubble", title: "My active incidents", count: mine.count, tint: .red)
            VStack(spacing: 4) {
                ForEach(mine) { inc in IncidentRow(incident: inc, isMine: true) }
            }
        }
    }

    @ViewBuilder
    private var otherIncidentsSection: some View {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let loaded = store.otherIncidentsLoaded
        let all = store.otherActiveIncidents
        let matches: [PDIncident] = q.isEmpty ? [] : all.filter { inc in
            inc.title.lowercased().contains(q) ||
            (inc.service?.summary ?? "").lowercased().contains(q) ||
            (inc.assignments?.contains { ($0.assignee.summary ?? "").lowercased().contains(q) } ?? false)
        }
        let count = loaded ? (q.isEmpty ? all.count : matches.count) : 0
        sectionHeader(symbol: "tray", title: "Other active incidents", count: count, tint: .secondary)
        if q.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(loaded
                    ? "Type above to search \(all.count) other active incident\(all.count == 1 ? "" : "s") on this PagerDuty account."
                    : "Type above to load and search active incidents from across the account."
                )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        } else if !loaded {
            HStack(spacing: 8) {
                if store.otherIncidentsLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading other incidents…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text("Tap to load other active incidents").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Load") { store.loadOtherIncidentsIfNeeded() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { store.loadOtherIncidentsIfNeeded() }
        } else if matches.isEmpty {
            Text("No other incidents match “\(search)”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 4) {
                ForEach(matches.prefix(20)) { inc in IncidentRow(incident: inc, isMine: false) }
                if matches.count > 20 {
                    Text("Showing 20 of \(matches.count) — refine the search.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func filteredIncidents(_ input: [PDIncident]) -> [PDIncident] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return input }
        return input.filter { inc in
            inc.title.lowercased().contains(q) ||
            (inc.service?.summary ?? "").lowercased().contains(q)
        }
    }

    private func filteredShifts(_ input: [MyShift]) -> [MyShift] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return input }
        return input.filter {
            ($0.policySummary ?? "").lowercased().contains(q) ||
            ($0.schedule?.summary ?? "").lowercased().contains(q)
        }
    }

    @ViewBuilder
    private var myOnCallSection: some View {
        let mine = filteredGroups(store.myOnCallGroups)
        if !mine.isEmpty {
            sectionHeader(symbol: "bell.fill", title: "You're on call", count: mine.count, tint: .orange)
            ForEach(mine) { group in
                PolicyCard(group: group, meID: store.me?.id, reorderable: false)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private var allGroupsSection: some View {
        let all = filteredGroups(store.orderedGroups)
        if !all.isEmpty {
            sectionHeader(
                symbol: "list.bullet.rectangle",
                title: "My services & schedules",
                count: all.count,
                tint: .secondary
            )
            ForEach(all) { group in
                PolicyCard(group: group, meID: store.me?.id, reorderable: search.isEmpty)
                    .environmentObject(store)
            }
        } else if !search.isEmpty && store.otherGroups.isEmpty {
            Text("No matches for “\(search)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var otherPoliciesSection: some View {
        let all = store.otherGroups
        if all.isEmpty { EmptyView() } else {
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches = q.isEmpty ? [] : all.filter { g in
                if (g.policy.summary ?? "").lowercased().contains(q) { return true }
                if g.levels.contains(where: { $0.assignments.contains { ($0.user.summary ?? "").lowercased().contains(q) } }) { return true }
                return false
            }
            let displayCount = q.isEmpty ? all.count : matches.count

            sectionHeader(
                symbol: "tray.full",
                title: "Other services & schedules",
                count: displayCount,
                tint: .secondary
            )

            if q.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text("Type above to search \(all.count) other service\(all.count == 1 ? "" : "s") & schedules on this PagerDuty account.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            } else if matches.isEmpty {
                Text("No other services or schedules match “\(search)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(matches.prefix(20).map { $0 }) { group in
                        OtherPolicyRow(group: group)
                            .environmentObject(store)
                    }
                    if matches.count > 20 {
                        Text("Showing 20 of \(matches.count) matches — refine the search to narrow further.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = filteredGroups(store.hiddenPolicies)
        if !hidden.isEmpty {
            sectionHeader(symbol: "eye.slash", title: "Hidden services", count: hidden.count, tint: .secondary)
            VStack(spacing: 6) {
                ForEach(hidden) { group in
                    HiddenPolicyRow(group: group)
                        .environmentObject(store)
                }
            }
        }
    }

    private func sectionHeader(symbol: String, title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Spacer()
        }
    }

    private func filteredGroups(_ input: [EscalationPolicyGroup]) -> [EscalationPolicyGroup] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return input }
        return input.filter { g in
            if (g.policy.summary ?? "").lowercased().contains(q) { return true }
            if g.services.contains(where: { $0.name.lowercased().contains(q) }) { return true }
            if g.levels.contains(where: { $0.assignments.contains { ($0.user.summary ?? "").lowercased().contains(q) } }) { return true }
            return false
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                if let url = URL(string: "https://app.pagerduty.com") { openURL(url) }
            } label: {
                Label("Open PagerDuty", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))

            Spacer()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Text("Settings")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private func emptyState(icon: String, title: String, message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Policy card

private struct PolicyCard: View {
    let group: EscalationPolicyGroup
    let meID: String?
    let reorderable: Bool

    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL
    @State private var showCalendar: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                if reorderable {
                    VStack(spacing: 1) {
                        Button {
                            store.nudgePolicy(group.id, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 18, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canMovePolicy(group.id, by: -1))
                        .help("Move up")

                        Button {
                            store.nudgePolicy(group.id, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 18, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canMovePolicy(group.id, by: 1))
                        .help("Move down")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
                }
                Text(group.policy.summary ?? "Escalation policy")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    showCalendar.toggle()
                } label: {
                    Image(systemName: showCalendar ? "calendar.circle.fill" : "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(showCalendar ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showCalendar ? "Hide schedule calendar" : "Show schedule calendar")
                .popover(isPresented: $showCalendar, arrowEdge: .trailing) {
                    CalendarPopoverView(policyID: group.id)
                        .environmentObject(store)
                }

                if let url = group.policy.html_url, let u = URL(string: url) {
                    Button {
                        openURL(u)
                    } label: {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Open escalation policy in PagerDuty")
                }

                Button {
                    store.setPolicyHidden(group.id, hidden: true)
                } label: {
                    Image(systemName: "eye.slash").font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide this service")
            }

            if !group.services.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(group.services) { svc in
                        ServiceChip(service: svc)
                    }
                }
            }

            // Primary level — full-detail rows
            if let primary = group.primaryLevel {
                if primary.assignments.isEmpty {
                    Text("No one currently on call")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(primary.assignments) { a in
                        AssignmentRow(
                            assignment: a,
                            level: primary.level,
                            isMe: a.user.id == meID,
                            isPrimary: true
                        )
                    }
                }
            } else {
                Text("No one currently on call")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Non-primary levels — always shown, compact one-liners
            let escalation = group.levels.dropFirst()
            if !escalation.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(escalation), id: \.level) { lvl in
                        ForEach(lvl.assignments) { a in
                            CompactAssignmentRow(
                                assignment: a,
                                level: lvl.level,
                                isMe: a.user.id == meID
                            )
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct CompactAssignmentRow: View {
    let assignment: OnCallAssignment
    let level: Int
    let isMe: Bool

    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    private var isPinned: Bool { store.isPinned(key: assignment.hideKey) }

    var body: some View {
        HStack(spacing: 6) {
            RoleBadge(level: level, compact: true)
            Text(assignment.user.summary ?? "Unknown")
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isMe {
                Text("You")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 0)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            if isPinned {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
            }
            if let sched = assignment.schedule?.summary {
                Text("· \(sched)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)

            if hovering {
                Button {
                    store.setPinned(key: assignment.hideKey, pinned: !isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                        .rotationEffect(.degrees(45))
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "Remove from menu bar" : "Show in menu bar")
            } else if let end = assignment.end {
                Text(Self.endFormatter.string(from: end))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("On call until \(end.formatted(date: .complete, time: .shortened))")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let s = assignment.user.html_url, let u = URL(string: s) { openURL(u) }
        }
    }

    private static let endFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

private struct HiddenPolicyRow: View {
    let group: EscalationPolicyGroup
    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.policy.summary ?? "Escalation policy")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let primary = group.primaryLevel?.assignments.first {
                    Text("Primary: \(primary.user.summary ?? "—")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !group.services.isEmpty {
                    Text(group.services.map(\.name).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                store.setPolicyHidden(group.id, hidden: false)
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Unhide “\(group.policy.summary ?? "service")”")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(0.7)
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = group.policy.html_url, let u = URL(string: s) { openURL(u) }
        }
    }
}

private struct ServiceChip: View {
    let service: PDService
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let s = service.html_url, let u = URL(string: s) { openURL(u) }
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(service.name).font(.system(size: 10))
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(service.html_url ?? service.name)
    }

    private var statusColor: Color {
        switch service.status {
        case "active": return .green
        case "warning": return .yellow
        case "critical", "maintenance": return .orange
        case "disabled": return .gray
        default: return .secondary
        }
    }
}

private struct AssignmentRow: View {
    let assignment: OnCallAssignment
    let level: Int
    let isMe: Bool
    let isPrimary: Bool

    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL

    private var isPinned: Bool { store.isPinned(key: assignment.hideKey) }

    var body: some View {
        HStack(spacing: 8) {
            Avatar(initials: initials(for: assignment.user.summary ?? "?"), highlighted: isMe)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(assignment.user.summary ?? "Unknown")
                        .font(.system(size: 12, weight: isPrimary ? .medium : .regular))
                        .lineLimit(1)
                    if isMe {
                        Text("You")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    RoleBadge(level: level)
                    if isPinned {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Showing in menu bar")
                    }
                }
                if let sched = assignment.schedule?.summary {
                    Text(sched).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let next = store.nextAfter(assignment: assignment) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text("Next: ")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        + Text(next.user.summary ?? "—").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        + Text(next.start.map { " · \(Self.handoverFormatter.string(from: $0))" } ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
            }
            Spacer()
            if let end = assignment.end {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Until")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(Self.endFormatter.string(from: end))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(end.formatted(date: .complete, time: .shortened))
                }
            }
            Button {
                store.setPinned(key: assignment.hideKey, pinned: !isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                    .rotationEffect(.degrees(45))
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "Remove from menu bar" : "Show in menu bar")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = assignment.user.html_url, let u = URL(string: s) { openURL(u) }
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first.map(String.init) }
        return chars.joined().uppercased()
    }

    private static let endFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let handoverFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct Avatar: View {
    let initials: String
    let highlighted: Bool

    var body: some View {
        ZStack {
            Circle().fill(highlighted ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.18))
            Text(initials)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
        }
        .frame(width: 22, height: 22)
    }
}

struct RoleBadge: View {
    let level: Int
    var compact: Bool = false

    private var label: String {
        switch level {
        case 1: return compact ? "1°" : "Primary"
        case 2: return compact ? "2°" : "Secondary"
        case 3: return compact ? "3°" : "Tertiary"
        default: return compact ? "L\(level)" : "Level \(level)"
        }
    }

    private var tint: Color {
        switch level {
        case 1: return .orange
        case 2: return .blue
        case 3: return .purple
        default: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: compact ? 9 : 9, weight: .bold))
            .padding(.horizontal, compact ? 4 : 5).padding(.vertical, compact ? 0 : 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Flow layout for service chips

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxRowWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxRowWidth = max(maxRowWidth, x)
        }
        return CGSize(width: maxRowWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > maxWidth, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct MyShiftRow: View {
    let shift: MyShift

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(tint.opacity(shift.isCurrent ? 0.9 : 0.18))
                    .frame(width: 24, height: 24)
                Image(systemName: shift.isCurrent ? "bell.fill" : "calendar")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(shift.isCurrent ? Color.white : tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(shift.policySummary ?? "Escalation policy")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    RoleBadge(level: shift.level, compact: true)
                }
                Text(captionText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(shift.isCurrent ? "On call now" : startLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(shift.isCurrent ? Color.orange : .primary)
                if let dur = durationLabel {
                    Text(dur)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(shift.isCurrent ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(shift.isCurrent ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
    }

    private var tint: Color {
        switch shift.level {
        case 1: return .orange
        case 2: return .blue
        case 3: return .purple
        default: return .secondary
        }
    }

    private var captionText: String {
        var parts: [String] = []
        if let sched = shift.schedule?.summary { parts.append(sched) }
        if let end = shift.end {
            parts.append("until \(Self.short.string(from: end))")
        }
        return parts.joined(separator: " · ")
    }

    private var startLabel: String {
        guard let s = shift.start else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(s) || cal.isDateInTomorrow(s) {
            return Self.short.string(from: s)
        }
        let days = cal.dateComponents([.day], from: Date(), to: s).day ?? 0
        if days < 7 {
            let dow = DateFormatter(); dow.dateFormat = "EEE"
            let t = DateFormatter(); t.timeStyle = .short; t.dateStyle = .none
            return "\(dow.string(from: s)) \(t.string(from: s))"
        }
        return Self.short.string(from: s)
    }

    private var durationLabel: String? {
        guard let s = shift.start, let e = shift.end else { return nil }
        let secs = e.timeIntervalSince(max(s, Date()))
        if secs <= 0 { return nil }
        let hours = Int(secs / 3600)
        if hours < 24 {
            return shift.isCurrent ? "\(hours)h left" : "\(hours)h shift"
        }
        let days = hours / 24
        let leftover = hours % 24
        let label = leftover == 0 ? "\(days)d" : "\(days)d \(leftover)h"
        return shift.isCurrent ? "\(label) left" : "\(label) shift"
    }

    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct OtherPolicyRow: View {
    let group: EscalationPolicyGroup
    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL
    @State private var showCalendar = false

    private var primaryUser: String? {
        group.primaryLevel?.assignments.first?.user.summary
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.policy.summary ?? "Escalation policy")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(primaryUser.map { "Primary: \($0)" } ?? "No one currently on call")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                showCalendar.toggle()
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show schedule calendar")
            .popover(isPresented: $showCalendar, arrowEdge: .trailing) {
                CalendarPopoverView(policyID: group.id)
                    .environmentObject(store)
            }
            if let url = group.policy.html_url, let u = URL(string: url) {
                Button {
                    openURL(u)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open in PagerDuty")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct IncidentRow: View {
    let incident: PDIncident
    let isMine: Bool

    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    private var isPending: Bool { store.pendingIncidentIDs.contains(incident.id) }
    private var assigneeLabel: String? { incident.assignments?.first?.assignee.summary }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(urgencyTint.opacity(0.18))
                    .frame(width: 22, height: 22)
                Image(systemName: incident.status == "acknowledged" ? "bell.badge" : "bell.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(urgencyTint)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(incident.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    UrgencyBadge(urgency: incident.urgency, status: incident.status)
                }
                HStack(spacing: 4) {
                    if let svc = incident.service?.summary {
                        Text(svc).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let assignee = assigneeLabel {
                        Text("· \(assignee)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let created = incident.created_at {
                        Text("· \(Self.relative.localizedString(for: created, relativeTo: Date()))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            if isPending {
                ProgressView().controlSize(.small)
            } else if isMine, hovering || incident.status == "acknowledged" {
                if incident.status == "triggered" {
                    Button("Ack") { store.updateIncidentStatus(incident.id, to: "acknowledged") }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Acknowledge")
                }
                Button("Resolve") { store.updateIncidentStatus(incident.id, to: "resolved") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.green)
                    .help("Resolve")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isMine ? Color.red.opacity(0.06) : Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isMine ? Color.red.opacity(0.25) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let s = incident.html_url, let u = URL(string: s) { openURL(u) }
        }
    }

    private var urgencyTint: Color {
        incident.urgency == "high" ? .red : .blue
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

private struct UrgencyBadge: View {
    let urgency: String
    let status: String

    var body: some View {
        let (label, tint) = render
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var render: (String, Color) {
        if status == "acknowledged" { return ("ACK", .blue) }
        return urgency == "high" ? ("HIGH", .red) : ("LOW", .secondary)
    }
}
