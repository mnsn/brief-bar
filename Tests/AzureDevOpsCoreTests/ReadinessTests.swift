import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// What's left before you can complete one of your pull requests, and the order a list by date shows them in.
@Suite struct ReadinessTests {
    private let me = People.me

    private func record(_ pr: PullRequest, checks: [Check] = [], checksKnown: Bool = true, threads: [ReviewThread] = []) -> PRRecord {
        PRRecord(pullRequest: pr, role: .author, details: makeDetails(for: pr, checks: checks, checksKnown: checksKnown, threads: threads,
                                                                     lastActivity: t(-hour)), me: me.id)
    }

    private func readiness(_ pr: PullRequest, checks: [Check] = [], checksKnown: Bool = true, threads: [ReviewThread] = []) throws -> PRReadiness {
        try #require(PRReadiness(record(pr, checks: checks, checksKnown: checksKnown, threads: threads)))
    }

    private func snapshot(_ record: PRRecord) throws -> PRSnapshot {
        try #require(PRClassifier.snapshot(for: record, seenCutoff: t(-3 * day), dismissedCutoff: t(-3 * day), now: t(0)))
    }

    /// "✋ Resolve 1 comment", "◷ 1 of 2 approvals"…
    private func said(_ readiness: PRReadiness) -> [String] {
        readiness.items.map { item in
            let mark = switch item.state {
            case .done?: "✓"
            case .failing?: "✕"
            case .needsYou?: "✋"
            case .running?: "↻"
            case nil: item.isRequired ? "◷" : "·"
            }
            return "\(mark) \(item.label)"
        }
    }

    private let minimumPolicy = { (state: Check.State, count: Int) in
        Check(name: "Minimum number of reviewers", kind: .reviewers, state: state, minimumApprovers: count)
    }
    private let commentPolicy = { (state: Check.State) in Check(name: "Comment requirements", kind: .requirement, state: state) }
    private let workItemPolicy = { (state: Check.State) in Check(name: "Work item linking", kind: .requirement, state: state) }
    private let build = { (state: Check.State) in Check(name: "web-ci", kind: .build, state: state) }
    private let mergeStrategy = Check(name: "Require a merge strategy", kind: .completion, state: .pending)

    private func thread(_ id: Int, status: String = "active") -> ReviewThread {
        ReviewThread(id: id, status: status, comments: [comment(1, People.sam, "Cap it", at: t(-2 * hour))])
    }

    // MARK: What's left

