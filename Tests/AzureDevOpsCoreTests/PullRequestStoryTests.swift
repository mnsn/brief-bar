import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// What a pull request's story says: one in your lists, from its row and what was read for it; one that's only linked,
/// such as a teammate's, from the pull request alone.
@Suite struct PullRequestStoryTests {
    private let me = People.me
    private let chen = Person(id: "66666666-6666-6666-6666-666666666666", name: "Chen Wei")
    private let maria = Person(id: "77777777-7777-7777-7777-777777777777", name: "Maria Garcia")
    private let jordan = Person(id: "88888888-8888-8888-8888-888888888888", name: "Jordan Lee")
    private let team = Person(id: "99999999-9999-9999-9999-999999999999", name: "[Shop]\\Checkout Team")
    private let unitTests = PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed in CheckoutTests.")

    private func record(_ pr: PullRequest, role: PRRole = .author, details: PRDetails? = nil, merge: MergePipelines? = nil) -> PRRecord {
        PRRecord(pullRequest: pr, role: role, details: details, me: me.id, merge: merge)
    }

    /// Its row, as the classifier makes it: seen up to three days ago.
    private func snapshot(_ record: PRRecord) throws -> PRSnapshot {
        try #require(PRClassifier.snapshot(for: record, seenCutoff: t(-3 * day), dismissedCutoff: t(-3 * day), now: t(0)))
    }

    private func story(_ record: PRRecord) throws -> ItemStory {
        PullRequestStory.mine(try snapshot(record), record: record)
    }

    /// A fact, whether it shows first or only with the rest.
    private func fact(_ label: String, in story: ItemStory) -> String? {
        (story.facts + story.more).first { $0.label == label }?.value
    }

    private func passing(_ extra: [Check] = []) -> [Check] {
        [Check(name: "CI", kind: .build, state: .passed), Check(name: "Minimum number of reviewers", kind: .reviewers, state: .passed)] + extra
    }

