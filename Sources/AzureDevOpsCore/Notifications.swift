import BriefBarCore
import Foundation

/// A notification to post.
public struct PulseNotification: Sendable, Equatable, Identifiable {
    /// Stable, so the same news is never posted twice.
    public var id: String
    /// What it means for you, such as a build that failed, for its symbol on the Notifications page. Nil for one in no
    /// state, such as the one that says how many more updates there are.
    public var state: ItemState?
    public var title: String
    public var subtitle: String?
    public var body: String
    /// What clicking it opens; nil shows the panel.
    public var url: URL?
    /// The pull request it's about, which clicking it marks as seen.
    public var key: PRKey?
    public var at: Date

    public init(
        id: String, state: ItemState? = nil, title: String, subtitle: String? = nil, body: String, url: URL?, key: PRKey? = nil,
        at: Date
    ) {
        self.id = id
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.url = url
        self.key = key
        self.at = at
    }
}

/// What to post for a refresh's news: at most a few notes, so a busy refresh doesn't bury you, the last of them saying
/// how many more updates there are, and the updates it counts, which the Notifications page lists instead of it.
public struct NotificationPlan: Sendable, Equatable {
    /// The newest news, each in a notification of its own, the newest first.
    public var shown: [PulseNotification]
    /// After them, one that says how many more updates there are: those in `summarized`. Nil when every update shows.
    public var summary: PulseNotification?
    /// What `summary` counts, the newest first: news that isn't posted itself.
    public var summarized: [PulseNotification]

    /// Everything to post, in order.
    public var posted: [PulseNotification] {
        shown + (summary.map { [$0] } ?? [])
    }
}

/// Decides what's worth a notification by comparing two consecutive lists: new events (replies,
/// mentions, review requests, votes...), and your pull requests failing, becoming ready or completing.
/// What you've seen isn't news, even while it still waits on you.
public enum NotificationPlanner {
    /// `notBefore`: events from before then (usually when BriefBar started) are in the panel, not announced.
    public static func plan(previous: [PRSnapshot], current: [PRSnapshot], notBefore: Date, limit: Int = 4) -> [PulseNotification] {
        plan(previous: previous, current: current, notBefore: { _ in notBefore }, limit: limit)
    }

    /// With a time per pull request, such as when its organization was first read.
    public static func plan(
        previous: [PRSnapshot], current: [PRSnapshot], notBefore: (PRSnapshot) -> Date, limit: Int = 4
    ) -> [PulseNotification] {
        collapse(news(previous: previous, current: current, notBefore: notBefore), limit: limit).posted
    }

    /// At most `limit` notes, the newest first: with more news than that, the newest `limit - 1`, then one that says how
    /// many more updates there are. A limit under 2 posts everything.
    public static func collapse(_ notes: [PulseNotification], limit: Int = 4) -> NotificationPlan {
        let notes = notes.sorted { $0.at > $1.at }
        guard notes.count > limit, limit > 1 else { return NotificationPlan(shown: notes, summary: nil, summarized: []) }
        let shown = Array(notes.prefix(limit - 1))
        let rest = Array(notes.dropFirst(shown.count))
        let summary = PulseNotification(
            id: "more:" + rest.map(\.id).joined(separator: ","),
            title: "BriefBar", body: "\(rest.count) more pull request updates", url: nil, at: shown[shown.count - 1].at
        )
        return NotificationPlan(shown: shown, summary: summary, summarized: rest)
    }

    /// Every piece of news worth a notification, the newest first.
    public static func news(
        previous: [PRSnapshot], current: [PRSnapshot], notBefore: (PRSnapshot) -> Date
    ) -> [PulseNotification] {
        let before = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var notes: [PulseNotification] = []
        for snapshot in current {
            let notBefore = notBefore(snapshot)
            let old = before[snapshot.key]
            let known = Set(old?.events.map(\.id) ?? [])
            let changedGroup = old.map { $0.hasDetails && $0.group != snapshot.group } ?? false
            let becameReady = changedGroup && snapshot.role == .author && snapshot.group == .ready

            for event in snapshot.events where event.isNew && !known.contains(event.id) && event.at >= notBefore {
                // "Ready to complete" names who approved.
                if event.kind == .approved && becameReady { continue }
                // The chat app already announced the message.
                if event.kind == .sentInChat { continue }
                notes.append(note(for: event, in: snapshot))
            }
            if let note = mergeNote(snapshot, before: old?.merge, notBefore: notBefore) {
                notes.append(note)
            }

            guard changedGroup, snapshot.role == .author, snapshot.hasDetails || snapshot.group == .done else { continue }
            let at = max(snapshot.since ?? notBefore, notBefore)
            // When it happened is part of the ID: a build that fails again, or a pull request that's ready again
            // after a push, is news again; a pull request moving back from Needs You in the same state isn't.
            let occurrence = snapshot.since.map { String(Int($0.timeIntervalSince1970)) } ?? ""
            switch snapshot.group {
            case .failing where snapshot.reason != .buildExpired && snapshot.reason != .failedAfterMerge:
                notes.append(PulseNotification(
                    id: "\(snapshot.id):failing:\(snapshot.reason.rawValue):\(occurrence)", state: .failing,
                    title: snapshot.headline, subtitle: snapshot.title, body: snapshot.detail ?? snapshot.repository,
                    url: snapshot.url, key: snapshot.key, at: at
                ))
            case .ready:
                notes.append(PulseNotification(
                    id: "\(snapshot.id):ready:\(occurrence)", state: .done, title: snapshot.headline, subtitle: snapshot.title,
                    body: snapshot.detail ?? "Every required check passes.", url: snapshot.url, key: snapshot.key, at: at
                ))
            case .done where snapshot.reason == .completed:
                notes.append(PulseNotification(
                    id: "\(snapshot.id):completed", state: .done, title: "Completed", subtitle: snapshot.title,
                    body: snapshot.detail ?? snapshot.repository, url: snapshot.url, key: snapshot.key, at: at
                ))
            default:
                break
            }
        }
        return notes.sorted { $0.at > $1.at }
    }

