import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// What a pull request's details show of it, from what the lists read: its threads, what waits on you first; its builds
/// and checks, what failed first; its reviewers, the ones it requires first; and where what's left leads.
@Suite struct PullRequestPanelTests {
    private let me = People.me

    private func record(_ pr: PullRequest, role: PRRole = .author, checks: [Check] = [], checksKnown: Bool = true,
                        threads: [ReviewThread] = [], details: Bool = true) -> PRRecord {
        PRRecord(
            pullRequest: pr, role: role,
            details: details ? makeDetails(for: pr, checks: checks, checksKnown: checksKnown, threads: threads, lastActivity: t(-hour)) : nil,
            me: me.id
        )
    }

    /// The row the list shows for it, with what you've seen up to `seen`.
    private func snapshot(_ record: PRRecord, seen: Date = t(-3 * day)) throws -> PRSnapshot {
        try #require(PRClassifier.snapshot(for: record, seenCutoff: seen, dismissedCutoff: t(-3 * day), now: t(0)))
    }

    private func panel(_ record: PRRecord, seen: Date = t(-3 * day)) throws -> PullRequestPanel {
        PullRequestPanel(try snapshot(record, seen: seen), record: record)
    }

    // MARK: Threads

    @Test func threadsThatWaitOnYouComeFirstThenTheOpenOnesThenTheResolvedOnes() throws {
        let threads = [
            // You answered: open, but it doesn't wait on you.
            ReviewThread(id: 1, filePath: "/src/Cart.cs", line: 12, comments: [
                comment(1, People.sam, "Round half up?", at: t(-5 * hour)), comment(2, me, "Done.", at: t(-4 * hour)),
            ]),
            // Sam answered you: it waits on you.
            ReviewThread(id: 2, filePath: "/src/Cart.cs", line: 40, comments: [
                comment(1, me, "Is a minute enough?", at: t(-6 * hour)), comment(2, People.sam, "Make it two.", at: t(-2 * hour)),
            ]),
            // Resolved before you last looked: only a new comment in one would need you.
            ReviewThread(id: 3, status: "fixed", comments: [comment(1, People.priya, "Add a test?", at: t(-4 * day))]),
            // Waiting on someone else, and newer than the one you answered.
            ReviewThread(id: 4, status: "pending", comments: [
                comment(1, me, "@Alex could you check the cache?", at: t(-3 * hour)),
            ]),
            ReviewThread(id: 5, status: "closed", comments: [comment(1, People.alex, "Typo here.", at: t(-5 * day))]),
        ]
        let pr = makePR(created: t(-6 * day))
        let panel = try panel(record(pr, threads: threads))
        #expect(panel.threads.waitingOnYou.map(\.id) == [2])
        #expect(panel.threads.open.map(\.id) == [4, 1])
        #expect(panel.threads.resolved.map(\.id) == [3, 5])
        #expect(panel.threads.all.map(\.id) == [2, 4, 1, 3, 5])
        #expect(panel.threads.unresolvedCount == 3)
        #expect(panel.threads.contains(5) && !panel.threads.contains(6))
        // Sam's reply came after you last looked.
        #expect(panel.threads.waitingOnYou.first?.isNew == true)
        #expect(panel.threads.waitingOnYou.first?.date == t(-2 * hour))

        // Seen since, it still waits on you, no longer as new.
        let seen = try self.panel(record(pr, threads: threads), seen: t(-hour))
        #expect(seen.threads.waitingOnYou.map(\.id) == [2])
        #expect(seen.threads.waitingOnYou.first?.isNew == false)
    }

