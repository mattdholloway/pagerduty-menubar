import SwiftUI

/// Schedule calendar shown as a side-flyout popover from a policy card.
/// Gantt-style: one row per (level, schedule), bars per shift, colored by level.
struct CalendarPopoverView: View {
    let policyID: String
    @EnvironmentObject private var store: OnCallStore
    @Environment(\.openURL) private var openURL

    @State private var anchor: Date = Calendar.current.startOfDay(for: Date())

    private let dayCount: Int = 7
    private let hourWidth: CGFloat = 5   // pt per hour → 120pt per day, 840pt total
    private let rowHeight: CGFloat = 28
    private let labelColumnWidth: CGFloat = 160

    private var totalWidth: CGFloat { CGFloat(dayCount * 24) * hourWidth }
    private var windowEnd: Date {
        Calendar.current.date(byAdding: .day, value: dayCount, to: anchor) ?? anchor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            calendarBody
            Divider()
            legend
        }
        .padding(12)
        .frame(width: labelColumnWidth + totalWidth + 24)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.policyGroup(for: policyID)?.policy.summary ?? "Schedule")
                    .font(.system(size: 12, weight: .semibold))
                Text(daysRangeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                anchor = Calendar.current.date(byAdding: .day, value: -dayCount, to: anchor) ?? anchor
            } label: { Image(systemName: "chevron.left").font(.system(size: 10)) }
                .buttonStyle(.borderless)
                .help("Previous \(dayCount) days")
            Button {
                anchor = Calendar.current.startOfDay(for: Date())
            } label: { Text("Today").font(.system(size: 11)) }
                .buttonStyle(.borderless)
            Button {
                anchor = Calendar.current.date(byAdding: .day, value: dayCount, to: anchor) ?? anchor
            } label: { Image(systemName: "chevron.right").font(.system(size: 10)) }
                .buttonStyle(.borderless)
                .help("Next \(dayCount) days")
        }
    }

    private var daysRangeLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: dayCount - 1, to: anchor) ?? anchor
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        return "\(f.string(from: anchor)) – \(f.string(from: end))"
    }

    // MARK: - Body

    @ViewBuilder
    private var calendarBody: some View {
        let entries = store.calendarEntries(for: policyID)
        let levels = Self.levels(from: entries)

        if levels.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text("No on-calls in the next \(dayCount) days.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: dayHeaderHeight)
                    ForEach(levels) { lvl in
                        HStack(spacing: 4) {
                            RoleBadge(level: lvl.level, compact: true)
                            Text(lvl.scheduleSummary ?? "Direct")
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 4)
                        .frame(height: rowHeight, alignment: .leading)
                    }
                }
                .frame(width: labelColumnWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    dayHeader
                    ForEach(levels) { lvl in
                        TimelineRow(
                            level: lvl,
                            anchor: anchor,
                            dayCount: dayCount,
                            hourWidth: hourWidth,
                            rowHeight: rowHeight,
                            meID: store.me?.id,
                            onOpen: { url in openURL(url) }
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.03))
                )
            }
        }
    }

    private let dayHeaderHeight: CGFloat = 32

    private var dayHeader: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for i in 0...dayCount {
                    let x = CGFloat(i * 24) * hourWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: dayHeaderHeight))
                }
            }
            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)

            HStack(spacing: 0) {
                ForEach(0..<dayCount, id: \.self) { i in
                    let day = Calendar.current.date(byAdding: .day, value: i, to: anchor) ?? anchor
                    let isToday = Calendar.current.isDateInToday(day)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.dowFormatter.string(from: day))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isToday ? Color.accentColor : .secondary)
                        Text(Self.dayFormatter.string(from: day))
                            .font(.system(size: 10, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.accentColor : .primary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 3)
                    .frame(width: 24 * hourWidth, alignment: .leading)
                }
            }
        }
        .frame(width: totalWidth, height: dayHeaderHeight)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([1, 2, 3], id: \.self) { lvl in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.colorFor(level: lvl).opacity(0.5))
                        .frame(width: 12, height: 8)
                    Text(roleName(for: lvl))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 3) {
                Rectangle().fill(Color.accentColor).frame(width: 1, height: 10)
                Text("now").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text("Click a bar to open in PagerDuty")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func roleName(for level: Int) -> String {
        switch level {
        case 1: return "Primary"
        case 2: return "Secondary"
        case 3: return "Tertiary"
        default: return "Level \(level)"
        }
    }

    static func colorFor(level: Int) -> Color {
        switch level {
        case 1: return .orange
        case 2: return .blue
        case 3: return .purple
        default: return .gray
        }
    }

    private static let dowFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    // MARK: - Level grouping

    struct LevelRow: Identifiable {
        let level: Int
        let scheduleID: String?
        let scheduleSummary: String?
        let entries: [PDOnCall]
        var id: String { "\(level)-\(scheduleID ?? "direct")" }
    }

    private static func levels(from entries: [PDOnCall]) -> [LevelRow] {
        var byKey: [String: [PDOnCall]] = [:]
        var meta: [String: (Int, String?, String?)] = [:]
        for e in entries {
            let sid = e.schedule?.id
            let key = "\(e.escalation_level)-\(sid ?? "direct")"
            byKey[key, default: []].append(e)
            if meta[key] == nil {
                meta[key] = (e.escalation_level, sid, e.schedule?.summary)
            }
        }
        return byKey.keys.compactMap { k -> LevelRow? in
            guard let (lvl, sid, sum) = meta[k] else { return nil }
            let rows = (byKey[k] ?? []).sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
            return LevelRow(level: lvl, scheduleID: sid, scheduleSummary: sum, entries: rows)
        }
        .sorted { ($0.level, $0.scheduleSummary ?? "") < ($1.level, $1.scheduleSummary ?? "") }
    }
}

