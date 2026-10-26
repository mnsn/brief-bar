import BriefBarCore
import Foundation
import Testing
@testable import CopilotCore

@Suite struct SessionLinksTests {
    private static let created = "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01"
    private static let started = "5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02"
    private static let provided = "9a4f2b17-c3d8-4e61-b5a0-2e8d7c6b4a03"

    /// The app's newer columns and table: a project's GitHub repository and folder, the pull requests a workspace started
    /// from or opened, and the pull requests its providers link it to.
    private static let linkColumns = """
        ALTER TABLE projects ADD COLUMN github_owner TEXT;
        ALTER TABLE projects ADD COLUMN github_repo TEXT;
        ALTER TABLE projects ADD COLUMN main_repo_path TEXT;
        ALTER TABLE workspaces ADD COLUMN source_pr_repo_full_name TEXT;
        ALTER TABLE workspaces ADD COLUMN source_pr_number INTEGER;
        ALTER TABLE workspaces ADD COLUMN source_pr_html_url TEXT;
        ALTER TABLE workspaces ADD COLUMN created_pr_repo_full_name TEXT;
        ALTER TABLE workspaces ADD COLUMN created_pr_number INTEGER;
        ALTER TABLE workspaces ADD COLUMN created_pr_html_url TEXT;
        CREATE TABLE workspace_pull_request_links (workspace_id TEXT PRIMARY KEY NOT NULL, uri TEXT NOT NULL);
        """

    private func sessions(_ db: TestDatabase) throws {
        try db.addProject("p1", name: "shop")
        try db.addProject("p2", name: "Storefront")
        try db.addSession(Self.created, title: "Fix the tax rounding")
        try db.addWorkspace("w1", session: Self.created, project: "p1", name: "Fix the tax rounding", branch: "fix-tax-rounding")
        try db.addSession(Self.started, title: "Review the cache")
        try db.addWorkspace("w2", session: Self.started, project: "p2", name: "Review the cache", branch: "search-cache")
        try db.addSession(Self.provided, title: "Speed up checkout")
        try db.addWorkspace("w3", session: Self.provided, project: "p2", name: "Speed up checkout", branch: "checkout-speed")
    }

    @Test func readsWhereEachSessionsWorkGoesOnlyWhenAsked() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.createAppSchema()
            try db.exec(Self.linkColumns)
            try sessions(db)
            try db.exec("""
                UPDATE projects SET github_owner = 'octo', github_repo = 'shop-web', main_repo_path = '/Users/robin/src/shop-web'
                WHERE id = 'p1';
                UPDATE workspaces SET created_pr_repo_full_name = 'octo/shop-web', created_pr_number = 12,
                                      created_pr_html_url = 'https://github.com/octo/shop-web/pull/12' WHERE id = 'w1';
                UPDATE workspaces SET source_pr_number = 4071,
                                      source_pr_html_url = 'https://dev.azure.com/contoso/Storefront/_git/search/pullrequest/4071'
                WHERE id = 'w2';
                INSERT INTO workspace_pull_request_links (workspace_id, uri) VALUES
                    ('w3', 'https://dev.azure.com/contoso/Storefront/_git/shop/pullrequest/4072'),
                    ('w1', 'provider://not-a-pull-request');
                """)

            #expect(try AppDatabase.load(at: url).sessions.allSatisfy { $0.links == nil })

            let sessions = Dictionary(uniqueKeysWithValues: try AppDatabase.load(at: url, links: true).sessions.map { ($0.id, $0) })
            #expect(sessions[Self.created]?.links == SessionLinks(
                gitHubRepository: "octo/shop-web", folder: "shop-web",
                pullRequests: [RecordedPullRequest(repository: "octo/shop-web", number: 12, url: "https://github.com/octo/shop-web/pull/12")]
            ))
            #expect(sessions[Self.created]?.links?.pullRequests.compactMap(\.ref) == [.gitHubPullRequest(repository: "octo/shop-web", number: 12)])
            #expect(sessions[Self.started]?.links?.pullRequests.compactMap(\.ref) == [.pullRequest(organization: "contoso", number: 4071)])
            #expect(sessions[Self.started]?.links?.gitHubRepository == nil)
            #expect(sessions[Self.provided]?.links?.pullRequests.compactMap(\.ref) == [.pullRequest(organization: "contoso", number: 4072)])

            // What a session's snapshot shows comes with it.
            let record = SessionRecord(meta: try #require(sessions[Self.created]), log: nil)
            #expect(StatusResolver.snapshot(for: record, now: t(60)).links == sessions[Self.created]?.links)
        }
    }

    @Test func anAppWithoutTheseColumnsStillListsItsSessions() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.createAppSchema()
            try sessions(db)
            let snapshot = try AppDatabase.load(at: url, links: true)
            #expect(snapshot.sessions.count == 3)
            #expect(snapshot.sessions.allSatisfy { $0.links == nil })
            #expect(snapshot.sessions.first { $0.id == Self.started }?.branch == "search-cache")
        }
    }

    @Test func aRecordedPullRequestIsOnlyAWholeOne() {
        #expect(RecordedPullRequest(repository: "octo/shop-web", number: 12, url: nil).ref == .gitHubPullRequest(repository: "octo/shop-web", number: 12))
        #expect(RecordedPullRequest(repository: "octo/shop-web", number: nil, url: nil).ref == nil)
        #expect(RecordedPullRequest(repository: "../..", number: 3, url: nil).ref == nil)
        #expect(RecordedPullRequest(repository: nil, number: nil, url: "https://dev.azure.com/c/p/_workitems/edit/5").ref == nil)
        // Its link wins over the rest.
        #expect(RecordedPullRequest(repository: "octo/other", number: 1, url: "https://github.com/octo/shop-web/pull/12").ref
            == .gitHubPullRequest(repository: "octo/shop-web", number: 12))
    }
}