    /// A thread you change in the details stays where it was as you first did, with the open ones and with those that wait
    /// on you, however it stands now: replied to, resolved, or reactivated; the others go where they stand.
    @Test func aThreadYouChangeStaysWhereItWas() throws {
        let threads = [
            // Answered: it waited on you before.
            ReviewThread(id: 2, filePath: "/src/Cart.cs", line: 40, comments: [
                comment(1, me, "Is a minute enough?", at: t(-6 * hour)), comment(2, People.sam, "Make it two.", at: t(-2 * hour)),
                comment(3, me, "Done.", at: t(-minute)),
            ]),
            // Resolved: it was open.
            ReviewThread(id: 4, status: "fixed", filePath: "/src/Cart.cs", line: 12, comments: [
                comment(1, People.alex, "Check the cache?", at: t(-3 * hour)),
            ]),
            // Reactivated: it was resolved.
            ReviewThread(id: 5, status: "active", filePath: "/src/Cart.cs", line: 90, comments: [
                comment(1, People.alex, "Typo here.", at: t(-5 * day)), comment(2, me, "Fixed it.", at: t(-4 * day)),
            ]),
            ReviewThread(id: 6, status: "closed", comments: [comment(1, People.priya, "Nit.", at: t(-5 * day))]),
        ]
        // Seen an hour ago: Alex's comment in the thread resolved since doesn't wait on you.
        let panel = try panel(record(makePR(created: t(-6 * day)), threads: threads), seen: t(-hour))
        // As they stand.
        let standing = panel.threads.arranged()
        #expect(standing.open.flatMap(\.threads).map(\.id) == [2, 5])
        #expect(standing.resolved.flatMap(\.threads).map(\.id) == [6, 4])

        let held = panel.threads.arranged(holding: [
            2: .init(placement: .waitingOnYou, date: t(-2 * hour)), 4: .init(placement: .open, date: t(-3 * hour)),
            5: .init(placement: .resolved, date: t(-4 * day)),
        ])
        // 2 still first, as it waited on you; 4 among the open ones, by its line.
        #expect(held.open.flatMap(\.threads).map(\.id) == [2, 4])
        #expect(held.resolved.flatMap(\.threads).map(\.id) == [6, 5])
        // Each says how it stands now.
        #expect(held.open.flatMap(\.threads).map(\.waitsOnYou) == [false, false])
        #expect(held.open.flatMap(\.threads).last?.isResolved == true)
        #expect(panel.threads.openByFile == standing.open)
        #expect(panel.threads.resolvedByFile == standing.resolved)
    }