// MARK: - Timeline row

private struct TimelineRow: View {
    let level: CalendarPopoverView.LevelRow
    let anchor: Date
    let dayCount: Int
    let hourWidth: CGFloat
    let rowHeight: CGFloat
    let meID: String?
    let onOpen: (URL) -> Void

    private var windowEnd: Date {
        Calendar.current.date(byAdding: .day, value: dayCount, to: anchor) ?? anchor
    }

    private var totalWidth: CGFloat { CGFloat(dayCount * 24) * hourWidth }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for i in 0...dayCount {
                    let x = CGFloat(i * 24) * hourWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: rowHeight))
                }
            }
            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)

            if Date() >= anchor && Date() <= windowEnd {
                let nowX = xFor(date: Date())
                Path { path in
                    path.move(to: CGPoint(x: nowX, y: 0))
                    path.addLine(to: CGPoint(x: nowX, y: rowHeight))
                }
                .stroke(Color.accentColor, lineWidth: 1)
            }

            ForEach(Array(visibleEntries.enumerated()), id: \.offset) { _, e in
                let start = max(e.start ?? anchor, anchor)
                let end = min(e.end ?? windowEnd, windowEnd)
                let x = xFor(date: start)
                let w = max(2, xFor(date: end) - x)
                ShiftBar(
                    user: e.user,
                    level: e.escalation_level,
                    isMe: e.user.id == meID,
                    start: e.start,
                    end: e.end
                )
                .frame(width: w, height: rowHeight - 6)
                .offset(x: x, y: 3)
                .onTapGesture {
                    if let s = e.user.html_url, let u = URL(string: s) { onOpen(u) }
                }
            }
        }
        .frame(width: totalWidth, height: rowHeight)
    }

    private var visibleEntries: [PDOnCall] {
        level.entries.filter { e in
            let s = e.start ?? anchor
            let f = e.end ?? windowEnd
            return f > anchor && s < windowEnd
        }
    }

    private func xFor(date: Date) -> CGFloat {
        let seconds = max(0, date.timeIntervalSince(anchor))
        let hours = seconds / 3600
        return CGFloat(hours) * hourWidth
    }
}

private struct ShiftBar: View {
    let user: PDReference
    let level: Int
    let isMe: Bool
    let start: Date?
    let end: Date?

    var body: some View {
        let tint = CalendarPopoverView.colorFor(level: level)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(isMe ? 0.5 : 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(tint.opacity(0.6), lineWidth: isMe ? 1.2 : 0.5)
                )
            Text(user.summary ?? "—")
                .font(.system(size: 10, weight: isMe ? .bold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
        }
        .help(tooltipText)
    }

    private var tooltipText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let s = start.map { f.string(from: $0) } ?? "—"
        let e = end.map { f.string(from: $0) } ?? "—"
        return "\(user.summary ?? "—") · \(s) → \(e)"
    }
}
