import Foundation
import Testing
@testable import AzureDevOpsCore

/// A work item's details, as BriefBar reads them when you open one, from a made-up Azure DevOps.
@Suite struct WorkItemDetailsTests {
    private static let org = Fixture.org

    private static func workItemURL(_ id: Int) -> String {
        "https://dev.azure.com/\(org)/_apis/wit/workItems/\(id)"
    }

    /// A task with every field the details show, its links, attachments and web pages.
    private static func details(project: String = "Shop", relations: [[String: Any]]? = nil) -> [String: Any] {
        [
            "id": 5, "rev": 3, "url": "https://example.invalid",
            "fields": [
                "System.Id": 5, "System.WorkItemType": "Task", "System.Title": "Show  saved items\n", "System.State": "Active",
                "System.TeamProject": project, "System.AssignedTo": Fixture.identity(People.me), "System.Parent": 1,
                "System.ChangedDate": iso(t(-hour)), "System.Reason": "Implementation started", "System.AreaPath": "Shop\\Cart",
                "System.IterationPath": "Shop\\Sprint 7", "System.CreatedBy": Fixture.identity(People.sam),
                "System.CreatedDate": iso(t(-3 * day)), "System.ChangedBy": Fixture.identity(People.me), "System.CommentCount": 3,
                "Microsoft.VSTS.Common.Priority": 2, "Microsoft.VSTS.Scheduling.RemainingWork": 3,
                "Microsoft.VSTS.Scheduling.OriginalEstimate": 5, "Microsoft.VSTS.Scheduling.CompletedWork": 2,
                "Microsoft.VSTS.Common.Activity": "Development", "System.Tags": "web; cart",
                "System.Description": "**Show** the list", "Microsoft.VSTS.Common.AcceptanceCriteria": "<ul><li>One</li></ul>",
                "Microsoft.VSTS.TCM.ReproSteps": "<div> </div>",
            ] as [String: Any],
            "multilineFieldsFormat": ["System.Description": "Markdown"],
            "relations": relations ?? [
                ["rel": "System.LinkTypes.Hierarchy-Reverse", "url": workItemURL(1), "attributes": ["isLocked": false, "name": "Parent"]],
                ["rel": "System.LinkTypes.Hierarchy-Forward", "url": workItemURL(7), "attributes": ["name": "Child"]],
                ["rel": "System.LinkTypes.Hierarchy-Forward", "url": workItemURL(8), "attributes": ["name": "Child"]],
                ["rel": "System.LinkTypes.Dependency-Forward", "url": workItemURL(9), "attributes": ["name": "Successor"]],
                ["rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2Fr1%2F42", "attributes": ["name": "Pull Request"]],
                ["rel": "AttachedFile", "url": "https://dev.azure.com/\(org)/p1/_apis/wit/attachments/abc", "attributes": ["name": "shot.png"]],
                ["rel": "Hyperlink", "url": "https://example.test/spec", "attributes": ["comment": "The spec"]],
                ["rel": "Hyperlink", "url": "javascript:alert(1)"],
                // Work item 4 in another organization, which this one's work item 4 isn't.
                ["rel": "System.LinkTypes.Remote.Related", "url": "https://dev.azure.com/fabrikam/p9/_apis/wit/workItems/4",
                 "attributes": ["name": "Remote Related"]],
            ],
        ]
    }

    private static var comments: [String: Any] {
        [
            "totalCount": 3, "count": 3,
            "comments": [
                ["workItemId": 5, "id": 12, "version": 2, "text": "Newest **one**", "format": "markdown",
                 "renderedText": "<p>Newest <strong>one</strong></p>", "createdBy": Fixture.identity(People.sam),
                 "createdDate": iso(t(-hour)), "modifiedDate": iso(t(-30 * minute)), "isDeleted": false],
                ["workItemId": 5, "id": 11, "text": "<div>Gone</div>", "createdBy": Fixture.identity(People.sam),
                 "createdDate": iso(t(-2 * hour)), "isDeleted": true],
                ["workItemId": 5, "id": 10, "text": "<div>First</div>", "format": "html", "createdBy": Fixture.identity(People.me),
                 "createdDate": iso(t(-day)), "modifiedDate": iso(t(-day))],
            ],
        ]
    }