    /// A pipeline that ran after a merge, with its latest run.
    private func pipeline(
        _ id: Int, _ name: String, _ run: PipelineRun.Status, stages: [PipelineStage] = [], failure: PipelineFailure? = nil
    ) -> PipelineStatus {
        let ref = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: id, name: name)
        let latest = PipelineRun(
            id: id, organization: Fixture.org, projectName: "Shop", number: "20261018.\(id)", status: run, trigger: .push,
            branch: "main", queuedAt: t(-50 * minute), startedAt: t(-49 * minute), finishedAt: run.isFinished ? t(-minute) : nil
        )
        return PipelineStatus(pipeline: ref, runs: [latest], stages: stages, failure: failure)
    }

    // MARK: Yours: where it stands

    @Test func itsSentenceIsItsRowsHeadlineAndDetailInALine() throws {
        let waiting = makePR(reviewers: [Reviewer(person: People.sam, vote: .none)])
        let minimum = Check(name: "Minimum number of reviewers", kind: .reviewers, state: .pending, minimumApprovers: 2)
        let waitingStory = try story(record(waiting, details: makeDetails(
            for: waiting, checks: [Check(name: "CI", kind: .build, state: .passed), minimum], lastActivity: t(-hour)
        )))
        #expect(waitingStory.sentence == "Waiting for reviewers: 0 of 2 approvals")

        let commented = makePR()
        let thread = ReviewThread(id: 5, comments: [comment(1, People.sam, "Could we cap the backoff at 30 seconds?", at: t(-hour))])
        let needsYou = try story(record(commented, details: makeDetails(for: commented, checks: passing(), threads: [thread])))
        #expect(needsYou.sentence == "Sam Rivera commented: Could we cap the backoff at 30 seconds?")
        #expect(needsYou.date == t(-hour))

        let failing = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        let failed = Check(name: "web-ci", kind: .build, state: .failed, completedAt: t(-2 * hour), buildId: 41, failure: unitTests)
        let failingStory = try story(record(failing, details: makeDetails(for: failing, checks: [failed], lastActivity: t(-hour))))
        #expect(failingStory.sentence == "Build failed: web-ci · Run unit tests: 2 tests failed in CheckoutTests.")
        #expect(failingStory.date == t(-2 * hour))

        let ready = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        let readyStory = try story(record(ready, details: makeDetails(for: ready, checks: passing(), lastActivity: t(-hour))))
        #expect(readyStory.sentence == "Ready to complete: Approved by Sam Rivera")

        let done = try story(record(makePR(status: .completed, closed: t(-2 * hour))))
        #expect(done.sentence == "Completed: Merged into main")
        #expect(done.date == t(-2 * hour))

        // A headline without a detail is all it says.
        let draft = makePR(draft: true)
        #expect(try story(record(draft, details: makeDetails(for: draft))).sentence == "Draft")
        // Not for how long, which its date says: "No activity for 20 days" says a day more each day.
        let quiet = makePR(created: t(-20 * day))
        let quietStory = try story(record(quiet, details: makeDetails(for: quiet, lastActivity: t(-20 * day))))
        #expect(quietStory.sentence == "No recent activity")
        #expect(quietStory.date == t(-20 * day))
        // What a row says of the pull request itself can be shared as it is.
        #expect(readyStory.sharedSentence == nil)
        #expect(failingStory.sharedSentence == nil)
    }

    // MARK: Yours: sent in a chat

    /// Dana sent it to you in Teams, as Notification Center has it.
    private func sent(_ pr: PullRequest, at date: Date = t(-10 * minute)) -> ChatLink {
        ChatLink(link: PullRequestLink(organization: pr.key.organization, project: pr.projectName, repository: pr.repositoryName,
                                       number: pr.key.number),
                 app: Chats.teams, sender: "Dana Whitfield", sentAt: date, notificationKey: "n1",
                 conversation: Chats.dana, messageID: teamsMessageID(date))
    }

    /// What a summary of a work item with only this pull request linked to it sends Copilot, between `<data>` and `</data>`.
    private func shared(_ pr: PullRequest, _ story: ItemStory, row: PRSnapshot) -> String {
        let prompt = StorySummaryPrompt.make(
            subject: StorySummaryPrompt.Item(kind: "Work item", label: "5110", title: "Coupon totals round down", status: "Active"),
            linked: [StorySummaryPrompt.Item(
                kind: "Pull request", label: "!\(pr.key.number)", title: pr.title,
                status: PullRequestStory.sharedStatus(row) ?? row.group.rawValue, link: "Linked in Azure DevOps", story: story
            )]
        )
        return String(prompt[prompt.range(of: "<data>\n")!.upperBound...])
    }

    @Test func whoSentItToYouInAChatStaysOnThisMac() throws {
        let pr = makePR(author: People.alex, reviewers: [
            Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.sam, vote: .none, isRequired: true),
        ])
        let record = PRRecord(pullRequest: pr, role: .linked, details: makeDetails(for: pr, lastActivity: t(-hour)), me: me.id,
                              chatLinks: [sent(pr)])
        let row = try snapshot(record)
        #expect(row.reason == .sentInChat)
        let story = PullRequestStory.mine(row, record: record)
        // You see who sent it, and where.
        #expect(story.sentence == "Dana Whitfield sent this in Teams: By Alex Kim")
        // What's shared says where it stands by its votes, as for a pull request you're not on.
        #expect(story.sharedSentence == "Waiting for reviewers: Sam Rivera")
        #expect(PullRequestStory.sharedStatus(row) == "Active")
        let data = shared(pr, story, row: row)
        #expect(data.contains("Status: Waiting for reviewers: Sam Rivera"))
        for said in ["Dana", "Whitfield", "Teams", "sent this", "chat"] {
            #expect(!data.contains(said))
        }
        // Without its record, what its row says of the pull request itself.
        #expect(PullRequestStory.mine(row, record: nil).sharedSentence == "Active")
    }

    @Test func whoSentItToYouInAChatStaysOnThisMacOnceYouAnswered() throws {
        let pr = makePR(author: People.alex, reviewers: [Reviewer(person: me, vote: .approved), Reviewer(person: People.priya, vote: .approved)])
        let details = makeDetails(for: pr, activity: [Activity(threadId: 2, kind: .vote, at: t(-5 * minute), actor: me, vote: .approved)])
        let record = PRRecord(pullRequest: pr, role: .reviewer, details: details, me: me.id, chatLinks: [sent(pr)])
        let row = try snapshot(record)
        #expect(row.reason == .answered)
        let story = PullRequestStory.mine(row, record: record)
        #expect(story.sentence == "You approved: Dana Whitfield sent this in Teams")
        #expect(story.sharedSentence == "Approved by you and Priya Shah")
        #expect(PullRequestStory.sharedStatus(row) == "Active")
        let data = shared(pr, story, row: row)
        #expect(data.contains("Status: Approved by you and Priya Shah"))
        for said in ["Dana", "Whitfield", "Teams", "sent this", "chat", "answered"] {
            #expect(!data.contains(said))
        }

        // Answering a comment, with nobody's message about it, is the pull request's own.
        let thread = ReviewThread(id: 5, comments: [
            comment(1, me, "Why?", at: t(-5 * hour)), comment(2, People.sam, "Because", at: t(-hour)), comment(3, me, "OK", at: t(-30 * minute)),
        ])
        let replied = try snapshot(PRRecord(pullRequest: pr, role: .reviewer, details: makeDetails(for: pr, threads: [thread]), me: me.id))
        #expect(replied.reason == .answered)
        #expect(PullRequestStory.mine(replied, record: nil).sharedSentence == nil)
        #expect(PullRequestStory.sharedStatus(replied) == nil)
    }

    @Test func aLongDetailIsCutToALine() throws {
        let pr = makePR()
        let text = String(repeating: "Please rename this. ", count: 12) + "\nAnd add a test."
        let thread = ReviewThread(id: 5, comments: [comment(1, People.sam, text, at: t(-hour))])
        let sentence = try story(record(pr, details: makeDetails(for: pr, checks: passing(), threads: [thread]))).sentence
        #expect(sentence.hasPrefix("Sam Rivera commented: Please rename this. Please rename this."))
        #expect(sentence.count <= 160)
        #expect(sentence.hasSuffix("…"))
        #expect(!sentence.contains("\n"))
    }

    // MARK: Yours: facts

    @Test func reviewersArePeopleByHowTheyVotedYouFirst() throws {
        let pr = makePR(author: People.sam, reviewers: [
            Reviewer(person: People.priya, vote: .approved),
            Reviewer(person: team, vote: .approved, isRequired: true, isGroup: true),
            Reviewer(person: maria, vote: .none, hasDeclined: true),
            Reviewer(person: chen, vote: .rejected),
            Reviewer(person: People.alex, vote: .waitingForAuthor),
            Reviewer(person: jordan, vote: .approvedWithSuggestions),
            Reviewer(person: me, vote: .none, isRequired: true),
        ])
        let reviewing = try story(record(pr, role: .reviewer, details: makeDetails(for: pr, lastActivity: t(-hour))))
        // Who wrote it says less: it shows with the rest.
        #expect(reviewing.more.first == ItemStory.Fact("Author", "Sam Rivera"))
        #expect(fact("Reviewers", in: reviewing) == "Approved by Jordan Lee and Priya Shah · Changes requested by Alex Kim and Chen Wei · "
            + "Waiting on you (required) · Declined by Maria Garcia")
        #expect(reviewing.facts.first?.label == "Reviewers")

        // Only groups: nobody to name.
        let groups = makePR(reviewers: [Reviewer(person: team, vote: .approved, isRequired: true, isGroup: true)])
        #expect(fact("Reviewers", in: try story(record(groups))) == nil)
    }

    @Test func withoutItsRecordTheRowsApprovalsAreItsReviewers() throws {
        let pr = makePR(reviewers: [
            Reviewer(person: People.sam, vote: .approved), Reviewer(person: People.priya, vote: .approvedWithSuggestions),
            Reviewer(person: team, vote: .approved, isGroup: true), Reviewer(person: People.alex, vote: .none),
        ])
        let alone = PullRequestStory.mine(try snapshot(record(pr)), record: nil)
        #expect(alone.facts == [ItemStory.Fact("Reviewers", "Approved by Sam Rivera and Priya Shah")])
        #expect(alone.runs.isEmpty)

        #expect(PullRequestStory.mine(try snapshot(record(makePR())), record: nil).facts.isEmpty)
    }

    @Test func yourOwnHasNoAuthor() throws {
        let story = try story(record(makePR()))
        #expect(fact("Author", in: story) == nil)
        #expect(story.facts.isEmpty)
        #expect(story.more == [ItemStory.Fact("Branch", "fix-total → main")])
    }

    @Test func commentsSayHowManyThreadsAreOpenAndHowManyWaitOnYou() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.priya, vote: .waitingForAuthor)])
        let threads = [
            ReviewThread(id: 1, comments: [comment(1, People.sam, "Could we cap the backoff?", at: t(-hour))]),
            ReviewThread(id: 2, status: "pending", comments: [
                comment(1, People.priya, "Rename this?", at: t(-3 * hour)), comment(2, me, "Done", at: t(-2 * hour)),
            ]),
            ReviewThread(id: 3, status: "fixed", comments: [comment(1, People.sam, "Typo", at: t(-5 * day))]),
            ReviewThread(id: 4, status: "closed", comments: [comment(1, People.alex, "Nit", at: t(-4 * day))]),
            ReviewThread(id: 5, comments: [comment(1, People.alex, "@Robin Diaz why not a struct?", at: t(-30 * minute), mentions: [me])]),
        ]
        // Priya's vote that wants changes waits on you too.
        let vote = Activity(threadId: 6, kind: .vote, at: t(-20 * minute), actor: People.priya, vote: .waitingForAuthor)
        let details = makeDetails(for: pr, threads: threads, activity: [vote])
        #expect(fact("Comments", in: try story(record(pr, details: details))) == "3 open threads · 3 wait on you")

        // A message about it and new commits need you too, but don't wait on you in its comments.
        var row = try snapshot(record(pr, details: details))
        row.events += [
            PREvent(id: "s1", kind: .sentInChat, at: t(-minute), actor: "Dana Whitfield", app: "Teams"),
            PREvent(id: "p1", kind: .newCommits, at: t(-minute)),
        ]
        #expect(fact("Comments", in: PullRequestStory.mine(row, record: record(pr, details: details))) == "3 open threads · 3 wait on you")

        let one = makePR()
        func comments(_ threads: [ReviewThread]) throws -> String? {
            fact("Comments", in: try story(record(one, details: makeDetails(for: one, threads: threads))))
        }
        #expect(try comments([threads[0]]) == "1 open thread · 1 waits on you")
        #expect(try comments([threads[1]]) == "1 open thread")
        #expect(try comments([threads[2], threads[3]]) == "No open threads")
        // Until they're read, it says nothing of them.
        #expect(fact("Comments", in: try story(record(one))) == nil)
    }

    @Test func mergeSaysHowAnActivePullRequestsMergeStands() throws {
        #expect(fact("Merge", in: try story(record(makePR(merge: "conflicts", autoComplete: true))))
            == "Conflicts with main · Completes by itself once it can")
        #expect(fact("Merge", in: try story(record(makePR(draft: true)))) == "Draft")
        #expect(fact("Merge", in: try story(record(makePR()))) == nil)
        // Nothing, once it's closed.
        #expect(fact("Merge", in: try story(record(makePR(status: .completed, closed: t(-hour), merge: "conflicts")))) == nil)
        #expect(fact("Merge", in: try story(record(makePR(status: .abandoned, closed: t(-hour), draft: true)))) == nil)
    }

    @Test func branchIsWhereItMergesFromAndInto() throws {
        #expect(fact("Branch", in: try story(record(makePR()))) == "fix-total → main")
        var unknown = makePR()
        unknown.sourceBranch = ""
        #expect(fact("Branch", in: try story(record(unknown))) == nil)
    }

    // MARK: Yours: runs

    @Test func runsAreItsBuildsAndStatusChecksWhatNeedsYouFirst() throws {
        let pr = makePR()
        let checks = [
            Check(name: "web-ci", kind: .build, state: .passed, completedAt: t(-3 * hour), buildId: 40),
            Check(name: "api-ci", kind: .build, state: .failed, completedAt: t(-hour), buildId: 41, failure: unitTests),
            Check(name: "docs-ci", kind: .build, state: .running, buildId: 42),
            Check(name: "perf", kind: .build, state: .queued, isBlocking: false, buildId: 43),
            Check(name: "old-ci", kind: .build, state: .expired, completedAt: t(-20 * day), buildId: 44),
            Check(name: "manual-ci", kind: .build, state: .notRun),
            Check(name: "license", kind: .status, state: .pending),
            Check(name: "security/scan", kind: .status, state: .passed, completedAt: t(-2 * hour)),
            // Not runs: a build that doesn't apply, and the other policies.
            Check(name: "legacy-ci", kind: .build, state: .notApplicable),
            Check(name: "Minimum number of reviewers", kind: .reviewers, state: .pending, minimumApprovers: 1),
            Check(name: "Work item linking", kind: .requirement, state: .passed),
            Check(name: "Require a merge strategy", kind: .completion, state: .pending),
        ]
        let runs = try story(record(pr, details: makeDetails(for: pr, checks: checks, lastActivity: t(-hour)))).runs
        #expect(runs.map(\.name) == ["api-ci", "docs-ci", "perf", "old-ci", "license", "manual-ci", "security/scan", "web-ci"])
        #expect(runs.map(\.state) == [.failing, .running, .running, nil, nil, nil, .done, .done])
        #expect(runs.map(\.status) == [
            "Failed at Run unit tests", "Running", "Queued", "Expired: it has to run again", "Waiting", "Not run", "Passed", "Passed",
        ])
        #expect(runs.map(\.detail) == ["2 tests failed in CheckoutTests.", nil, nil, nil, nil, nil, nil, nil])
        #expect(runs.map(\.date) == [t(-hour), nil, nil, t(-20 * day), nil, nil, t(-2 * hour), t(-3 * hour)])
        // A build opens its run; a status check has none.
        #expect(runs[0].url?.absoluteString == "https://dev.azure.com/contoso/Shop/_build/results?buildId=41")
        #expect(runs.map { $0.url != nil } == [true, true, true, true, false, false, false, true])
    }

    @Test func aFailedRunSaysWhereAndItsFirstError() throws {
        let pr = makePR()
        let message = "error CS0103: The name 'total' does not exist in the current context.\n" + String(repeating: "More detail. ", count: 20)
        let checks = [
            Check(name: "web-ci", kind: .build, state: .failed, completedAt: t(-hour), buildId: 41,
                  failure: PipelineFailure(stage: nil, step: "Compile", message: message)),
            Check(name: "api-ci", kind: .build, state: .failed, completedAt: t(-2 * hour), buildId: 42),
            Check(name: "scan", kind: .status, state: .failed, completedAt: t(-3 * hour)),
        ]
        let runs = try story(record(pr, details: makeDetails(for: pr, checks: checks, lastActivity: t(-hour)))).runs
        #expect(runs.map(\.status) == ["Failed at Compile", "Failed", "Failed"])
        let detail = try #require(runs[0].detail)
        #expect(detail.hasPrefix("error CS0103: The name 'total' does not exist in the current context. More detail."))
        #expect(detail.count <= 200)
        #expect(detail.hasSuffix("…"))
        #expect(runs[1].detail == nil)
        #expect(runs[1].url == ADOEndpoint.buildPage(organization: "contoso", project: "Shop", buildId: 42))
        #expect(runs[2].url == nil)
    }

    @Test func onceItMergedThePipelinesAfterItAreARun() throws {
        var pr = makePR(status: .completed, closed: t(-hour))
        pr.mergeCommit = "m1"
        func story(_ pipelines: [PipelineStatus]) throws -> ItemStory {
            let merge = MergePipelines(pullRequest: pr.key, title: pr.title, targetBranch: pr.targetBranch, mergedAt: t(-hour),
                                       url: pr.webURL, pipelines: pipelines, isFollowing: true)
            return try self.story(record(pr, merge: merge))
        }
        let ci = pipeline(1, "shop-web CI", .succeeded)
        let deployRun = URL(string: "https://dev.azure.com/contoso/Shop/_build/results?buildId=2")

        let failed = try story([ci, pipeline(2, "shop-web Deploy", .failed, failure: unitTests)])
        #expect(failed.sentence == "Failed after merge: shop-web Deploy · Run unit tests: 2 tests failed in CheckoutTests.")
        #expect(failed.runs == [ItemStory.Run(
            name: "shop-web Deploy", state: .failing, status: "Failed at Run unit tests", detail: "2 tests failed in CheckoutTests.",
            url: deployRun, date: t(-minute)
        )])
        #expect(failed.facts.isEmpty)
        #expect(failed.more == [ItemStory.Fact("Branch", "fix-total → main")])

        let production = PipelineStage(id: "s3", name: "Production", state: .waiting)
        let waiting = try story([ci, pipeline(2, "shop-web Deploy", .running, stages: [production])])
        #expect(waiting.runs == [ItemStory.Run(
            name: "shop-web Deploy", state: nil, status: "Waiting for approval to Production", url: deployRun, date: t(-49 * minute)
        )])

        let running = try story([ci, pipeline(2, "shop-web Deploy", .running)])
        #expect(running.runs == [ItemStory.Run(name: "Pipelines after merge", state: .running, status: "Running", date: t(-50 * minute))])

        let passed = try story([ci, pipeline(2, "shop-web Deploy", .succeeded)])
        #expect(passed.runs == [ItemStory.Run(name: "Pipelines after merge", state: .done, status: "Passed", date: t(-minute))])
    }

    // MARK: Linked, not yours

    @Test func aLinkedPullRequestStandsWhereItsVotesSay() {
        func sentence(_ reviewers: [Reviewer], draft: Bool = false) -> String {
            PullRequestStory.others(makePR(author: People.sam, reviewers: reviewers, draft: draft)).sentence
        }
        #expect(sentence([Reviewer(person: People.priya, vote: .rejected)], draft: true) == "Draft")
        #expect(sentence([Reviewer(person: People.priya, vote: .waitingForAuthor), Reviewer(person: People.alex, vote: .approved)])
            == "Priya Shah wants changes")
        #expect(sentence([Reviewer(person: People.priya, vote: .waitingForAuthor), Reviewer(person: chen, vote: .rejected)])
            == "Changes requested")
        // A group's vote isn't a person's.
        #expect(sentence([Reviewer(person: team, vote: .rejected, isGroup: true), Reviewer(person: People.priya, vote: .approved)])
            == "Approved by Priya Shah")
        // Approved once every required person has, whoever else hasn't voted.
        #expect(sentence([
            Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.alex, vote: .approvedWithSuggestions, isRequired: true),
            Reviewer(person: chen, vote: .none),
        ]) == "Approved by Alex Kim and Priya Shah")
        #expect(sentence([Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.alex, vote: .none, isRequired: true)])
            == "Waiting for reviewers: Alex Kim")
        #expect(sentence([]) == "Waiting for reviewers")
        #expect(sentence([Reviewer(person: maria, vote: .none, hasDeclined: true)]) == "Waiting for reviewers")
        let five = [People.priya, People.alex, chen, maria, jordan].map { Reviewer(person: $0, vote: .none) }
        #expect(sentence(Array(five.prefix(3))) == "Waiting for reviewers: Alex Kim, Chen Wei and Priya Shah")
        #expect(sentence(five) == "Waiting for reviewers: Alex Kim, Chen Wei, Jordan Lee and 2 more")
    }

    @Test func aLinkedPullRequestThatsClosed() {
        let completed = PullRequestStory.others(makePR(status: .completed, author: People.sam, closed: t(-hour)))
        #expect(completed.sentence == "Merged into main")
        #expect(completed.footnote == nil)
        #expect(completed.date == t(-hour))
        #expect(PullRequestStory.others(makePR(status: .abandoned, closed: t(-hour))).sentence == "Abandoned")
        #expect(PullRequestStory.others(makePR(status: .other)).sentence == "Closed")
    }

    @Test func aLinkedPullRequestsFactsAreWhatItSaysItself() {
        let pr = makePR(author: People.sam, created: t(-5 * hour), reviewers: [
            Reviewer(person: People.priya, vote: .approved), Reviewer(person: team, vote: .none, isRequired: true, isGroup: true),
            Reviewer(person: People.alex, vote: .none, isRequired: true),
        ], merge: "conflicts", autoComplete: true)
        let story = PullRequestStory.others(pr)
        #expect(story.sentence == "Waiting for reviewers: Alex Kim")
        #expect(story.date == t(-5 * hour))
        #expect(story.facts == [
            ItemStory.Fact("Reviewers", "Approved by Priya Shah · Waiting on Alex Kim (required)"),
            ItemStory.Fact("Merge", "Conflicts with main · Completes by itself once it can"),
        ])
        #expect(story.more == [ItemStory.Fact("Author", "Sam Rivera"), ItemStory.Fact("Branch", "fix-total → main")])
        // It says why there are no builds or comments.
        #expect(story.footnote == "Builds and comments aren't read for pull requests you're not on.")
        #expect(story.runs.isEmpty)
        #expect(story.account == nil)

        var merged = pr
        merged.status = .completed
        merged.closedAt = t(-hour)
        #expect(PullRequestStory.others(merged).facts.map(\.label) == ["Reviewers"])
        #expect(PullRequestStory.others(merged).more.map(\.label) == ["Author", "Branch"])
    }

    @Test func aLinkedPullRequestSaysYouRatherThanYourName() {
        let waiting = makePR(author: People.sam, reviewers: [
            Reviewer(person: me, vote: .none, isRequired: true), Reviewer(person: People.priya, vote: .approved),
        ])
        let story = PullRequestStory.others(waiting, me: me.id)
        #expect(story.sentence == "Waiting for your review")
        #expect(story.facts.first == ItemStory.Fact("Reviewers", "Approved by Priya Shah · Waiting on you (required)"))
        // Without knowing who you are, by name.
        #expect(PullRequestStory.others(waiting).sentence == "Waiting for reviewers: Robin Diaz")

        let yours = makePR(author: me, reviewers: [Reviewer(person: People.priya, vote: .waitingForAuthor)])
        #expect(PullRequestStory.others(yours, me: me.id).sentence == "Priya Shah is waiting for you")
        #expect(PullRequestStory.others(yours, me: me.id).more.first == ItemStory.Fact("Author", "You"))
        let approved = makePR(author: People.sam, reviewers: [Reviewer(person: People.priya, vote: .approved), Reviewer(person: me, vote: .approved)])
        #expect(PullRequestStory.others(approved, me: me.id).sentence == "Approved by you and Priya Shah")
    }
}