    /// Among the threads on the pull request itself, which have no line, the latest show first: one you reply to stays where
    /// it was as you first changed it, though it's the latest now, and doesn't wait on you.
    @Test func aThreadYouReplyToStaysWhereItWasAmongTheLatest() throws {
        let before = [
            ReviewThread(id: 7, comments: [comment(1, People.alex, "Release notes?", at: t(-hour))]),
            ReviewThread(id: 8, comments: [comment(1, People.priya, "Who reviews the SQL?", at: t(-2 * hour))]),
            ReviewThread(id: 9, comments: [comment(1, People.alex, "Rename it?", at: t(-3 * hour))]),
        ]
        let open = try panel(record(makePR(created: t(-day)), threads: before), seen: t(-hour)).threads.arranged().open.flatMap(\.threads)
        #expect(open.map(\.id) == [7, 8, 9])
        #expect(open.map(\.waitsOnYou) == [true, true, true])
        let held = PullRequestPanel.Thread.Held(try #require(open.first { $0.id == 8 }))

        // You replied to 8: it's the latest now, and doesn't wait on you.
        var after = before
        after[1].comments.append(comment(2, me, "I will.", at: t(-minute)))
        let replied = try panel(record(makePR(created: t(-day)), threads: after), seen: t(-hour)).threads
        #expect(replied.arranged().open.flatMap(\.threads).map(\.id) == [7, 9, 8])
        #expect(replied.arranged(holding: [8: held]).open.flatMap(\.threads).map(\.id) == [7, 8, 9])
    }

    /// A comment that needs you in a thread resolved since, as a new one in a resolved thread does, waits on you there too.
    @Test func aResolvedThreadWithACommentThatNeedsYouWaitsOnYou() throws {
        let thread = ReviewThread(id: 9, status: "fixed", comments: [
            comment(1, me, "Fixed.", at: t(-3 * hour)), comment(2, People.sam, "Not quite: the total is still off.", at: t(-hour)),
        ])
        let panel = try panel(record(makePR(), threads: [thread]))
        #expect(panel.threads.waitingOnYou.map(\.id) == [9])
        #expect(panel.threads.waitingOnYou.first?.isResolved == true)
        #expect(panel.threads.resolved.isEmpty)
    }

    /// Seen since, a new comment in a resolved thread doesn't wait on you anymore, unless the details tell what needs you
    /// as when they showed it.
    @Test func whatNeedsYouCanBeAsTheDetailsShowedIt() throws {
        let thread = ReviewThread(id: 9, status: "fixed", comments: [
            comment(1, me, "Fixed.", at: t(-3 * hour)), comment(2, People.sam, "Not quite: the total is still off.", at: t(-2 * hour)),
        ])
        let record = record(makePR(), threads: [thread])
        let seen = try snapshot(record, seen: t(-hour))
        let now = PullRequestPanel(seen, record: record)
        #expect(now.threads.resolved.map(\.id) == [9])
        let shown = PullRequestPanel(seen, record: record, events: try snapshot(record).pendingEvents)
        #expect(shown.threads.waitingOnYou.map(\.id) == [9])
        #expect(shown.threads.waitingOnYou.first?.isNew == true)
        // The rest is as its row has it.
        #expect(shown.sentence == now.sentence && shown.readiness == now.readiness)
    }

    @Test func aThreadSaysWhereItIsAndHowItStands() {
        func thread(_ path: String?, _ line: Int?, status: String? = "active") -> PullRequestPanel.Thread {
            PullRequestPanel.Thread(
                thread: ReviewThread(id: 1, status: status, filePath: path, line: line, comments: [comment(1, People.sam, at: t(0))]),
                waitsOnYou: false, isNew: false
            )
        }
        #expect(thread("/src/PaymentsClient.cs", 88).place == "PaymentsClient.cs:88")
        #expect(thread("/src/PaymentsClient.cs", nil).place == "PaymentsClient.cs")
        #expect(thread(nil, nil).place == nil)
        let statuses = ["active", "pending", "fixed", "wontFix", "closed", "byDesign", "unknown"].map { thread(nil, nil, status: $0).status }
        #expect(statuses == ["Active", "Pending", "Resolved", "Won't fix", "Closed", "By design", nil])
        #expect(thread(nil, nil, status: nil).status == nil)
    }

    /// The threads of a pull request you review: only what's said to you waits on you.
    @Test func onAReviewOnlyWhatsSaidToYouWaitsOnYou() throws {
        let pr = makePR(author: People.alex, reviewers: [Reviewer(person: me, vote: .none)])
        let threads = [
            ReviewThread(id: 1, comments: [comment(1, People.alex, "@Robin could you check this?", at: t(-hour), mentions: [me])]),
            ReviewThread(id: 2, comments: [comment(1, People.sam, "Looks good to me.", at: t(-2 * hour))]),
        ]
        let panel = try panel(record(pr, role: .reviewer, threads: threads))
        #expect(panel.threads.waitingOnYou.map(\.id) == [1])
        #expect(panel.threads.open.map(\.id) == [2])
        #expect(!panel.isYours)
        #expect(panel.author == "Alex Kim")
        // What's left is for your own pull requests.
        #expect(panel.readiness == nil)
    }

    // MARK: Checks

    @Test func buildsAndChecksSayWhatFailedFirstWhereAndWhichRun() throws {
        let failure = PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed in CartTests.")
        let checks = [
            Check(name: "shop-web CI", kind: .build, state: .passed, completedAt: t(-3 * hour), buildId: 501),
            Check(name: "shop-web lint", kind: .build, state: .failed, isBlocking: false, completedAt: t(-2 * hour), buildId: 502),
            Check(name: "security/scan", kind: .status, state: .running),
            Check(name: "shop-web tests", kind: .build, state: .failed, completedAt: t(-4 * hour), buildId: 503, failure: failure),
            Check(name: "Old build", kind: .build, state: .notApplicable),
            Check(name: "Minimum number of reviewers", kind: .reviewers, state: .pending, minimumApprovers: 2),
        ]
        let panel = try panel(record(makePR(), checks: checks))
        // The required one that failed, then the optional one, then what's running, then what passed. Policies that
        // don't apply, and those that aren't builds or checks, aren't.
        #expect(panel.checks.map(\.run.name) == ["shop-web tests", "shop-web lint", "security/scan", "shop-web CI"])
        #expect(panel.checks.map(\.isRequired) == [true, false, true, true])
        let failed = try #require(panel.checks.first)
        #expect(failed.run.state == .failing)
        #expect(failed.run.status == "Failed at Run unit tests")
        #expect(failed.run.detail == "2 tests failed in CartTests.")
        #expect(failed.run.url == ADOEndpoint.buildPage(organization: "contoso", project: "Shop", buildId: 503))
        #expect(failed.buildId == 503)
        #expect(failed.check?.name == "shop-web tests")
        #expect(Set(panel.checks.map(\.id)).count == panel.checks.count)
        #expect(panel.checksKnown)

        // Two of the same name, each its own.
        let twins = try self.panel(record(makePR(), checks: [
            Check(name: "Status check", kind: .status, state: .pending), Check(name: "Status check", kind: .status, state: .passed),
        ]))
        #expect(twins.checks.map(\.id) == ["check Status check", "check Status check 2"])
        // Even with one named as the second would be.
        let lints = try self.panel(record(makePR(), checks: ["lint", "lint", "lint 2"].map {
            Check(name: $0, kind: .status, state: .pending)
        }))
        #expect(Set(lints.checks.map(\.id)).count == 3)
        #expect(lints.checks.map(\.id) == ["check lint", "check lint 2", "check lint 2 2"])

        // Without its policies, nobody can tell.
        let unknown = try self.panel(record(makePR(), checksKnown: false))
        #expect(!unknown.checksKnown)
        #expect(unknown.checks.isEmpty)
    }

    @Test func aMergedPullRequestHasThePipelinesThatRanAfterIt() throws {
        let pr = makePR(status: .completed, closed: t(-hour))
        var merged = record(pr, details: false)
        merged.merge = MergePipelines(
            pullRequest: pr.key, title: pr.title, targetBranch: "main", mergedAt: t(-hour), url: pr.webURL,
            pipelines: [PipelineStatus(
                pipeline: PipelineRef(organization: "contoso", projectId: "p1", projectName: "Shop", definitionId: 9, name: "shop-web CD"),
                runs: [PipelineRun(id: 77, organization: "contoso", projectName: "Shop", number: "1", status: .failed, trigger: .push,
                                   branch: "main", queuedAt: t(-50 * minute), startedAt: t(-49 * minute), finishedAt: t(-40 * minute))]
            )],
            isFollowing: true
        )
        let panel = try panel(merged)
        #expect(panel.checks.count == 1)
        let line = try #require(panel.checks.first)
        #expect(line.check == nil && !line.isRequired)
        #expect(line.run.name == "shop-web CD")
        #expect(line.run.state == .failing)
        #expect(line.buildId == 77)
        // Its threads and policies weren't read, and nothing's left of a closed one.
        #expect(!panel.hasDetails && panel.isClosed)
        #expect(panel.threads.isEmpty)
        #expect(panel.readiness == nil)

        // As its details kept it from before it merged, when its project didn't let you read its policies: what ran
        // after it shows all the same.
        var kept = merged
        kept.details = makeDetails(for: pr, checksKnown: false, lastActivity: t(-2 * hour))
        let unreadable = try self.panel(kept)
        #expect(!unreadable.checksKnown && unreadable.checks.map(\.buildId) == [77])
        #expect(!unreadable.checksUnknown)
        // Open, nobody can tell its builds and checks.
        #expect(try self.panel(record(makePR(), checksKnown: false)).checksUnknown)
    }

    // MARK: Reviewers

    @Test func theReviewersItRequiresComeFirstWithHowEachVoted() throws {
        let team = Person(id: "66666666-6666-6666-6666-666666666666", name: "[Shop]\\Shop Team")
        let pr = makePR(author: People.alex, reviewers: [
            Reviewer(person: People.priya, vote: .approved),
            Reviewer(person: me, vote: .none, hasDeclined: true),
            Reviewer(person: team, vote: .none, isRequired: true, isGroup: true),
            Reviewer(person: People.sam, vote: .waitingForAuthor, isRequired: true),
            Reviewer(person: People.bot, vote: .rejected),
            Reviewer(person: Person(id: "77777777-7777-7777-7777-777777777777", name: "Chen Wei"), vote: .approvedWithSuggestions),
        ])
        let panel = try panel(record(pr, role: .reviewer))
        #expect(panel.reviewers.map(\.name) == ["Sam Rivera", "Shop Team", "Chen Wei", "Priya Shah", "Robin Diaz", "Shop Build Service"])
        #expect(panel.reviewers.map(\.verdict)
            == ["Wants changes", "No vote yet", "Approved with suggestions", "Approved", "Declined", "Rejected"])
        #expect(panel.reviewers.map(\.isRequired) == [true, true, false, false, false, false])
        #expect(panel.reviewers.filter(\.isYou).map(\.name) == ["Robin Diaz"])
        #expect(panel.reviewers.filter(\.isGroup).map(\.name) == ["Shop Team"])
    }