    /// What the pipelines after a merge did since the last list: one failed, one waits for an approval, or they all
    /// passed once they'd been running. Each failed or waiting run is announced once, and what happened before
    /// `notBefore` isn't.
    static func mergeNote(_ snapshot: PRSnapshot, before old: MergeSummary?, notBefore: Date) -> PulseNotification? {
        guard snapshot.role == .author, let merge = snapshot.merge, let at = merge.since, at >= notBefore else { return nil }
        let pipeline = merge.pipeline.map { "“\($0)”" } ?? "A pipeline"
        switch merge.outcome {
        case .failed where !(old?.outcome == .failed && old?.runId == merge.runId):
            return PulseNotification(
                id: "\(snapshot.id):merge:failed:\(merge.runId ?? 0)", state: .failing, title: "Failed after merge",
                subtitle: snapshot.title, body: merge.failure.map { "\(pipeline): \($0.summary)" } ?? "\(pipeline) failed.",
                url: snapshot.url, key: snapshot.key, at: at
            )
        case .waiting where !(old?.outcome == .waiting && old?.runId == merge.runId && old?.stage == merge.stage):
            return PulseNotification(
                id: "\(snapshot.id):merge:waiting:\(merge.runId ?? 0):\(merge.stage ?? "")", state: .needsYou,
                title: "Waiting for approval", subtitle: snapshot.title,
                body: "\(pipeline) waits for approval" + (merge.stage.map { " to \($0)." } ?? "."),
                url: snapshot.url, key: snapshot.key, at: at
            )
        case .passed where old?.outcome == .running || old?.outcome == .waiting:
            return PulseNotification(
                id: "\(snapshot.id):merge:passed", state: .done, title: merge.total == 1 ? "Pipeline passed" : "Pipelines passed",
                subtitle: snapshot.title,
                body: merge.total == 1 ? "Its pipeline passed after it merged." : "All \(merge.total) pipelines passed after it merged.",
                url: snapshot.url, key: snapshot.key, at: at
            )
        default:
            return nil
        }
    }

    static func note(for event: PREvent, in snapshot: PRSnapshot) -> PulseNotification {
        let actor = event.actor ?? "Someone"
        let title: String
        var body = event.text
        var state = ItemState.needsYou
        switch event.kind {
        case .mention: title = "\(actor) mentioned you"
        case .sentInChat:
            title = "\(actor) sent you a pull request"
            body = event.app.map { "In \($0)." }
        case .reply: title = "\(actor) replied"
        case .comment: title = "\(actor) commented"
        case .reviewRequest:
            title = "Review requested"
            body = "\(snapshot.author) asked you to review" + (event.text.map { " (\($0.lowercased()))" } ?? "") + "."
        case .newCommits:
            title = "New commits"
            body = (event.count.map { $0 == 1 ? "1 new commit" : "\($0) new commits" } ?? "New commits") + " since your vote."
        case .changesRequested:
            title = "\(actor) is waiting for you"
            body = "They voted \"Waiting for author\"."
        case .rejected:
            title = "\(actor) rejected it"
            body = "They voted \"Rejected\"."
        case .approved:
            title = "\(actor) approved"
            body = snapshot.detail
            state = .done
        }
        // Its own thread: the pull request's link goes to the comment that needs you most, which may be another one.
        return PulseNotification(
            id: "\(snapshot.id):\(event.id)", state: state, title: title, subtitle: snapshot.title,
            body: body ?? snapshot.repository, url: snapshot.pageURL(thread: event.threadId), key: snapshot.key, at: event.at
        )
    }
}