    @Test func whatWaitsOnYouComesFirstThenOthersThenWhatsDone() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.sam, vote: .none, isRequired: true)])
        let ready = try readiness(pr, checks: [build(.passed), minimumPolicy(.pending, 2), commentPolicy(.pending), workItemPolicy(.passed), mergeStrategy],
                                  threads: [thread(1), thread(2, status: "fixed")])
        #expect(said(ready) == ["✋ Resolve 1 comment", "◷ 1 of 2 approvals", "◷ Waiting on Sam", "✓ Build passed", "✓ Work item linked"])
        #expect(!ready.isReady)
        #expect(ready.isCurrent)
        #expect(ready.left.map(\.kind) == [.comments, .approvals, .requiredReviewers])
        // Who approved, and who it requires, for the tooltip.
        #expect(ready.items.first { $0.kind == .approvals }?.detail == "Approved by Priya Shah")
        #expect(ready.items.first { $0.kind == .requiredReviewers }?.detail == "Required: Sam Rivera")
        // The merge strategy is chosen as it completes: it isn't something left.
        #expect(!ready.items.contains { $0.label.contains("merge strategy") })
    }

    @Test func everythingDoneIsReady() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved), Reviewer(person: People.priya, vote: .approvedWithSuggestions)])
        let record = record(pr, checks: [build(.passed), minimumPolicy(.passed, 2), commentPolicy(.passed), workItemPolicy(.passed), mergeStrategy])
        let ready = try #require(PRReadiness(record))
        #expect(said(ready) == ["✓ Approved", "✓ Build passed", "✓ Comments resolved", "✓ Work item linked"])
        #expect(ready.isReady)
        #expect(ready.left.isEmpty)
        let row = try snapshot(record)
        #expect(row.group == .ready)
        #expect(row.readiness == ready)
    }

    @Test func failuresAndWhatYouHaveToDo() throws {
        var pr = makePR(draft: true, merge: "conflicts")
        pr.reviewers = [Reviewer(person: People.sam, vote: .waitingForAuthor)]
        let failure = PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed in CheckoutTests.")
        let failed = Check(name: "web-ci", kind: .build, state: .failed, buildId: 41, failure: failure)
        let ready = try readiness(pr, checks: [failed, Check(name: "scan", kind: .status, state: .running), minimumPolicy(.pending, 1)])
        #expect(said(ready) == [
            "✋ Publish the draft", "✋ Sam wants changes", "✕ Build failed", "✕ Merge conflicts", "↻ Check running", "◷ Not approved yet",
        ])
        #expect(ready.items.first { $0.kind == .builds }?.detail == "web-ci · Run unit tests: 2 tests failed in CheckoutTests.")
        #expect(ready.items.first { $0.kind == .conflicts }?.detail == "fix-total into main")
        #expect(ready.items.first { $0.kind == .changesRequested }?.detail == "Changes requested by Sam Rivera")
    }

    @Test func builds() throws {
        func builds(_ checks: [Check]) throws -> String? {
            let item = try readiness(makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)]), checks: checks)
                .items.first { $0.kind == .builds }
            return item.map { "\($0.label) | \($0.detail ?? "")" }
        }
        let api = { (state: Check.State) in Check(name: "api-ci", kind: .build, state: state) }
        #expect(try builds([build(.passed)]) == "Build passed | web-ci")
        #expect(try builds([build(.passed), api(.passed)]) == "Builds passed | web-ci, api-ci")
        #expect(try builds([build(.failed), api(.failed)]) == "2 builds failed | web-ci, api-ci")
        // The worst one says it.
        #expect(try builds([build(.expired), api(.running)]) == "Build expired | web-ci · queue it again")
        #expect(try builds([build(.notRun), api(.passed)]) == "Build hasn't run | web-ci · queue it")
        #expect(try builds([build(.running), api(.passed)]) == "Build running | web-ci")
        #expect(try builds([build(.queued)]) == "Build queued | web-ci")
        // An optional build, or one that doesn't apply, isn't something left.
        #expect(try builds([Check(name: "perf", kind: .build, state: .failed, isBlocking: false), api(.notApplicable)]) == nil)

        func checks(_ states: [Check.State]) throws -> String? {
            let statuses = states.enumerated().map { Check(name: "status \($0.offset)", kind: .status, state: $0.element) }
            guard let item = try readiness(makePR(), checks: statuses).items.first(where: { $0.kind == .checks }) else { return nil }
            return "\(item.state?.rawValue ?? "nil") \(item.label)"
        }
        #expect(try checks([.failed, .passed]) == "failing Check failed")
        #expect(try checks([.pending, .running]) == "running 2 checks running")
        #expect(try checks([.passed, .passed]) == "done Checks passed")
    }

    @Test func reviewers() throws {
        func approvals(_ reviewers: [Reviewer], _ checks: [Check] = []) throws -> [String] {
            try said(readiness(makePR(reviewers: reviewers), checks: checks)).filter { !$0.contains("Build") }
        }
        let priya = Reviewer(person: People.priya, vote: .approved)
        let sam = Reviewer(person: People.sam, vote: .approved)
        // Without reviewer policies, someone's approval.
        #expect(try approvals([]) == ["◷ Not approved yet"])
        #expect(try approvals([priya]) == ["✓ Approved"])
        // With a minimum, how many of how many.
        #expect(try approvals([priya], [minimumPolicy(.pending, 3)]) == ["◷ 1 of 3 approvals"])
        #expect(try approvals([], [minimumPolicy(.pending, 1)]) == ["◷ Not approved yet"])
        #expect(try approvals([priya], [minimumPolicy(.passed, 1)]) == ["✓ Approved"])
        // Enough approved, but not as the policy counts them; and the one that isn't met says how many.
        #expect(try approvals([priya, sam], [minimumPolicy(.pending, 2)]) == ["◷ Approval policy pending"])
        #expect(try approvals([priya], [minimumPolicy(.passed, 1), minimumPolicy(.pending, 2)]) == ["◷ 1 of 2 approvals"])

        // Who wants changes, by first name.
        #expect(try approvals([Reviewer(person: People.sam, vote: .rejected), priya]) == ["✋ Sam rejected it", "✓ Approved"])
        let several = try readiness(makePR(reviewers: [Reviewer(person: People.sam, vote: .rejected), Reviewer(person: People.alex, vote: .waitingForAuthor)]))
        #expect(said(several).first == "✋ Changes requested")
        #expect(several.items.first?.detail == "Rejected by Sam Rivera · Changes requested by Alex Kim")

        // A reviewer it requires, even one who declined; a team, as its policy says.
        let team = Person(id: "66666666-6666-6666-6666-666666666666", name: "[Shop]\\Checkout Team")
        let required = Check(name: "Required reviewers", kind: .reviewers, state: .pending)
        #expect(try approvals([priya, Reviewer(person: People.alex, vote: .none, isRequired: true, hasDeclined: true)])
            == ["◷ Waiting on Alex", "✓ Approved"])
        #expect(try approvals([priya, Reviewer(person: team, vote: .none, isRequired: true, isGroup: true)], [required])
            == ["◷ Waiting on Checkout Team", "✓ Approved"])
        #expect(try approvals([priya, Reviewer(person: team, vote: .approved, isRequired: true, isGroup: true)],
                              [Check(name: "Required reviewers", kind: .reviewers, state: .passed)])
            == ["✓ Approved", "✓ Required reviewers"])
        // Its policy passed: the team's vote is up to it.
        #expect(try approvals([priya, Reviewer(person: team, vote: .none, isRequired: true, isGroup: true)],
                              [Check(name: "Required reviewers", kind: .reviewers, state: .passed)])
            == ["✓ Approved", "✓ Required reviewers"])
        // Two policies, each requiring a team: only the team whose policy is pending is waited on, whatever the other's
        // vote. The policy names it by its ID, in any case.
        let payments = Person(id: "77777777-7777-7777-7777-777777777777", name: "[Shop]\\Payments Team")
        let teams = [Reviewer(person: team, vote: .none, isRequired: true, isGroup: true),
                     Reviewer(person: payments, vote: .none, isRequired: true, isGroup: true)]
        let policies = [Check(name: "Required reviewers", kind: .reviewers, state: .passed, reviewerIds: [team.id]),
                        Check(name: "Required reviewers", kind: .reviewers, state: .pending, reviewerIds: [payments.id.uppercased()])]
        #expect(try approvals([priya] + teams, policies) == ["◷ Waiting on Payments Team", "✓ Approved"])
        #expect(try approvals([Reviewer(person: People.sam, vote: .none, isRequired: true), Reviewer(person: People.alex, vote: .none, isRequired: true)])
            == ["◷ Not approved yet", "◷ Waiting on 2 reviewers"])
        // With a reviewer policy but no minimum, approvals aren't required, but they're said once there are some.
        #expect(try approvals([], [Check(name: "Proof Of Presence", kind: .reviewers, state: .pending)]) == ["◷ Proof Of Presence"])
    }

    @Test func openComments() throws {
        let open = [thread(1), thread(2, status: "pending"), thread(3, status: "closed"), thread(4, status: "wontFix")]
        let approved = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        #expect(said(try readiness(approved, checks: [commentPolicy(.pending)], threads: open)).first == "✋ Resolve 2 comments")
        #expect(said(try readiness(approved, checks: [commentPolicy(.pending)])).first == "✋ Resolve comments")
        #expect(said(try readiness(approved, checks: [commentPolicy(.passed)], threads: open)).last == "✓ Comments resolved")

        // Without a policy that requires resolving them, open comments are said, but don't hold it up.
        let unrequired = try readiness(approved, threads: open)
        #expect(said(unrequired) == ["· 2 open comments", "✓ Approved"])
        #expect(unrequired.isReady)
        #expect(try readiness(approved, threads: [thread(3, status: "closed")]).items.allSatisfy { $0.kind != .comments })
    }

    @Test func otherPolicies() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        let ready = try readiness(pr, checks: [
            workItemPolicy(.pending), Check(name: "File size restriction", kind: .requirement, state: .pending),
            Check(name: "File size restriction", kind: .requirement, state: .passed), Check(name: "Path length", kind: .requirement, state: .passed),
        ])
        #expect(said(ready) == ["✋ Link a work item", "◷ File size restriction", "✓ Approved", "✓ Path length"])
    }

    /// When nobody can tell, it isn't ready; and once it changed, by a push or a vote, until its policies are read again.
    @Test func onlyWhatsKnownAndCurrentIsReady() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        let unreadable = try readiness(pr, checksKnown: false)
        #expect(said(unreadable) == ["◷ Can't read its policies", "✓ Approved"])
        #expect(!unreadable.isReady)

        let details = makeDetails(for: pr, checks: [build(.passed), minimumPolicy(.passed, 1)], lastActivity: t(-hour))
        var pushed = pr
        pushed.sourceCommit = "abd"
        let outdated = try #require(PRReadiness(PRRecord(pullRequest: pushed, role: .author, details: details, me: me.id)))
        #expect(!outdated.isCurrent)
        #expect(!outdated.isReady)
        #expect(outdated.left.isEmpty)
    }

    @Test func onlyYourOpenPullRequestsOnceRead() throws {
        let pr = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .none)])
        #expect(PRReadiness(PRRecord(pullRequest: pr, role: .reviewer, details: makeDetails(for: pr), me: me.id)) == nil)
        #expect(PRReadiness(PRRecord(pullRequest: makePR(), role: .author, me: me.id)) == nil)
        let completed = makePR(status: .completed, closed: t(-hour))
        #expect(PRReadiness(PRRecord(pullRequest: completed, role: .author, details: makeDetails(for: completed), me: me.id)) == nil)

        let review = try snapshot(PRRecord(pullRequest: pr, role: .reviewer, details: makeDetails(for: pr, lastActivity: t(-hour)), me: me.id))
        #expect(review.readiness == nil)
        #expect(review.createdAt == pr.createdAt)
    }

    /// The list says it's ready to complete exactly when nothing it requires is left.
    @Test func readyAsTheListSaysIt() throws {
        let sam = Reviewer(person: People.sam, vote: .approved)
        let reviewerSets: [[Reviewer]] = [
            [], [sam], [sam, Reviewer(person: People.priya, vote: .none, isRequired: true)],
            [sam, Reviewer(person: People.alex, vote: .waitingForAuthor)],
            [sam, Reviewer(person: Person(id: "team", name: "[Shop]\\Team"), vote: .none, isRequired: true, isGroup: true)],
        ]
        let checkSets: [[Check]] = [
            [], [build(.passed)], [build(.failed)], [build(.running)], [build(.expired)], [build(.notRun)],
            [build(.passed), minimumPolicy(.passed, 1)], [build(.passed), minimumPolicy(.pending, 2)],
            [build(.passed), commentPolicy(.pending)], [build(.passed), commentPolicy(.passed), workItemPolicy(.passed)],
            [Check(name: "scan", kind: .status, state: .pending)], [Check(name: "Required reviewers", kind: .reviewers, state: .passed)],
            [Check(name: "Required reviewers", kind: .reviewers, state: .pending)],
        ]
        for reviewers in reviewerSets {
            for checks in checkSets {
                for merge in ["succeeded", "conflicts", "failure", "rejectedByPolicy"] {
                    for known in [true, false] {
                        let pr = makePR(reviewers: reviewers, merge: merge, autoComplete: merge == "succeeded" && known)
                        let row = try snapshot(record(pr, checks: known ? checks : [], checksKnown: known))
                        let ready = try #require(row.readiness)
                        #expect((row.group == .ready) == ready.isReady, "\(reviewers.map(\.vote)) \(checks.map(\.name)) \(merge) \(known)")
                    }
                }
            }
        }

        // Something new that needs you, or two weeks without activity, comes first: nothing's left all the same.
        let approved = makePR(reviewers: [sam])
        let passing = [build(.passed), minimumPolicy(.passed, 1)]
        let commented = record(approved, checks: passing, threads: [thread(1)])
        #expect(try snapshot(commented).group == .needsYou)
        #expect(try snapshot(commented).readiness?.isReady == true)
        var quiet = record(makePR(created: t(-40 * day), reviewers: [sam]), checks: passing)
        quiet.details?.lastActivity = t(-30 * day)
        let idle = try #require(PRClassifier.snapshot(for: quiet, seenCutoff: t(-3 * day), dismissedCutoff: t(-3 * day), now: t(0)))
        #expect(idle.group == .idle)
        #expect(idle.readiness?.isReady == true)
    }

    // MARK: Required reviewers in the list

    /// A merge Azure DevOps couldn't make, for something other than conflicts, holds it up as conflicts do, however its
    /// policies stand.
    @Test func aMergeAzureDevOpsCouldntMakeIsFailing() throws {
        let approved = [Reviewer(person: People.sam, vote: .approved)]
        let passing = [build(.passed), minimumPolicy(.passed, 1)]
        let cases = [
            ("failure", "Merge failed", "Azure DevOps couldn't merge fix-total into main"),
            ("rejectedByPolicy", "Merge rejected", "A policy rejected merging fix-total into main"),
        ]
        for (merge, headline, detail) in cases {
            let failed = record(makePR(reviewers: approved, merge: merge), checks: passing)
            let row = try snapshot(failed)
            #expect(row.group == .failing)
            #expect(row.reason == .mergeFailed)
            #expect(row.headline == headline)
            #expect(row.detail == detail)
            let ready = try #require(row.readiness)
            #expect(said(ready) == ["✕ \(headline)", "✓ Approved", "✓ Build passed"])
            #expect(ready.items.first?.detail == detail)
            #expect(!ready.isReady)
            #expect(PullRequestWait.waiting(on: row, record: failed)?.text == "you, to fix !7's merge")
            #expect(Brief.item(row, reader: nil).sentence == "“Fix the checkout total” can't be merged.")
            #expect(PullRequestStory.merge(failed.pullRequest) == headline)
        }
        // After a failed build, its merge is said too, as conflicts are.
        let both = record(makePR(reviewers: approved, merge: "failure"), checks: [build(.failed)])
        #expect(try snapshot(both).detail == "web-ci · merge failed")
        // Merges still being checked, or never checked, aren't failures.
        for merge in ["queued", "notSet"] {
            #expect(try snapshot(record(makePR(reviewers: approved, merge: merge), checks: passing)).group == .ready)
        }
    }

    @Test func aRequiredReviewerWhoHasntApprovedHoldsItUp() throws {
        let checks = [build(.passed), minimumPolicy(.passed, 1)]
        let pr = makePR(reviewers: [Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.sam, vote: .none, isRequired: true)])
        let row = try snapshot(record(pr, checks: checks))
        #expect(row.group == .waiting)
        #expect(row.reason == .waitingForReviewers)
        #expect(row.detail == "Approved by Priya Shah · Sam Rivera is required")
        #expect(PullRequestWait.waiting(on: row, record: record(pr, checks: checks))?.text == "Sam Rivera, to review your !7")

        // Two, and one who declined.
        let two = makePR(reviewers: [
            Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.sam, vote: .none, isRequired: true),
            Reviewer(person: People.alex, vote: .none, isRequired: true, hasDeclined: true),
        ])
        #expect(try snapshot(record(two, checks: checks)).detail == "Approved by Priya Shah · Sam Rivera and Alex Kim are required")

        // It waits on whoever it requires, even one who declined, rather than on someone whose vote can't unblock it.
        let declined = record(makePR(reviewers: [
            Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.sam, vote: .none),
            Reviewer(person: People.alex, vote: .none, isRequired: true, hasDeclined: true),
        ]), checks: checks)
        #expect(PullRequestWait.waiting(on: try snapshot(declined), record: declined)?.text == "Alex Kim, to review your !7")

        // Once they approved, it's ready.
        let approved = makePR(reviewers: [Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.sam, vote: .approved, isRequired: true)])
        #expect(try snapshot(record(approved, checks: checks)).group == .ready)
        // A team counts as its policy says.
        let team = makePR(reviewers: [
            Reviewer(person: People.priya, vote: .approved), Reviewer(person: Person(id: "team", name: "Team"), vote: .none, isRequired: true, isGroup: true),
        ])
        #expect(try snapshot(record(team, checks: checks + [Check(name: "Required reviewers", kind: .reviewers, state: .passed)])).group == .ready)
    }

    // MARK: Order

    @Test func ordersByWhenEachWasCreated() throws {
        func item(_ number: Int, _ group: PRGroup, created: Date?, since: Date) -> PRSnapshot {
            var snapshot = try! #require(PRClassifier.snapshot(
                for: PRRecord(pullRequest: makePR(number), role: .author, me: me.id), seenCutoff: t(-3 * day), dismissedCutoff: t(-3 * day), now: t(0)
            ))
            snapshot.group = group
            snapshot.createdAt = created
            snapshot.since = since
            return snapshot
        }
        let items = [
            item(1, .idle, created: t(-9 * day), since: t(-1)), item(2, .needsYou, created: t(-2 * day), since: t(-5)),
            item(3, .ready, created: t(-5 * day), since: t(-50)), item(4, .waiting, created: nil, since: t(0)),
            item(5, .failing, created: t(-hour), since: t(-hour)), item(6, .done, created: t(-2 * day), since: t(-10)),
        ]
        #expect(PROrdering.sorted(items.shuffled(), by: .newestFirst).map(\.key.number) == [5, 6, 2, 3, 1, 4])
        #expect(PROrdering.sorted(items.shuffled(), by: .oldestFirst).map(\.key.number) == [1, 3, 2, 6, 5, 4])
        #expect(PROrdering.sorted(items.shuffled(), by: .status) == PROrdering.sorted(items))
        #expect(PROrder.allCases.filter(\.isByDate) == [.newestFirst, .oldestFirst])

        // Each says when it was created.
        let created = t(-4 * day)
        let row = try #require(PRClassifier.snapshot(
            for: PRRecord(pullRequest: makePR(created: created), role: .author, me: me.id), seenCutoff: t(-3 * day), dismissedCutoff: t(-3 * day), now: t(0)
        ))
        #expect(row.createdAt == created)
    }

    @Test func theDemosPullRequestsSayWhatsLeft() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let rows = DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        }
        func row(_ number: Int) throws -> PRSnapshot { try #require(rows.first { $0.key.number == number }) }
        #expect(said(try #require(try row(4091).readiness)) == ["✓ Approved", "✓ Build passed", "✓ Comments resolved"])
        #expect(said(try #require(try row(4102).readiness))
            == ["✋ Resolve 2 comments", "◷ 1 of 2 approvals", "◷ Waiting on Sam", "✓ Build passed"])
        #expect(said(try #require(try row(4088).readiness)) == ["✕ Build failed", "✓ Approved"])
        #expect(said(try #require(try row(4079).readiness)) == ["✕ Merge conflicts", "◷ Not approved yet", "✓ Build passed"])
        #expect(said(try #require(try row(4099).readiness)) == ["↻ Build running", "◷ 0 of 2 approvals"])
        // Reviews, and what's closed, don't say it.
        #expect(try row(4097).readiness == nil)
        #expect(try row(4085).readiness == nil)
        // Every one of your open pull requests does.
        for row in rows where row.role == .author && row.group != .done {
            #expect(row.readiness != nil, "\(row.key)")
        }
    }
}
