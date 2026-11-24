import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// What My Work's Map says of a pull request and of a work item at a glance, under its title.
@Suite struct WorkMapGlancesTests {
    private let minimumPolicy = { (state: Check.State, count: Int) in
        Check(name: "Minimum number of reviewers", kind: .reviewers, state: state, minimumApprovers: count)
    }
    private let commentPolicy = { (state: Check.State) in Check(name: "Comment requirements", kind: .requirement, state: state) }

    private func record(
        _ pr: PullRequest, role: PRRole = .author, checks: [Check] = [], threads: [ReviewThread] = [], read: Bool = true
    ) -> PRRecord {
        PRRecord(pullRequest: pr, role: role, details: read ? makeDetails(for: pr, checks: checks, threads: threads) : nil, me: People.me.id)
    }

    private func thread(_ id: Int, status: String = "active") -> ReviewThread {
        ReviewThread(id: id, status: status, comments: [comment(1, People.sam, "Cap it", at: t(-2 * hour))])
    }

    /// "✕ Merge conflicts", "✋ 2 to resolve", "✓ 2 approved", "· Draft": each as its node says it, after its state's mark.
    private func said(_ glances: [MapGlance]) -> [String] {
        glances.map { glance in
            let mark = switch glance.state {
            case .failing?: "✕"
            case .needsYou?: "✋"
            case .done?: "✓"
            case .running?: "↻"
            case nil: "·"
            }
            return "\(mark) \(glance.words)"
        }
    }

    /// Yours says what stands in its way, in its order: conflicts, comments to resolve, the changes someone wants, which say
    /// more than who approved, what failed, then that it's a draft. What a policy requires resolving, and the changes someone
    /// wants, wait on you.
    @Test func yoursSaysWhatStandsInItsWayInOrder() {
        let pr = makePR(
            reviewers: [Reviewer(person: People.priya, vote: .approved), Reviewer(person: People.sam, vote: .waitingForAuthor)],
            draft: true, merge: "conflicts"
        )
        let failure = PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed.")
        let glances = record(
            pr, checks: [Check(name: "web-ci", kind: .build, state: .failed, failure: failure), minimumPolicy(.pending, 2), commentPolicy(.pending)],
            threads: [thread(1), thread(2, status: "pending"), thread(3, status: "fixed")]
        ).glances
        #expect(said(glances) == ["✕ Merge conflicts", "✋ 2 to resolve", "✋ Sam wants changes", "✕ Build failed", "· Draft"])
        #expect(glances.map(\.kind) == [.conflicts, .comments, .votes, .builds, .draft])
        #expect(glances.map(\.count) == [nil, 2, 1, nil, nil])
        #expect(glances.map(\.sentence) == [
            "Merge conflicts: fix-total into main", "2 comments to resolve: a policy requires resolving every comment",
            "Changes requested by Sam Rivera", "Build failed: web-ci · \(failure.summary)", "A draft",
        ])
    }

    /// One you review says the same, but nothing on it waits on you; you're "You", and who approved it is done once it has
    /// the approvals a policy wants, else says how many it has of them.
    @Test func oneYouReviewSaysTheSameButNothingWaitsOnYou() {
        let sams = { (reviewers: [Reviewer]) in makePR(author: People.sam, reviewers: reviewers) }
        let approved = record(
            sams([Reviewer(person: People.me, vote: .approved), Reviewer(person: People.priya, vote: .approvedWithSuggestions)]),
            role: .reviewer, checks: [minimumPolicy(.passed, 2)], threads: [thread(1)]
        ).glances
        #expect(said(approved) == ["· 1 to resolve", "✓ 2 approved"])
        #expect(approved.map(\.sentence) == ["1 comment to resolve", "Approved by you and Priya Shah"])

        let halfway = record(sams([Reviewer(person: People.priya, vote: .approved)]), role: .reviewer, checks: [minimumPolicy(.pending, 2)])
        #expect(said(halfway.glances) == ["· Priya approved"])
        #expect(halfway.glances.first?.sentence == "Approved by Priya Shah · 1 of 2 approvals")

        let yourChanges = record(sams([Reviewer(person: People.me, vote: .waitingForAuthor)]), role: .reviewer)
        #expect(said(yourChanges.glances) == ["· You want changes"])
        let rejected = record(
            sams([Reviewer(person: People.alex, vote: .waitingForAuthor), Reviewer(person: People.priya, vote: .rejected)]), role: .reviewer
        )
        #expect(said(rejected.glances) == ["· 2 want changes"])
        #expect(rejected.glances.first?.sentence == "Rejected by Priya Shah · Changes requested by Alex Kim")
        #expect(said(record(sams([Reviewer(person: People.priya, vote: .rejected)]), role: .reviewer).glances) == ["· Priya rejected it"])
    }

    /// Builds that expired fail it too, with how many; a check that failed, where its builds didn't; but not a build that
    /// runs, nor one no policy requires. Before its details are read, it says only what its list says; once it's done,
    /// nothing.
    @Test func whatFailedIsWhatAPolicyRequiresAndNothingOnceDone() {
        let pr = makePR()
        let build = { (name: String, state: Check.State) in Check(name: name, kind: .build, state: state) }
        let expired = record(pr, checks: [build("web-ci", .expired), build("api-ci", .expired)]).glances
        #expect(said(expired) == ["✕ 2 builds expired"])
        #expect(expired.first?.count == 2)
        #expect(said(record(pr, checks: [build("web-ci", .passed), Check(name: "sonar", kind: .status, state: .failed)]).glances) == ["✕ Check failed"])
        #expect(record(pr, checks: [build("web-ci", .running)]).glances.isEmpty)
        #expect(record(pr, checks: [Check(name: "lint", kind: .build, state: .failed, isBlocking: false)]).glances.isEmpty)

        let drafted = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)], draft: true, merge: "conflicts")
        let unread = record(drafted, checks: [build("web-ci", .failed)], threads: [thread(1)], read: false)
        #expect(said(unread.glances) == ["✕ Merge conflicts", "· Sam approved", "· Draft"])
        #expect(record(makePR(status: .completed, draft: true, merge: "conflicts"), threads: [thread(1)]).glances.isEmpty)
    }

    /// A work item says its state, the hours left on it while it isn't done, and where it is, outside the sprint.
    @Test func aWorkItemSaysItsStateHoursLeftAndWhereItIsOutsideTheSprint() {
        let task = { (state: String, category: WorkItem.Category, hours: Double?) in
            WorkItem(
                id: 5103, organization: "contoso", project: "Shop", type: "Task", title: "Show saved items", state: state, category: category,
                remainingWork: hours
            )
        }
        let active = task("Active", .inProgress, 2.5)
        #expect(active.glances(place: nil).map(\.words) == ["Active", "2.5 h left"])
        #expect(active.glances(place: nil).map(\.sentence) == ["Active", "2.5 h of work left"])
        #expect(task("New", .proposed, 0).glances(place: nil).map(\.words) == ["New"])
        #expect(task("Closed", .completed, 3).glances(place: nil).map(\.words) == ["Closed"])

        let outside = task("New", .proposed, 3).glances(place: "Sprint 41")
        #expect(outside.map(\.kind) == [.state, .hours, .sprint])
        #expect(outside.last?.sentence == "In Sprint 41")
        #expect(task("New", .proposed, nil).glances(place: OutsideWork.noSprint).last?.sentence == "In no sprint")
    }
}
