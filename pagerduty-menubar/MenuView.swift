import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                        myOnCallSection
                        allGroupsSection
                        hiddenSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(minHeight: 360, maxHeight: 720)
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
                title: store.myOnCallGroups.isEmpty ? "Services & schedules" : "All services",
                count: all.count,
                tint: .secondary
            )
            ForEach(all) { group in
                PolicyCard(group: group, meID: store.me?.id, reorderable: search.isEmpty)
                    .environmentObject(store)
            }
        } else if !search.isEmpty {
            Text("No matches for “\(search)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
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
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if reorderable {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .frame(width: 12, height: 12)
                        .help("Drag to reorder")

                    Button {
                        store.nudgePolicy(group.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!store.canMovePolicy(group.id, by: -1))
                    .help("Move up")

                    Button {
                        store.nudgePolicy(group.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!store.canMovePolicy(group.id, by: 1))
                    .help("Move down")
                }
                Text(group.policy.summary ?? "Escalation policy")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

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
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        )
        .modifier(ReorderModifier(
            enabled: reorderable,
            id: group.id,
            isTargeted: $isDropTargeted,
            onDrop: { sourceID in
                store.movePolicy(sourceID, relativeTo: group.id, before: true)
            }
        ))
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

private struct ReorderModifier: ViewModifier {
    let enabled: Bool
    let id: String
    @Binding var isTargeted: Bool
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    NSItemProvider(object: id as NSString)
                }
                .onDrop(
                    of: [.text, .utf8PlainText, .plainText],
                    isTargeted: $isTargeted
                ) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                        guard let str = obj as? String, str != id else { return }
                        Task { @MainActor in onDrop(str) }
                    }
                    return true
                }
        } else {
            content
        }
    }
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

private struct RoleBadge: View {
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