    /// The parent, and two children in backlog order: 8 before 7. Work item 9 can't be read.
    private static func linked() -> [String: Any] {
        Fixture.list([
            WorkFixture.workItem(1, "User Story", "The story", state: "Active", rank: 1),
            WorkFixture.workItem(7, "Task", "Second task", state: "Closed", rank: 2),
            WorkFixture.workItem(8, "Task", "First task", assignee: People.me, remaining: 2, rank: 1),
        ])
    }

    private func serve(_ server: StubServer, details: [String: Any] = details(), comments: StubServer.Reply = .json(comments),
                       linked: StubServer.Reply = .json(linked())) {
        server.on("/\(Self.org)/_apis/wit/workitems/5", json: details)
        server.on("/\(Self.org)/Shop/_apis/wit/workItems/5/comments") { _ in comments }
        server.on("/\(Self.org)/_apis/wit/workitems", query: ["ids": "1,7,8,9"]) { _ in linked }
    }

    @Test func readsAWorkItemsDetailsWithGETsOnly() async throws {
        let server = StubServer()
        serve(server)
        let read = try await WorkItemDetailsReader.read(client: server.client(), organization: Self.org, project: "Shop", id: 5, now: t(0))

        // What it is and where it stands.
        #expect(read.item.id == 5)
        #expect(read.item.title == "Show saved items")
        #expect(read.item.type == "Task")
        #expect(read.item.category == .inProgress)
        #expect(read.item.assignedTo == People.me)
        #expect(read.item.parentId == 1)
        #expect(read.item.tags == ["web", "cart"])
        #expect(read.item.remainingWork == 3)
        #expect(read.reason == "Implementation started")
        #expect(read.areaPath == "Shop\\Cart")
        #expect(read.iterationPath == "Shop\\Sprint 7")
        #expect(read.priority == 2)
        #expect(read.size == nil && read.sizeTitle == nil)
        #expect(read.originalEstimate == 5 && read.completedWork == 2)
        #expect(read.activity == "Development")
        #expect(read.createdBy == People.sam && read.changedBy == People.me)
        #expect(read.createdAt == t(-3 * day))
        #expect(read.readAt == t(0))

        // Its text, in the format each field is kept in; empty ones are left out.
        #expect(read.texts.map(\.title) == ["Description", "Acceptance Criteria"])
        #expect(read.texts[0].text.blocks == [.paragraph([RichText.Run("Show", style: .bold), RichText.Run(" the list")])])
        #expect(read.texts[1].text.blocks == [.listItem(.bullet, depth: 0, [RichText.Run("One")])])

        // Its parent, its children in backlog order, then the rest; a pull request's link isn't a work item.
        #expect(read.links.map(\.workItemId) == [1, 8, 7, 9])
        #expect(read.parent?.item?.title == "The story")
        #expect(read.children.map { $0.item?.title } == ["First task", "Second task"])
        #expect(read.otherLinks.map(\.name) == ["Successor"])
        #expect(read.otherLinks.first?.item == nil)

        // Its file opens with its name, and a work item in another organization opens there; a link that isn't to a web page
        // is left out.
        #expect(read.resources.map(\.name) == ["shot.png", "The spec", "Remote Related: work item 4 in fabrikam"])
        #expect(read.resources.map(\.kind) == [.attachment, .webPage, .webPage])
        #expect(read.resources[2].url.absoluteString == "https://dev.azure.com/fabrikam/p9/_workitems/edit/4")
        #expect(read.resources[0].url.absoluteString == "https://dev.azure.com/\(Self.org)/p1/_apis/wit/attachments/abc?fileName=shot.png")

        // Its comments, newest first, as Azure DevOps renders them, but the deleted one.
        #expect(read.comments.map(\.id) == [12, 10])
        #expect(read.comments[0].text.blocks == [.paragraph([RichText.Run("Newest "), RichText.Run("one", style: .bold)])])
        #expect(read.comments[0].isEdited)
        #expect(!read.comments[1].isEdited)
        #expect(read.comments[0].author == People.sam)
        #expect(read.commentCount == 3)
        #expect(read.commentsProblem == nil)

        // The work item, its comments, and what its links are.
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        let commentsRequest = try #require(server.requests.first { $0.url?.path.hasSuffix("/comments") == true }?.url)
        let query = URLComponents(url: commentsRequest, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "$top", value: "50")))
        #expect(query.contains(URLQueryItem(name: "order", value: "desc")))
        #expect(query.contains(URLQueryItem(name: "$expand", value: "renderedText")))
        #expect(query.contains(URLQueryItem(name: "api-version", value: "7.1-preview.4")))
    }

    @Test func readsTheCommentsOnceItKnowsTheProject() async throws {
        let server = StubServer()
        serve(server)
        let read = try await WorkItemDetailsReader.read(client: server.client(), organization: Self.org, project: nil, id: 5)
        #expect(read.item.project == "Shop")
        #expect(read.comments.map(\.id) == [12, 10])
        let paths = server.requests.compactMap(\.url?.path)
        #expect(paths.count == 3)
        #expect(paths.first == "/\(Self.org)/_apis/wit/workitems/5")
        #expect(paths.dropFirst().first == "/\(Self.org)/Shop/_apis/wit/workItems/5/comments")
    }

    @Test func readsTheCommentsThroughTheProjectAWorkItemMovedTo() async throws {
        let server = StubServer()
        serve(server)
        server.on("/\(Self.org)/Old/_apis/wit/workItems/5/comments") { _ in .status(404) }
        let read = try await WorkItemDetailsReader.read(client: server.client(), organization: Self.org, project: "Old", id: 5)
        #expect(read.comments.map(\.id) == [12, 10])
        #expect(read.commentsProblem == nil)
        #expect(server.requests.count == 4)
    }

    @Test func showsAWorkItemWhoseCommentsCantBeRead() async throws {
        let server = StubServer()
        serve(server, comments: .status(403))
        let read = try await WorkItemDetailsReader.read(client: server.client(), organization: Self.org, project: "Shop", id: 5)
        #expect(read.item.title == "Show saved items")
        #expect(read.comments.isEmpty)
        #expect(read.commentCount == 3)
        #expect(read.commentsProblem == ADOError.forbidden.description)
    }

    @Test func linkedWorkItemsThatCantBeReadKeepTheirIDs() async throws {
        let server = StubServer()
        serve(server, linked: .status(500))
        let read = try await WorkItemDetailsReader.read(client: server.client(), organization: Self.org, project: "Shop", id: 5)
        #expect(read.links.map(\.workItemId) == [1, 7, 8, 9])
        #expect(read.links.allSatisfy { $0.item == nil })
    }

    @Test func aWorkItemWithoutLinksReadsNoMore() async throws {
        let server = StubServer()
        serve(server, details: Self.details(relations: []))
        let read = try await WorkItemDetailsReader.read(client: server.client(), organization: Self.org, project: "Shop", id: 5)
        #expect(read.links.isEmpty && read.resources.isEmpty)
        #expect(server.requests.count == 2)
    }

    @Test func failsWhenTheWorkItemCantBeRead() async {
        let server = StubServer()
        server.on("/\(Self.org)/Shop/_apis/wit/workItems/5/comments", json: Self.comments)
        await #expect(throws: ADOError.notFound) {
            try await WorkItemDetailsReader.read(client: server.client(), organization: Self.org, project: "Shop", id: 5)
        }
    }

    @Test func aStoryNamesItsSizeAsItsProcessDoes() throws {
        var json = Self.details(relations: [])
        var fields = json["fields"] as! [String: Any]
        fields["System.WorkItemType"] = "Product Backlog Item"
        fields["Microsoft.VSTS.Scheduling.Effort"] = 8
        json["fields"] = fields
        let dto = try Fixture.decode(ADOWorkItemDetails.self, json)
        let read = WorkItemDetails(organization: Self.org, project: "Shop", dto, comments: nil, linked: [:], readAt: t(0))
        #expect(read.size == 8 && read.sizeTitle == "Effort")
        // Without a project, its comments can't be read.
        #expect(read.commentsProblem != nil)
    }

    @Test func findsTheWorkItemsALinkIsTo() throws {
        func relation(_ rel: String, _ url: String) throws -> ADOWorkItemDetails.Relation {
            try Fixture.decode(ADOWorkItemDetails.Relation.self, ["rel": rel, "url": url])
        }
        let related = "System.LinkTypes.Related"
        #expect(try relation(related, "https://dev.azure.com/contoso/_apis/wit/workItems/12").workItemId(in: "Contoso") == 12)
        #expect(try relation(related, "https://dev.azure.com/contoso/p1/_apis/wit/workItems/56").workItemId(in: "contoso") == 56)
        #expect(try relation(related, "https://contoso.visualstudio.com/_apis/wit/WorkItems/34/").workItemId(in: "contoso") == 34)
        #expect(try relation(related, "https://contoso.visualstudio.com/DefaultCollection/_apis/wit/workItems/7").workItemId(in: "contoso") == 7)
        // Not to a work item, or not one this address names.
        #expect(try relation("ArtifactLink", "vstfs:///Git/PullRequestId/p%2Fr%2F12").workItemId(in: "contoso") == nil)
        #expect(try relation("Hyperlink", "https://dev.azure.com/contoso/_apis/wit/workItems/5").workItemId(in: "contoso") == nil)
        #expect(try relation(related, "https://dev.azure.com/contoso/_apis/wit/workItems/x").workItemId(in: "contoso") == nil)
        #expect(try relation(related, "https://dev.azure.com/contoso/_apis/wit/workItems/99999999999999999999").workItemId(in: "contoso") == nil)
        #expect(try relation(related, "https://example.test/contoso/_apis/wit/workItems/5").workItemId(in: "contoso") == nil)
        #expect(try relation(related, "https://dev.azure.com/contoso/a/b/_apis/wit/workItems/5").workItemId(in: "contoso") == nil)

        // In another organization, its ID is another work item here: it opens there instead.
        let remote = try relation("System.LinkTypes.Remote.Related", "https://fabrikam.visualstudio.com/_apis/wit/workItems/12")
        #expect(remote.workItemId(in: "contoso") == nil)
        #expect(remote.workItemId(in: "fabrikam") == 12)
        #expect(remote.resource(in: "contoso") == WorkItemDetails.Resource(
            kind: .webPage, name: "Remote Related: work item 12 in fabrikam", url: URL(string: "https://dev.azure.com/fabrikam/_workitems/edit/12")!
        ))
        #expect(remote.resource(in: "fabrikam") == nil)
        #expect(try relation(related, "https://dev.azure.com/contoso/_apis/wit/workItems/12").resource(in: "contoso") == nil)

        #expect(WorkItemDetails.linkName("System.LinkTypes.Dependency-Reverse") == "Predecessor")
        #expect(WorkItemDetails.linkName("Custom.Something") == "Linked")
    }

    @Test func buildsTheDetailsURLs() {
        #expect(ADOEndpoint.workItem(organization: "contoso", id: 5).absoluteString
            == "https://dev.azure.com/contoso/_apis/wit/workitems/5?$expand=relations&api-version=7.1")
        #expect(ADOEndpoint.workItemComments(organization: "contoso", project: "My Shop", id: 5, top: 50).absoluteString
            == "https://dev.azure.com/contoso/My%20Shop/_apis/wit/workItems/5/comments?$top=50&order=desc&$expand=renderedText&api-version=7.1-preview.4")
    }

    @Test func findsAWorkItemOnTheBoard() {
        let board = DemoData.sprintBoard(now: t(0))
        #expect(board.item(WorkItemKey("CONTOSO", 5103))?.title == "Show saved items under the cart")
        #expect(board.item(WorkItemKey("contoso", 5101))?.type == "User Story")
        #expect(board.item(WorkItemKey("fabrikam", 5103)) == nil)
        #expect(board.item(WorkItemKey("contoso", 1)) == nil)
    }

    @Test func demoDetailsHaveEverything() throws {
        let story = try #require(DemoData.workItemDetails(organization: "contoso", id: 5101, now: t(0)))
        #expect(story.texts.map(\.title) == ["Description", "Acceptance Criteria"])
        #expect(story.children.count == 4)
        #expect(story.comments.count == 3)
        let task = try #require(DemoData.workItemDetails(organization: "contoso", id: 5103, now: t(0)))
        #expect(task.parent?.workItemId == 5101)
        #expect(task.texts.first?.text.blocks.contains { if case .listItem(.checkbox(checked: true), _, _) = $0 { true } else { false } } == true)
        #expect(DemoData.workItemDetails(organization: "contoso", id: 1, now: t(0)) == nil)
    }
}
