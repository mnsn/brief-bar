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
        #expect(rows.filter(\.isReady).count == 1)
        #expect(rows.filter(\.isReady).allSatisfy { $0.state == .done })
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

    /// Someone else signed in to the GitHub CLI, another account or no one: what was told of its pull requests goes, and is
    /// told again as the new ones when asked; the same ones change nothing.
    @Test func otherAccountsForgetWhatWasToldOfGitHub() async throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        services.links.setOn(true)
        let source = GitHubSource(services: services)
        source.start()
        defer { source.stop() }
        let logins = source.store.logins
        #expect(logins == [GitHubDemoData.login])
        let item = try #require(source.store.items.first)
        let ref = ItemRef.gitHubPullRequest(repository: item.pullRequest.repository, number: item.pullRequest.number)
        let row = services.links.describe(ref)
        await services.stories.tell([row])
        source.loginsChanged(logins)
        #expect(services.stories.story(for: ref) != nil)
        source.loginsChanged(["someone-else"])
        #expect(!services.stories.hasTold(ref))
        await services.stories.tell([row])
        #expect(services.stories.story(for: ref) != nil)
        // Signed in to another account too.
        source.loginsChanged(["someone-else", "robin-oss"])
        #expect(!services.stories.hasTold(ref))
        await services.stories.tell([row])
        // Signed out.
        source.loginsChanged([])
        #expect(!services.stories.hasTold(ref))
        // The first sign-in after that changes nothing.
        await services.stories.tell([row])
        source.loginsChanged(logins)
        #expect(services.stories.story(for: ref) != nil)
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

    @Test func readableWidgetsGrowWithoutStartingTheSource() {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = GitHubSource(services: services)
        #expect(source.widgetHeight(for: .githubPullRequests, rows: 2) == 120)
        services.setInterfaceOption(.readableRows, enabled: true)
        #expect(source.widgetHeight(for: .githubPullRequests, rows: 2) == 128)
        #expect(source.stateRows(for: .githubPullRequests).isEmpty)
        services.setInterfaceOption(.readableRows, enabled: false)
        #expect(source.widgetHeight(for: .githubPullRequests, rows: 2) == 120)
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

    /// The Pull Requests page in Settings has none of GitHub's own, as how often it reads stays on its page, but Pull Request
    /// Order works with its pull requests, under Azure DevOps and GitHub.
    @Test func sharesPullRequestOrderOnThePullRequestsPage() {
        let source = demoSource()
        #expect(source.pullRequestSettings.isEmpty)
        #expect(source.pullRequestSettingsView(state: .on) == nil)
        #expect(PullRequestSettings.has(source.id, ownSettings: source.pullRequestSettings))
        let groups = PullRequestSettings.groups([(id: source.id, settings: source.pullRequestSettings)])
        #expect(groups == [PullRequestSettings.shared])
        #expect(PullRequestSettings.shared.sources.contains(.github))
    }
}

/// What Terminal runs when you sign in to the GitHub CLI, or to another account.
@Suite struct SignInScriptTests {
    @Test func signsInThroughTheBrowser() {
        let script = GitHub.signInScript(ghPath: "/opt/homebrew/bin/gh", keepingActive: false)
        #expect(script.hasPrefix("#!/bin/zsh -l\n"))
        #expect(script.contains("\nif '/opt/homebrew/bin/gh' auth login --hostname github.com --web; then\n"))
        #expect(script.contains("BriefBar will refresh within a minute"))
        #expect(!script.contains("auth switch"))
        #expect(!script.contains("config get"))
        #expect(GitHub.signInScript(ghPath: nil, keepingActive: false).contains("\nif gh auth login --hostname github.com --web; then\n"))
    }

    /// Signing in to another account makes it the GitHub CLI's active one: the one it used as the sign-in started, as `gh`
    /// says then, goes on being so; and when it can't, the script says so, and how to switch back.
    @Test func anotherAccountLeavesTheOneTheCLIUses() throws {
        let script = GitHub.signInScript(ghPath: nil, keepingActive: true)
        let active = try #require(script.range(of: "\nactive=\"$(gh config get --host github.com user 2>/dev/null)\"\n"))
        let login = try #require(script.range(of: "\nif gh auth login --hostname github.com --web; then\n"))
        let back = try #require(script.range(
            of: "\n        if switched=\"$(gh auth switch --hostname github.com --user \"$active\" 2>&1)\"; then\n"
        ))
        #expect(active.lowerBound < login.lowerBound)
        #expect(back.lowerBound > login.upperBound)
        #expect(script.contains("\n    if [[ -n \"$active\" ]]; then\n"))
        #expect(script.contains("\n            echo \"The GitHub CLI goes on using $active in Terminal: gh auth switch changes that.\"\n        else\n"))
        #expect(script.contains("\n            print -r -- \"$switched\"\n"))
        #expect(script.contains("couldn't switch back to $active, so in Terminal it uses the account you signed in to."))
        #expect(script.contains("To use $active again: gh auth switch --hostname github.com --user $active\""))
    }

    @Test func quotesWhatItRuns() {
        let script = GitHub.signInScript(ghPath: "/Users/o'brien/bin/gh", keepingActive: true)
        #expect(script.contains("active=\"$('/Users/o'\\''brien/bin/gh' config get --host github.com user"))
        #expect(script.contains("if '/Users/o'\\''brien/bin/gh' auth login"))
        #expect(script.contains("switched=\"$('/Users/o'\\''brien/bin/gh' auth switch"))
    }
}
