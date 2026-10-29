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

        package init(title: String, tell: @escaping @Sendable (Query) async throws -> [Item]) {
            self.title = title
            self.tell = tell
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
