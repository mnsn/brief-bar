import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// What ends `BriefBar --wait` on one of your pull requests: a build that ran since and failed or passed, merge conflicts,
/// or comments someone else wrote since, in threads still open.
@Suite struct WaitOutcomeTests {
    private func record(
        checks: [Check] = [], threads: [ReviewThread] = [], merge: String = "succeeded", details: Bool = true
    ) -> PRRecord {
        let pr = makePR(4102, merge: merge)
        return PRRecord(
            pullRequest: pr, role: .author, details: details ? makeDetails(for: pr, checks: checks, threads: threads) : nil,
            me: People.me.id
        )
    }

    private func build(
        _ state: Check.State, id: Int? = 501, pipeline: Int? = 12, name: String = "shop-web CI", blocking: Bool = true,
        completed: Date? = nil, policy: Int? = nil
    ) -> Check {
        Check(
            name: name, kind: .build, state: state, isBlocking: blocking, completedAt: completed, buildId: id, definitionId: pipeline,
            policyId: policy
        )
    }

    @Test func nothingYetWhileTheBuildRuns() {
        let baseline = record(checks: [build(.queued)])
        #expect(WaitOutcome.since(baseline, in: baseline).isEmpty)
        #expect(WaitOutcome.since(baseline, in: record(checks: [build(.running)])).isEmpty)
        #expect(WaitOutcome.running(in: record(checks: [build(.running), build(.passed, pipeline: 13)])).map(\.definitionId) == [12])
    }

    @Test func aBuildThatRanSinceEndsItWithItsResult() {
        let baseline = record(checks: [build(.running)])
        let failed = build(.failed, completed: t(60))
        #expect(WaitOutcome.since(baseline, in: record(checks: [failed])) == [.buildFailed([failed])])
        let passed = build(.passed, completed: t(60))
        #expect(WaitOutcome.since(baseline, in: record(checks: [passed])) == [.buildPassed([passed])])
    }

    /// A build that had failed when the wait began, as after a push before its next run is queued, ends nothing until it
    /// runs again: as another run, or the same one retried, which finishes later.
    @Test func aBuildThatHadFailedAlreadyCountsOnlyOnceItRunsAgain() {
        let old = build(.failed, id: 500, completed: t(-600))
        let baseline = record(checks: [old])
        #expect(WaitOutcome.since(baseline, in: baseline).isEmpty)
        #expect(WaitOutcome.since(baseline, in: record(checks: [build(.queued, id: 501)])).isEmpty)
        let again = build(.failed, id: 501, completed: t(60))
        #expect(WaitOutcome.since(baseline, in: record(checks: [again])) == [.buildFailed([again])])
        let retried = build(.passed, id: 500, completed: t(120))
        #expect(WaitOutcome.since(baseline, in: record(checks: [retried])) == [.buildPassed([retried])])
        // So does one that passed already.
        let passed = record(checks: [build(.passed, id: 500, completed: t(-600))])
        #expect(WaitOutcome.since(passed, in: passed).isEmpty)
    }

    /// One failed build ends it at once, while the others still run; it passes only once every build that runs has.
    @Test func itFailsAtOnceButPassesOnlyOnceEveryBuildHas() {
        let baseline = record(checks: [build(.running), build(.running, id: 601, pipeline: 13, name: "shop-web tests")])
        let passed = build(.passed, completed: t(60))
        #expect(WaitOutcome.since(baseline, in: record(checks: [passed, build(.running, id: 601, pipeline: 13)])).isEmpty)
        let failed = build(.failed, id: 601, pipeline: 13, name: "shop-web tests", completed: t(90))
        #expect(WaitOutcome.since(baseline, in: record(checks: [build(.running), failed])) == [.buildFailed([failed])])
        let both = [passed, build(.passed, id: 601, pipeline: 13, name: "shop-web tests", completed: t(90))]
        #expect(WaitOutcome.since(baseline, in: record(checks: both)) == [.buildPassed(both)])
    }

    /// It passes only once every build that blocks it has: not while another failed before the wait began, expired, or never
    /// ran, though nothing runs it, as one that expired while the wait went on. One that doesn't apply holds nothing up.
    @Test func itPassesOnlyOnceEveryBuildThatBlocksItHas() {
        let passed = build(.passed, completed: t(60))
        for state in [Check.State.failed, .expired, .notRun] {
            let other = build(state, id: 601, pipeline: 13, name: "shop-web tests", completed: t(-600))
            #expect(WaitOutcome.since(record(checks: [build(.running), other]), in: record(checks: [passed, other])).isEmpty, "\(state)")
        }
        let running = build(.running, id: 601, pipeline: 13, name: "shop-web tests")
        var expired = running
        expired.state = .expired
        #expect(WaitOutcome.since(record(checks: [build(.running), running]), in: record(checks: [passed, expired])).isEmpty)
        #expect(WaitOutcome.stalled(in: record(checks: [passed, expired])) == [expired])
        let skipped = build(.notApplicable, id: nil, pipeline: 13, name: "shop-web tests")
        #expect(WaitOutcome.since(record(checks: [build(.running), skipped]), in: record(checks: [passed, skipped])) == [.buildPassed([passed])])
        #expect(WaitOutcome.stalled(in: record(checks: [passed, skipped])).isEmpty)
    }

