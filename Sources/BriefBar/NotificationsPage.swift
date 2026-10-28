import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Notifications page: what BriefBar notified you of lately, from every source, the newest first, by day. Each opens
/// what it's about, as its notification does, and a dot marks what you haven't seen yet.
struct NotificationsPage: View {
    static let symbol = "bell.fill"

    @ObservedObject var recent: RecentNotifications
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Notifications", subtitle: subtitle) {
                Button {
                    recent.clear()
                } label: {
                    Label("Clear All", systemImage: "xmark.circle")
                }
                .glassButtonStyle()
                .disabled(recent.history.isEmpty)
                .help("Take every notification off this page, which then hides until a new one comes")
            }
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    if recent.history.isEmpty {
                        Text("Nothing to show")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(days) { day in
                        section(day)
                    }
                    footnote
                }
            }
        }
    }

    /// "5 in the last day · 2 new".
    private var subtitle: String {
        let history = recent.history
        let unseen = history.unseenCount
        let listed = "\(history.entries.count) in \(Self.period(recent.keepHours))"
        return unseen == 0 ? listed : "\(listed) · \(unseen) new"
    }

    private struct Day: Identifiable {
        var start: Date
        var entries: [NotificationHistory.Entry]
        var id: Date { start }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for entry in recent.history.entries {
            let start = calendar.startOfDay(for: entry.date)
            if days.last?.start == start {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(Day(start: start, entries: [entry]))
            }
        }
        return days
    }

    private func title(of day: Day) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day.start, inSameDayAs: recent.now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: recent.now), calendar.isDate(day.start, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.start.formatted(.dateTime.weekday(.wide).month().day())
    }

    private func section(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title(of: day))
                    .foregroundStyle(.primary)
                Text("\(day.entries.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, 46).padding(.trailing, 12)
                    }
                    NotificationRow(entry: entry, now: recent.now, source: model.source(entry.source)) {
                        model.open(entry)
                    } remove: {
                        recent.remove(entry.id)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
            .background(GlassCard(cornerRadius: 18))
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Text("BriefBar keeps them for \(Self.duration(recent.keepHours)), in memory only: this page starts empty when it restarts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Change…") { model.openSettings(.general) }
                .buttonStyle(.borderless)
                .help("Choose how long, in Settings › General")
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 4)
    }

    /// What Settings offers, for the setting: "4 Hours", "1 Day", "3 Days".
    static var keepChoices: [(hours: Int, title: String)] {
        NotificationHistory.keepHoursChoices.map { hours in
            (hours, hours % 24 == 0 ? (hours == 24 ? "1 Day" : "\(hours / 24) Days") : "\(hours) Hours")
        }
    }

    /// "4 hours", "a day", "3 days".
    static func duration(_ hours: Int) -> String {
        hours % 24 == 0 ? (hours == 24 ? "a day" : "\(hours / 24) days") : "\(hours) hours"
    }

    /// "the last 4 hours", "the last day", "the last 3 days".
    static func period(_ hours: Int) -> String {
        hours == 24 ? "the last day" : "the last \(duration(hours))"
    }
}

/// One notification on the page: what it means for you, its title and message, and how long ago it came. A click opens
/// what it's about.
private struct NotificationRow: View {
    let entry: NotificationHistory.Entry
    let now: Date
    /// Where it came from, for its symbol when it's in no state, and its name.
    let source: (any BriefBarSource)?
    let open: () -> Void
    let remove: () -> Void

    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.state?.symbol ?? source?.symbol ?? NotificationsPage.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(options.quietAppearance ? Color.secondary : entry.state?.color ?? .secondary)
                    .frame(width: 22)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Elapsed.short(since: entry.date, now: now))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !entry.isSeen {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                    }
                    if let subtitle = entry.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    if !entry.body.isEmpty {
                        Text(entry.body)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button("Remove from This Page", action: remove)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(([entry.isSeen ? nil : "New"] + [entry.subtitle, entry.body, Elapsed.short(since: entry.date, now: now)])
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Opens what it's about")
    }

    private var help: String {
        let time = entry.date.formatted(date: .abbreviated, time: .shortened)
        return [source?.name, time].compactMap { $0 }.joined(separator: " · ") + ". Click to open what it's about."
    }
}
