import BriefBarCore
import Foundation

/// What the sources know of the things another source names, for that source's tools to tell with their own, as Show
/// Links joins them: the Copilot sessions on a work item's pull requests, for `work_item`. Each source tells only of its
/// own things, and only while it's on, so the sources stay apart: Azure DevOps never reads Copilot's files, nor Copilot
/// Azure DevOps.
package enum MCPRelated {
    /// What a tool asks about: the things it names, such as a work item and its pull requests, and what links each pull
    /// request to a session by its branch (`BranchLinks`).
    package struct Query: Sendable, Equatable {
        package var items: [ItemRef]
        package var branches: [ItemRef: BranchHint]
        /// How many to tell in full, the most telling first: the rest come with their title and status only.
        package var limit: Int

        package init(items: [ItemRef], branches: [ItemRef: BranchHint] = [:], limit: Int = 5) {
            self.items = items
            self.branches = branches
            self.limit = limit
        }
    }

    /// One of a source's things that goes with what was asked about, told in a few lines.
    package struct Item: Sendable, Equatable {
        package var ref: ItemRef
        /// Its name, such as a session's: "Save items for later".
        package var title: String
        /// Where it stands, and since when: "finished 2h ago", "waiting for your answer since 4m ago".
        package var status: String
        /// What it means for you, as the lists by state count it: a session that waits for your answer needs you.
        package var state: ItemState?
        /// When it got where it stands.
        package var date: Date?
        /// Its link, such as a session's `ghapp://sessions/` link.
        package var url: URL?
        /// The things asked about that it goes with, and why.
        package var links: [Link]
        /// What more it says, a line each without a list's marker, such as "Did: …" and "Next: …".
        package var lines: [String]
        /// Who it waits on, as its source says it, when that's more than its state says: a session whose question its
        /// coordinator relays waits on you, in that session.
        package var waits: [ItemStory.Wait]

        package init(
            ref: ItemRef, title: String, status: String, state: ItemState? = nil, date: Date? = nil, url: URL? = nil,
            links: [Link] = [], lines: [String] = [], waits: [ItemStory.Wait] = []
        ) {
            self.ref = ref
            self.title = title
            self.status = status
            self.state = state
            self.date = date
            self.url = url
            self.links = links
            self.lines = lines
            self.waits = waits
        }
    }

    /// One of the things asked about, and why an item goes with it: "on !4120's branch", "opened !4091".
    package struct Link: Sendable, Equatable {
        package var item: ItemRef
        package var reason: String

        package init(item: ItemRef, reason: String) {
            self.item = item
            self.reason = reason
        }
    }

    /// How a source tells what it knows of the things asked about.
    package struct Teller: Sendable {
        /// What it tells of, as a heading: "Copilot sessions".
        package var title: String
        /// Its things that go with what was asked about, the most telling first. What it throws says why it can't tell,
        /// such as being off in BriefBar.
        package var tell: @Sendable (Query) async throws -> [Item]
        /// The sessions it lists now, and since when each idle one has been, as its own list has them: what sessions told
        /// BriefBar counts only while they're listed, as Show Links shows it (`SessionReports.links`). Nil for a source
        /// with no sessions.
        package var sessions: (@Sendable () async throws -> SessionReports.Listing)?
        /// Its sessions, as pull requests' stages and missions need them, as it tells Pull Request Order in the app; nil
        /// for a source with no sessions.
        package var stageSessions: (@Sendable () async throws -> StageSessions)?

        package init(
            title: String, tell: @escaping @Sendable (Query) async throws -> [Item],
            sessions: (@Sendable () async throws -> SessionReports.Listing)? = nil,
            stageSessions: (@Sendable () async throws -> StageSessions)? = nil
        ) {
            self.title = title
            self.tell = tell
            self.sessions = sessions
            self.stageSessions = stageSessions
        }
    }

    /// A source's sessions, as pull requests' stages and missions need them, as the Copilot app's source tells Pull Request
    /// Order (`CopilotSource.publishOrder`): the sessions it lists, each with what it does now, or how it ended, since
    /// when, and its name; the pull requests each opened or works on, as the app records them; and those each told
    /// BriefBar it works on.
    package struct StageSessions: Sendable, Equatable {
        package struct Session: Sendable, Equatable {
            package var activity: StageSession.Activity
            /// When it started what it does now, or when it ended.
            package var since: Date?
            package var name: String

            package init(activity: StageSession.Activity, since: Date?, name: String) {
                self.activity = activity
                self.since = since
                self.name = name
            }
        }

        /// The pull requests each session opened, with the sessions that started and coordinate it (`OrderSessions`).
        package var sessions: [OrderSession]
        /// What each session told BriefBar it works on now, with Updates from Copilot Sessions on.
        package var working: [ItemRef: [ItemRef]]
        /// The sessions it lists now: only what these set counts (`SessionStages`).
        package var listed: [ItemRef: Session]

        package init(sessions: [OrderSession] = [], working: [ItemRef: [ItemRef]] = [:], listed: [ItemRef: Session] = [:]) {
            self.sessions = sessions
            self.working = working
            self.listed = listed
        }

        /// The listed sessions on each pull request, those that opened it or work on it, and those that told BriefBar they
        /// work on it, each with what it does now, or how it ended, and since when, as Pull Request Order has them.
        package var onPullRequests: [ItemRef: [StageSession]] {
            var on: [ItemRef: Set<ItemRef>] = [:]
            for session in sessions {
                for ref in session.pullRequests { on[ref, default: []].insert(session.ref) }
            }
            for (session, refs) in working {
                for ref in refs { on[ref, default: []].insert(session) }
            }
            return on.mapValues { sessions in
                sessions.sorted().compactMap { session in
                    listed[session].map { StageSession(ref: session, activity: $0.activity, since: $0.since) }
                }
            }
        }

        /// Both, the first's wherever both have a session.
        func merging(_ other: StageSessions) -> StageSessions {
            StageSessions(
                sessions: sessions + other.sessions.filter { session in !sessions.contains { $0.ref == session.ref } },
                working: working.merging(other.working) { first, _ in first },
                listed: listed.merging(other.listed) { first, _ in first }
            )
        }
    }

    /// What one source told, under its title, or why it couldn't.
    package struct Part: Sendable, Equatable {
        package var title: String
        package var items: [Item]
        package var problem: String?

        package init(title: String, items: [Item] = [], problem: String? = nil) {
            self.title = title
            self.items = items
            self.problem = problem
        }
    }

    /// The sources' tellers while one of their tools runs (`MCPSource.tools`); none for a tool that runs on its own.
    @TaskLocal package static var tellers: [Teller] = []

    /// What each of the sources whose tool runs tells of a query.
    package static func ask(_ query: Query) async -> [Part] {
        await ask(tellers, query)
    }

    /// The sessions the sources whose tool runs list now (`Teller.sessions`), for what sessions told BriefBar: nil when
    /// none of them lists sessions or can say now, as when it's off in BriefBar.
    package static func sessionListing() async -> SessionReports.Listing? {
        await sessionListing(tellers)
    }

    /// The sessions the sources whose tool runs list, as pull requests' stages need them (`Teller.stageSessions`): nil when
    /// none of them lists sessions or can say now, as when it's off in BriefBar.
    package static func stageSessions() async -> StageSessions? {
        var all: StageSessions?
        for teller in tellers {
            guard let sessions = teller.stageSessions, let told = try? await sessions() else { continue }
            all = all.map { $0.merging(told) } ?? told
        }
        return all
    }

    /// The sessions these sources list now, together.
    package static func sessionListing(_ tellers: [Teller]) async -> SessionReports.Listing? {
        var listing: SessionReports.Listing?
        for teller in tellers {
            guard let sessions = teller.sessions, let listed = try? await sessions() else { continue }
            var all = listing ?? SessionReports.Listing()
            all.sessions.formUnion(listed.sessions)
            all.idleSince.merge(listed.idleSince) { first, _ in first }
            listing = all
        }
        return listing
    }

    /// What each source tells of a query, asked at the same time, in the sources' order.
    package static func ask(_ tellers: [Teller], _ query: Query) async -> [Part] {
        guard !tellers.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Part).self) { group in
            for (index, teller) in tellers.enumerated() {
                group.addTask {
                    do {
                        return (index, Part(title: teller.title, items: try await teller.tell(query)))
                    } catch {
                        return (index, Part(title: teller.title, problem: String(describing: error)))
                    }
                }
            }
            var parts: [Int: Part] = [:]
            for await (index, part) in group { parts[index] = part }
            return tellers.indices.compactMap { parts[$0] }
        }
    }
}
