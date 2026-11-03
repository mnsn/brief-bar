import Foundation
import Testing
@testable import AzureDevOpsCore

/// The prompts about one of a pull request's failed builds quote what its details read of it: where it failed, its errors,
/// the tests that failed with what each said, the end of the failed step's log, and whether it's the change's doing, cut to
/// a size a prompt can carry.
@Suite struct BuildPromptTests {
    private let now = Date()

    private var record: PRRecord {
        get throws { try #require(DemoData.records(now: now).first { $0.id.number == 4088 }) }
    }

    private var investigation: BuildInvestigation {
        get throws { try #require(DemoData.buildInvestigation(buildId: 204_417, of: try record.pullRequest, now: now)) }
    }

    @Test func aReportQuotesWhatTheDetailsRead() throws {
        let report = FailedBuildReport(try investigation, name: "shop-web CI")
        #expect(report.buildId == 204_417)
        #expect(report.place == ["Test", "Unit tests", "Run unit tests"])
        #expect(report.errors == [
            "2 tests failed in DeliveryEstimateTests.",
            "Dotnet command failed with non-zero exit code on the following projects: tests/Storefront.Tests/Storefront.Tests.csproj",
        ])
        #expect(report.tests.map(\.name) == ["EstimateSkipsWeekends", "EstimateUsesTheWarehouseTimeZone"])
        #expect(report.testsSummary == "2 of 320 failed")
        #expect(report.moreTests == 0)
        #expect(report.logStep == "Run unit tests")
        #expect(report.log.count == 39)
        #expect(report.log.last == "##[section]Finishing: Run unit tests")
        #expect(report.log.contains("##[error]2 tests failed in DeliveryEstimateTests."))
        #expect(report.hints == ["main's latest run failed too: it may not be this change."])
    }

    /// Fix, for one build, as you say, with what a session answered of it: it keeps to that build, reproduces it and fixes
    /// it, without committing, pushing or touching pipelines.
    @Test func fixQuotesTheRunAndKeepsToIt() throws {
        let record = try record
        let report = FailedBuildReport(try investigation, name: "shop-web CI")
        let answer = CopilotAnswer(question: nil, answer: "It's main's AddBusinessDays.")
        let prompt = PullRequestPrompt.fixBuild(
            record, failures: [report], how: "Skip weekends in AddBusinessDays", answer: answer, alone: true
        )
        #expect(prompt.contains("""
            This build of it failed:

            1. shop-web CI: https://dev.azure.com/contoso/Storefront/_build/results?buildId=204417
               Failed at Test › Unit tests › Run unit tests.
               - 2 tests failed in DeliveryEstimateTests.
            """))
        #expect(prompt.contains("   main's latest run failed too: it may not be this change."))
        #expect(prompt.contains("""
               Its tests: 2 of 320 failed. Those that failed, with what each said:
               - Storefront.Tests.Delivery.DeliveryEstimateTests.EstimateSkipsWeekends
                 Assert.Equal() Failure: Values differ
                 Expected: Monday
                 Actual:   Saturday
            """))
        #expect(prompt.contains("   The last 39 lines of the log of Run unit tests:\n\n```\n##[section]Starting: Run unit tests"))
        #expect(prompt.contains("Earlier I asked Copilot why this build failed. It answered:\n\n> It's main's AddBusinessDays."))
        #expect(prompt.contains("How I want it fixed, in my own words:\n\n> Skip weekends in AddBusinessDays"))
        #expect(prompt.contains("Keep to this build: leave its other builds to their own fixes."))
        #expect(prompt.contains("Don't queue, retry or change pipelines. Don't commit or push"))
        // Without a word of yours, or an answer, as the pull request's Fix the Build sends it.
        let plain = PullRequestPrompt.fixBuild(record, failures: [report])
        #expect(plain.contains("Its build failed:\n\n1. shop-web CI"))
        #expect(!plain.contains("Keep to this build"))
        #expect(!plain.contains("in my own words"))
        #expect(!plain.contains("Earlier I asked"))
    }

    /// What a prompt quotes is cut to a size it can carry: the first tests, the first lines of what each said, and the last
    /// lines of the log, each line cut short; and a fence that nothing in the log closes.
    @Test func cutsWhatItQuotes() throws {
        var investigation = try investigation
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        investigation.tests?.failures = (1...7).map { FailedTest(id: "1/\($0)", name: "Test\($0)", message: long, stackTrace: long) }
        investigation.tests?.failed = 9
        let log = (1...60).map { BuildLogLine(number: $0, text: $0 == 60 ? String(repeating: "x", count: 400) : "log ```` \($0)") }
        investigation.log?.lines = log
        let report = FailedBuildReport(investigation, name: "shop-web CI")
        #expect(report.tests.count == FailedBuildReport.testLimit)
        #expect(report.moreTests == 4)
        #expect(report.log.count == FailedBuildReport.logLines)
        #expect(report.log.first == "log ```` 21")
        #expect(report.log.last?.count == FailedBuildReport.logLineLimit)
        #expect(report.log.last?.hasSuffix("…") == true)
        let prompt = PullRequestPrompt.fixBuild(try record, failures: [report])
        #expect(prompt.contains("     line 12…\n"))
        #expect(!prompt.contains("line 13"))
        #expect(prompt.contains("     line 6…\n"))
        #expect(prompt.contains("   - 4 more failed."))
        #expect(prompt.contains("\n`````\nlog ```` 21"))
    }

    /// Explain asks aside what failed, why, and whose doing it is, from what's quoted, which a throwaway fork can't read
    /// itself; a follow-up asks just your question, with the answer before.
    @Test func explainAsksWhatFailedAndWhoseDoingItIs() throws {
        let record = try record
        let report = FailedBuildReport(try investigation, name: "shop-web CI")
        let why = PullRequestPrompt.explainBuild(record, build: report, question: nil)
        #expect(why.hasPrefix("Pull request !4088 “Show delivery estimates on the product page” in shop-web, from delivery-estimates into main, has a build that failed:\n\n1. shop-web CI"))
        #expect(why.contains("Explain what failed and why, and whether it's this change, a flaky test, the target branch or the build's infrastructure, with the evidence."))
        #expect(why.hasSuffix("Be brief and concrete, and don't change anything."))
        #expect(why.contains("Its tests: 2 of 320 failed."))
        let asked = PullRequestPrompt.explainBuild(record, build: report, question: "Did main break it?")
        #expect(asked.contains("My question, in my own words:\n\n> Did main break it?"))
        let earlier = CopilotAnswer(question: "Did main break it?", answer: "Yes.")
        let more = PullRequestPrompt.explainBuild(record, build: report, question: "Since when?", earlier: earlier)
        #expect(more.contains("Earlier I asked Copilot about this build, in my own words:\n\n> Did main break it?\n\nIt answered:\n\n> Yes."))
        #expect(more.contains("My next question, in my own words:\n\n> Since when?"))
        #expect(more.contains("Answer it, with what you answered before in mind."))
        #expect(!more.contains("Explain what failed"))
        // Asked in the session instead, it can read the whole log itself, and changes nothing.
        let inSession = PullRequestPrompt.askAboutBuild(record, build: report, question: nil)
        #expect(inSession.contains(record.pullRequest.webURL.absoluteString))
        #expect(inSession.contains("read its code, or the run's whole log with your Azure DevOps tools"))
        #expect(inSession.contains("don't queue, retry or change pipelines, and don't commit, push or reply on the pull request: only answer."))
    }
}