    // MARK: Where it stands

    @Test func itSaysWhereItStandsAsItsRowDoes() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.priya, vote: .approved)], autoComplete: true)
        let record = record(pr, checks: [Check(name: "shop-web CI", kind: .build, state: .passed, completedAt: t(-hour))])
        let row = try snapshot(record)
        let panel = PullRequestPanel(row, record: record)
        #expect(panel.branch == "fix-total → main")
        #expect(panel.isYours)
        #expect(panel.author == "Robin Diaz")
        #expect(panel.sentence == "Completing automatically: Approved by Priya Shah")
        #expect(panel.since == row.since)
        #expect(panel.merge == "Completes by itself once it can")
        #expect(panel.readiness == row.readiness)
        #expect(panel.hasDetails && !panel.isClosed)

        // Without its record, what its row says.
        let bare = PullRequestPanel(row, record: nil)
        #expect(bare.branch == nil && bare.merge == nil && !bare.hasDetails && !bare.isClosed && bare.reviewers.isEmpty)
        #expect(bare.sentence == panel.sentence)
    }

    @Test func whatsLeftLeadsToThePartItsAbout() {
        func section(_ kind: PRReadiness.Item.Kind) -> PullRequestPanel.Section? {
            PullRequestPanel.section(of: PRReadiness.Item(kind: kind, state: nil, label: ""))
        }
        #expect(section(.comments) == .comments)
        #expect(section(.builds) == .checks)
        #expect(section(.checks) == .checks)
        #expect(section(.approvals) == .reviewers)
        #expect(section(.requiredReviewers) == .reviewers)
        #expect(section(.changesRequested) == .reviewers)
        for kind: PRReadiness.Item.Kind in [.draft, .workItems, .policy, .conflicts, .mergeFailed, .unreadablePolicies] {
            #expect(section(kind) == nil, "\(kind)")
        }
    }

    // MARK: The demo

    /// The demo's pull requests have what the details show: threads on lines of code and on the whole pull request, open
    /// and resolved, a failed build, and approvals.
    @Test func theDemosPullRequestsFillTheirDetails() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let records = DemoData.records(now: now)
        func panel(_ number: Int) throws -> PullRequestPanel {
            let record = try #require(records.first { $0.id.number == number })
            let row = try #require(PRClassifier.snapshot(
                for: record, seenCutoff: seen.cutoff(for: record.id), dismissedCutoff: seen.dismissedCutoff(for: record.id), now: now
            ))
            return PullRequestPanel(row, record: record)
        }

        let retry = try panel(4102)
        #expect(retry.threads.waitingOnYou.map(\.id) == [11])
        #expect(retry.threads.waitingOnYou.first?.place == "PaymentsClient.cs:88")
        // Priya's suggested change, which you said you'd take: open, and not waiting on you.
        #expect(retry.threads.open.map(\.id) == [18])
        #expect(retry.threads.open.first?.place == "RetryOptions.cs:12")
        #expect(retry.threads.resolved.map(\.id) == [17, 14, 16, 13, 15])
        #expect(retry.threads.resolved.map(\.place)
            == ["PaymentsClientTests.cs:13", "RetryPolicy.cs:12", "PaymentsClient.cs:46", "PaymentsClient.cs:41", nil])
        #expect(retry.threads.resolved.map(\.status) == ["Closed", "Won't fix", "Resolved", "Resolved", "Closed"])
        #expect(retry.reviewers.map(\.name) == ["Sam Rivera", "Priya Shah"])
        #expect(retry.reviewers.map(\.verdict) == ["No vote yet", "Approved"])
        #expect(retry.branch == "payments-retry → main")

        let delivery = try panel(4088)
        #expect(delivery.checks.first?.run.status == "Failed at Run unit tests")
        #expect(delivery.checks.first?.run.detail == "2 tests failed in DeliveryEstimateTests.")
        #expect(delivery.threads.resolved.map(\.id) == [41, 43])

        let coupons = try panel(4091)
        #expect(coupons.threads.resolved.map(\.id) == [68, 67])
        #expect(coupons.threads.resolved.map(\.place) == [nil, "CouponService.cs:118"])
        #expect(coupons.readiness?.isReady == true)
    }
}
