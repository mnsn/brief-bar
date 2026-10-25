import BriefBarCore
import BriefBarUI
import Foundation
import GitHubCore
import Testing
@testable import GitHubUI

/// What GitHub shows across BriefBar: the made-up pull requests, which never run gh or connect to GitHub.
@MainActor
@Suite struct SourceTests {
    private func demoSource() -> GitHubSource {
        GitHubSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true))
    }

    private func states(_ rows: [StateRow]) -> StateCounts {
        var counts = StateCounts()
        for row in rows { counts[row.state] += 1 }
        return counts
    }

    @Test func listsWhatTheMenuBarCountsByState() {
        let source = demoSource()
        source.start()
        defer { source.stop() }

        let segment = source.segment(for: .githubPullRequests)
        let rows = source.stateRows(for: .githubPullRequests)
        #expect(states(rows) == StateCounts(needsYou: 3, failing: 2, done: 1))
        #expect(states(rows) == segment.states)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(segment.count == 3)
        #expect(segment.needsAttention)
        #expect(segment.problem == nil)
        #expect(segment.summary == "GitHub: 2 to review, 1 with changes requested, 2 failing, 1 ready")
    }

    @Test func saysTheSamePullRequestsInTheBrief() {
        let source = demoSource()
        source.start()
        defer { source.stop() }

        let lines = source.briefLines(for: .githubPullRequests)
        var counts = StateCounts()
        for line in lines { counts[line.state] += 1 }
        #expect(counts == source.segment(for: .githubPullRequests).states)
        #expect(Set(lines.map(\.id)).count == lines.count)
        #expect(lines.allSatisfy { $0.source == .github && $0.id.hasPrefix("github/") && !$0.sentence.isEmpty })
        // Made up in BriefBar's words: nothing asks a model.
        #expect(lines.allSatisfy { $0.request == nil })
    }

    @Test func showsNothingUntilStartedOrOnceStopped() {
        let source = demoSource()
        func expectNothing() {
            let segment = source.segment(for: .githubPullRequests)
            #expect(source.stateRows(for: .githubPullRequests).isEmpty)
            #expect(source.briefLines(for: .githubPullRequests).isEmpty)
            #expect(segment.count == 0)
            #expect(segment.states == StateCounts())
            #expect(!segment.needsAttention)
            #expect(segment.summary == "GitHub: nothing needs you")
        }
        expectNothing()
        source.start()
        #expect(!source.stateRows(for: .githubPullRequests).isEmpty)
        source.stop()
        expectNothing()
    }

    @Test func asksYouToSignInInsteadOfCounting() {
        for problem in [GitHubProblem.cliNotFound, .signedOut("not logged in")] {
            let segment = GitHubSource.segment(counts: GitHubGroupCounts(), problem: problem, glyph: "arrow.triangle.merge")
            #expect(segment.summary == "GitHub: sign in to see your pull requests")
            #expect(segment.problem == segment.summary)
            #expect(segment.needsAttention)
            #expect(segment.states == StateCounts())
            #expect(segment.count == 0)
        }
    }

    /// Offline or slowed down, the last list stays, and its counts with it.
    @Test func otherProblemsKeepCounting() {
        var counts = GitHubGroupCounts()
        counts.failing = 2
        counts.waiting = 4
        for problem in [GitHubProblem.offline, .throttled(until: Date()), .unreachable("x"), .authFailed("x")] {
            let segment = GitHubSource.segment(counts: counts, problem: problem, glyph: "arrow.triangle.merge")
            #expect(segment.problem == nil)
            #expect(segment.states == StateCounts(failing: 2))
            #expect(segment.count == 0)
            #expect(!segment.needsAttention)
            #expect(segment.summary == "GitHub: 2 failing")
        }
    }

    @Test func waitingPullRequestsArentCounted() {
        var counts = GitHubGroupCounts()
        counts.waiting = 3
        let segment = GitHubSource.segment(counts: counts, problem: nil, glyph: "arrow.triangle.merge")
        #expect(segment.summary == "GitHub: nothing needs you")
        #expect(segment.states == StateCounts())
    }

    @Test func aSignInProblemEmptiesEveryList() {
        let source = demoSource()
        source.start()
        defer { source.stop() }

        source.store.fail(GitHubError.unauthorized)
        #expect(source.stateRows(for: .githubPullRequests).isEmpty)
        #expect(source.briefLines(for: .githubPullRequests).isEmpty)
        #expect(source.segment(for: .githubPullRequests).problem != nil)
    }

    @Test func describesWhatItReadsAndWhereItConnects() {
        let source = demoSource()
        #expect(source.id == .github)
        #expect(source.description.version == GitHubSource.descriptionVersion)
        #expect(source.description.requirements == [.githubCLI])
        #expect(source.description.network.contains("api.github.com"))
        #expect(source.description.network.contains("never changes anything"))
        #expect(source.description.needs.contains("No personal access token"))
        #expect(source.sections.map(\.id) == [.githubPullRequests])
        #expect(source.sections.first?.states == [.needsYou, .failing, .done])
    }

    @Test func theDemoHasNoSignInToShow() {
        #expect(demoSource().statusView() == nil)
    }

    /// Agents (`--mcp`) get tools from Azure DevOps and Copilot, never from GitHub.
    @Test func givesAgentsNothing() {
        for demo in [true, false] {
            #expect(GitHubCommandLine.mcp(CommandLineOptions(arguments: [], demo: demo)) == nil)
        }
    }

    /// Turning GitHub off keeps its settings: it saves nothing else.
    @Test func turningOffKeepsTheRefreshSetting() {
        let defaults = MemoryDefaults()
        let source = GitHubSource(services: AppServices(defaults: defaults, isDemo: true))
        source.settings.refreshMinutes = 15
        source.deleteSavedData()
        #expect(source.settings.refreshMinutes == 15)
        #expect(defaults.integer(forKey: AppSettings.Key.refreshMinutes) == 15)
    }
}
