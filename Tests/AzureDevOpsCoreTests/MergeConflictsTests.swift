import Foundation
import Testing
@testable import AzureDevOpsCore

/// A pull request's merge conflicts: what Azure DevOps lists, read with GETs a page at a time, and how each file conflicts,
/// in plain words. From made-up answers, never Azure DevOps.
@Suite struct MergeConflictsTests {
    private let pullRequest = makePR(7, merge: "conflicts")

    /// A conflict as Azure DevOps lists it.
    private static func conflict(
        _ id: Int?, _ path: String?, _ type: Any?, status: Any? = "unresolved", extra: [String: Any] = [:]
    ) -> [String: Any] {
        var json: [String: Any] = ["url": "https://example.invalid", "_links": [:]]
        if let id { json["conflictId"] = id }
        if let path { json["conflictPath"] = path }
        if let type { json["conflictType"] = type }
        if let status { json["resolutionStatus"] = status }
        for (key, value) in extra { json[key] = value }
        json["mergeSourceCommit"] = ["commitId": "abc"]
        json["mergeTargetCommit"] = ["commitId": "def"]
        return json
    }

    // MARK: What Azure DevOps lists

    @Test func readsEachTypeOfConflictAndTheOtherPathsARenameGives() throws {
        let list = try Fixture.decode(ADOList<ADOConflict>.self, Fixture.list([
            Self.conflict(1, "/src/Orders/OrderService.cs", "editEdit"),
            // By its number, as some servers send it: 7 is `editDelete`, and 2 is `resolved`.
            Self.conflict(2, "/src/Orders/LegacyOrderMapper.cs", 7, status: 2),
            Self.conflict(3, "/docs/order-states.md", "rename1to2", extra: [
                "sourceNewPath": "/docs/order-statuses.md", "targetNewPath": "/docs/orders/states.md",
            ]),
            Self.conflict(4, "/docs/statuses.md", "rename2to1", extra: [
                "sourceOriginalPath": "/docs/a.md", "targetOriginalPath": "/docs/b.md",
            ]),
            Self.conflict(5, "/docs/both.md", "renameRename", extra: ["originalPath": "/docs/old.md"]),
            // A type BriefBar doesn't know, and one of an unexpected type.
            Self.conflict(6, "/a.txt", "somethingNew"),
            Self.conflict(7, "/b.txt", ["unexpected": true]),
        ]))
        let files = list.value.enumerated().compactMap { MergeConflict($1, index: $0) }
        #expect(files.map(\.kind) == [.editEdit, .editDelete, .rename1to2, .rename2to1, .renameRename, .other, .other])
        #expect(files.map(\.isResolved) == [false, true, false, false, false, false, false])
        #expect(files[2].sourcePath == "/docs/order-statuses.md")
        #expect(files[2].targetPath == "/docs/orders/states.md")
        #expect(files[3].sourcePath == "/docs/a.md" && files[3].targetPath == "/docs/b.md")
        #expect(files[4].originalPath == "/docs/old.md")
        #expect(files[0].name == "OrderService.cs" && files[0].folder == "src/Orders")
        #expect(MergeConflict(id: 9, path: "/README.md", kind: .editEdit).folder == nil)
    }

    @Test func leavesOutAConflictWithoutAPathAndKeepsTheRest() throws {
        let list = try Fixture.decode(ADOList<ADOConflict>.self, [
            "count": 4,
            "value": [
                Self.conflict(1, nil, "editEdit"),
                Self.conflict(2, "", "editEdit"),
                "not a conflict",
                // Without a number, and a path without its slash, as from the top of the repository.
                Self.conflict(nil, "src/a.cs", "addAdd"),
            ],
        ])
        let files = list.value.enumerated().compactMap { MergeConflict($1, index: $0) }
        #expect(files.count == 1)
        #expect(files.first?.path == "/src/a.cs")
        #expect(files.first?.kind == .addAdd)
        // Its number in the list stands in for the one Azure DevOps didn't give.
        #expect(files.first.map { $0.id < 0 } == true)
    }

    /// In the order a change lists its files: folder by folder, each folder's folders before its files.
    @Test func listsTheFilesAsAChangeDoes() {
        let conflicts = MergeConflicts(files: [
            MergeConflict(id: 1, path: "/src/Orders/OrderStatus.cs", kind: .editEdit),
            MergeConflict(id: 2, path: "/README.md", kind: .editEdit),
            MergeConflict(id: 3, path: "/src/App.cs", kind: .editEdit),
            MergeConflict(id: 4, path: "/src/Orders/LegacyOrderMapper.cs", kind: .editDelete),
        ], of: pullRequest)
        #expect(conflicts.files.map(\.id) == [4, 1, 3, 2])
    }