    /// Two policies may run one pipeline under one name, each with its own run: their policies tell them apart, so neither's
    /// last run is news, and only the one that runs again ends it.
    @Test func twoPoliciesOfOnePipelineAreToldApart() {
        let web = build(.passed, id: 501, completed: t(-600), policy: 7)
        let api = build(.failed, id: 601, completed: t(-300), policy: 8)
        let baseline = record(checks: [web, api])
        #expect(WaitOutcome.since(baseline, in: baseline).isEmpty)
        let again = build(.passed, id: 602, completed: t(60), policy: 8)
        #expect(WaitOutcome.since(baseline, in: record(checks: [web, again])) == [.buildPassed([again])])
    }

    /// Optional builds don't hold up a merge, and expired ones or ones never run aren't results.
    @Test func onlyResultsOfBuildsThatBlockItCount() {
        let baseline = record(checks: [build(.running, blocking: false)])
        #expect(WaitOutcome.since(baseline, in: record(checks: [build(.failed, blocking: false, completed: t(60))])).isEmpty)
        let queued = record(checks: [build(.queued)])
        #expect(WaitOutcome.since(queued, in: record(checks: [build(.expired)])).isEmpty)
        #expect(WaitOutcome.since(queued, in: record(checks: [build(.notRun, id: nil)])).isEmpty)
    }

    @Test func mergeConflictsEndItEvenWhenItBeganWithThem() {
        let baseline = record(checks: [build(.running)], merge: "conflicts")
        #expect(WaitOutcome.since(baseline, in: baseline) == [.conflicts])
        #expect(WaitOutcome.since(record(), in: record(merge: "conflicts")) == [.conflicts])
    }

    /// Someone else's word since the wait began, in a thread still open: a new thread, or a reply in one that was there.
    /// Not yours, not a resolved thread's, not one that waited on you already, and not an edit to a comment.
    @Test func commentsSomeoneElseWroteSinceEndIt() {
        let waiting = ReviewThread(id: 1, comments: [comment(1, People.sam, "Cap it", at: t(-600))])
        let answered = ReviewThread(id: 2, comments: [comment(1, People.sam, "Why?", at: t(-600)), comment(2, People.me, "Because", at: t(-300))])
        let baseline = record(threads: [waiting, answered])
        #expect(WaitOutcome.since(baseline, in: baseline).isEmpty)

        let reply = ReviewThread(id: 2, comments: answered.comments + [comment(3, People.priya, "Then say so in the code", at: t(60))])
        let new = ReviewThread(id: 3, comments: [comment(1, People.alex, "Rename it", at: t(90))])
        let resolved = ReviewThread(id: 4, status: "fixed", comments: [comment(1, People.alex, "Done", at: t(90))])
        let mine = ReviewThread(id: 5, comments: [comment(1, People.me, "A note to self", at: t(90))])
        var edited = waiting
        edited.comments[0].text = "Cap it at 30 s"
        let current = record(threads: [edited, reply, new, resolved, mine])
        #expect(WaitOutcome.since(baseline, in: current) == [.comments([reply, new])])
    }

    /// As Needs You counts them: a bot's note ends nothing, as a build service's or a code scanner's posted while the build
    /// runs, not even after someone's comment that waited on you already; nor does a comment you've answered since. But
    /// someone's comment does, with a bot's after it.
    @Test func onlyCommentsFromPeopleThatWaitOnYouEndIt() {
        let waiting = ReviewThread(id: 1, comments: [comment(1, People.sam, "Cap it", at: t(-600))])
        let baseline = record(threads: [waiting])
        let botsNote = ReviewThread(id: 1, comments: waiting.comments + [comment(2, People.bot, "Coverage dropped 2%", at: t(30))])
        let botsThread = ReviewThread(id: 2, comments: [comment(1, People.bot, "3 new code smells", at: t(30))])
        #expect(WaitOutcome.since(baseline, in: record(threads: [botsNote, botsThread])).isEmpty)

        let answered = ReviewThread(id: 3, comments: [comment(1, People.alex, "Rename it", at: t(30)), comment(2, People.me, "Done", at: t(50))])
        #expect(WaitOutcome.since(baseline, in: record(threads: [waiting, answered])).isEmpty)

        let thenBot = ReviewThread(id: 4, comments: [comment(1, People.priya, "Add a test", at: t(30)), comment(2, People.bot, "Thanks", at: t(31))])
        #expect(WaitOutcome.since(baseline, in: record(threads: [waiting, thenBot])) == [.comments([thenBot])])
    }

    /// Everything at once, in that order: a failed build, then conflicts, then comments; a passed build last.
    @Test func whatHappenedAtOnceComesInOrder() {
        let thread = ReviewThread(id: 3, comments: [comment(1, People.alex, "Rename it", at: t(90))])
        let failed = build(.failed, completed: t(60))
        let baseline = record(checks: [build(.running)])
        #expect(WaitOutcome.since(baseline, in: record(checks: [failed], threads: [thread], merge: "conflicts"))
            == [.buildFailed([failed]), .conflicts, .comments([thread])])
        let passed = build(.passed, completed: t(60))
        #expect(WaitOutcome.since(baseline, in: record(checks: [passed], threads: [thread]))
            == [.comments([thread]), .buildPassed([passed])])
    }
}