    // MARK: How each conflicts

    @Test func saysWhatEachBranchDidToTheFile() {
        func how(_ kind: MergeConflict.Kind, source: String? = nil, target: String? = nil, original: String? = nil) -> String {
            MergeConflict(id: 1, path: "/src/Orders/OrderStatus.cs", kind: kind, sourcePath: source, targetPath: target, originalPath: original)
                .how(source: "rename-order-status", target: "main")
        }
        #expect(how(.editEdit) == "Changed on both branches")
        #expect(how(.addAdd) == "Added on both branches")
        #expect(how(.deleteEdit) == "Deleted on rename-order-status, changed on main")
        #expect(how(.editDelete) == "Changed on rename-order-status, deleted on main")
        // Another path in the same folder by its name, one elsewhere from the top of the repository.
        #expect(how(.renameDelete, source: "/src/Orders/Status.cs") == "Renamed to Status.cs on rename-order-status, deleted on main")
        #expect(how(.deleteRename, target: "/src/Status.cs") == "Deleted on rename-order-status, renamed to src/Status.cs on main")
        #expect(how(.rename1to2, source: "/src/Orders/Status.cs", target: "/src/Status.cs")
            == "Renamed to Status.cs on rename-order-status, and to src/Status.cs on main")
        #expect(how(.rename2to1, source: "/src/Orders/A.cs", target: "/src/Orders/B.cs")
            == "Both branches renamed a file to it: A.cs on rename-order-status, B.cs on main")
        #expect(how(.renameAdd, source: "/src/Orders/Old.cs") == "Renamed from Old.cs on rename-order-status, added on main")
        #expect(how(.addRename, target: "/src/Orders/Old.cs") == "Added on rename-order-status, renamed from Old.cs on main")
        #expect(how(.renameRename, original: "/src/Orders/Old.cs") == "Renamed from Old.cs on both branches, with different changes")
        #expect(how(.directoryFile) == "A folder on rename-order-status, a file on main")
        #expect(how(.fileDirectory) == "A file on rename-order-status, a folder on main")
        #expect(how(.directoryChild) == "In a folder that's a file on one branch")
        #expect(how(.other) == "Conflicts with main")
        // Without the other paths a rename gives, as Azure DevOps may leave them out.
        #expect(how(.renameDelete) == "Renamed on rename-order-status, deleted on main")
        #expect(how(.deleteRename) == "Deleted on rename-order-status, renamed on main")
        #expect(how(.rename1to2, source: "/src/Orders/Status.cs") == "Renamed differently on each branch")
        #expect(how(.rename2to1) == "Both branches renamed a file to it")
        #expect(how(.renameAdd) == "Renamed to it on rename-order-status, added on main")
        #expect(how(.addRename) == "Added on rename-order-status, renamed to it on main")
        #expect(how(.renameRename) == "Renamed to it on both branches, with different changes")
        // Without branch names.
        #expect(MergeConflict(id: 1, path: "/a.cs", kind: .editDelete).how(source: "", target: "")
            == "Changed on its branch, deleted on the target branch")
    }

    /// Where its page shows what the pull request changed in it: where the pull request renamed it to, or its path.
    @Test func showsTheFileWhereThePullRequestHasIt() {
        #expect(MergeConflict(id: 1, path: "/a.md", kind: .rename1to2, sourcePath: "/b.md", targetPath: "/c.md").pathInPullRequest == "/b.md")
        #expect(MergeConflict(id: 1, path: "/a.md", kind: .renameDelete, sourcePath: "/b.md").pathInPullRequest == "/b.md")
        #expect(MergeConflict(id: 1, path: "/a.md", kind: .renameDelete).pathInPullRequest == "/a.md")
        #expect(MergeConflict(id: 1, path: "/a.md", kind: .rename2to1, sourcePath: "/b.md").pathInPullRequest == "/a.md")
        #expect(MergeConflict(id: 1, path: "/a.md", kind: .editEdit).pathInPullRequest == "/a.md")
    }

    @Test func areCurrentUntilEitherBranchMoves() {
        let conflicts = MergeConflicts(files: [], of: pullRequest)
        #expect(conflicts.isCurrent(for: pullRequest))
        var pushed = pullRequest
        pushed.sourceCommit = "abd"
        #expect(!conflicts.isCurrent(for: pushed))
        var moved = pullRequest
        moved.targetCommit = "deg"
        #expect(!conflicts.isCurrent(for: moved))
        var retargeted = pullRequest
        retargeted.targetBranch = "release"
        #expect(!conflicts.isCurrent(for: retargeted))
    }

    // MARK: Reading them

    @Test func asksForThePullRequestsConflictsInItsRepository() throws {
        let url = ADOEndpoint.pullRequestConflicts(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7, top: 100, skip: 200)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "dev.azure.com")
        #expect(components.path == "/contoso/p1/_apis/git/repositories/r1/pullRequests/7/conflicts")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == ["$top": "100", "$skip": "200", "api-version": "7.1-preview.1"])
    }

    @Test func readsThemWithOneGetForAHundredOrFewer() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/conflicts", json: Fixture.list([
            Self.conflict(1, "/src/b.cs", "editEdit"), Self.conflict(2, "/src/a.cs", "addAdd"),
        ]))
        let read = try await MergeConflicts.read(pullRequest, with: server.client())
        #expect(read.files.map(\.path) == ["/src/a.cs", "/src/b.cs"])
        #expect(read.isComplete)
        #expect(read.isCurrent(for: pullRequest))
        #expect(server.requests.count == 1)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func readsPageAfterPageWhileTheyreFull() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/conflicts") { request in
            let skip = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "$skip" }?.value.flatMap(Int.init) ?? 0
            // Five in all, two a page.
            let ids = Array((skip + 1)...min(skip + 2, 5))
            return .json(Fixture.list(ids.map { Self.conflict($0, "/src/\($0).cs", "editEdit") }))
        }
        let read = try await MergeConflicts.read(pullRequest, with: server.client(), pageSize: 2)
        #expect(read.files.map(\.id).sorted() == [1, 2, 3, 4, 5])
        #expect(read.isComplete)
        #expect(server.requests.count == 3)

        // Past the most it reads, it says the rest are left out.
        let capped = try await MergeConflicts.read(pullRequest, with: server.client(), pageSize: 2, maxPages: 2)
        #expect(capped.files.count == 4)
        #expect(!capped.isComplete)
    }

    /// A server that answers with the same page whatever it's asked for, or with all of them at once, isn't asked forever;
    /// and once a full page brings nothing new, there may be more, which it won't give.
    @Test func stopsWhenAPageBringsNothingNew() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/conflicts", json: Fixture.list([Self.conflict(1, "/a.cs", "editEdit"), Self.conflict(2, "/b.cs", "editEdit")]))
        let read = try await MergeConflicts.read(pullRequest, with: server.client(), pageSize: 2)
        #expect(read.files.count == 2)
        #expect(!read.isComplete)
        #expect(server.requests.count == 2)

        // Told apart by their paths when Azure DevOps doesn't number them.
        let unnumbered = StubServer()
        unnumbered.on("/pullRequests/7/conflicts", json: Fixture.list([Self.conflict(nil, "/a.cs", "editEdit"), Self.conflict(nil, "/b.cs", "editEdit")]))
        let byPath = try await MergeConflicts.read(pullRequest, with: unnumbered.client(), pageSize: 2)
        #expect(byPath.files.map(\.path) == ["/a.cs", "/b.cs"])
        #expect(!byPath.isComplete)
        #expect(unnumbered.requests.count == 2)

        let all = StubServer()
        all.on("/pullRequests/7/conflicts", json: Fixture.list((1...3).map { Self.conflict($0, "/\($0).cs", "editEdit") }))
        let everything = try await MergeConflicts.read(pullRequest, with: all.client(), pageSize: 2)
        #expect(everything.files.count == 3)
        #expect(everything.isComplete)
        #expect(all.requests.count == 1)
    }

    @Test func saysWhyTheyCantBeRead() async {
        let server = StubServer()
        server.on("/pullRequests/7/conflicts") { _ in .status(404) }
        await #expect(throws: ADOError.notFound) { try await MergeConflicts.read(pullRequest, with: server.client()) }
    }

    // MARK: The demo

    @Test func theDemosPullRequestWithConflictsHasThem() throws {
        let records = DemoData.records(now: Date())
        let conflicting = try #require(records.first { $0.pullRequest.hasConflicts })
        let conflicts = DemoData.conflicts(of: conflicting.pullRequest)
        #expect(conflicts.files.count == 5)
        #expect(Set(conflicts.files.map(\.kind)) == [.editEdit, .editDelete, .addAdd, .rename1to2])
        #expect(conflicts.isCurrent(for: conflicting.pullRequest))
        // Others have none.
        let other = try #require(records.first { !$0.pullRequest.hasConflicts })
        #expect(DemoData.conflicts(of: other.pullRequest).files.isEmpty)
    }
}
