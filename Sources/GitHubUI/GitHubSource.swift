import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import GitHubCore
import SwiftUI

/// Your GitHub pull requests: those whose review is requested from you, and yours that have changes requested, are
/// failing or are approved. It reads github.com with the GitHub CLI's sign-in, and is off until you turn it on.
@MainActor
package final class GitHubSource: BriefBarSource {
    nonisolated package static let descriptionVersion = 1

    package let id = SourceID.github
    package let name = "GitHub"
    package let symbol = "arrow.triangle.merge"
    package let description = SourceDescription(
        version: GitHubSource.descriptionVersion,
        summary: "Your GitHub pull requests: reviews requested from you, and which of yours need changes, are failing or are approved",
        reads: "On github.com: the open pull requests that request your review by name, and your own open pull requests, with their checks, reviews and whether they can merge. BriefBar keeps none of it: it reads them again each time.",
        network: "GitHub only: api.github.com, with the GitHub CLI's sign-in. One read-only GraphQL query (sent as a POST) each refresh, every 2 minutes by default. It never changes anything on GitHub.",
        needs: "The GitHub CLI, signed in with gh auth login. No personal access token.",
        requirements: [.githubCLI]
    )
    package let sections = [
        SectionInfo(
            id: .githubPullRequests, title: "Pull Requests", symbol: "arrow.triangle.merge",
            tint: Color(red: 0.51, green: 0.31, blue: 0.86), counted: CountNoun("GitHub pull request", "GitHub pull requests"),
            states: [.needsYou, .failing, .done], surfaces: [.menuBar, .widgets, .windows]
        ),
    ]
    package var panelWidth: CGFloat { MenuPanelView.width }

    /// The groups counted in the menu bar. Waiting ones only show in the list.
    static let shownGroups: [GitHubPRGroup] = [.toReview, .changesRequested, .failing, .ready]

    private let services: AppServices
    let settings: AppSettings
    let store: GitHubStore

    package init(services: AppServices) {
        self.services = services
        settings = AppSettings(defaults: services.defaults)
        // The demo shows only made-up pull requests: it never runs gh or connects to GitHub.
        store = GitHubStore(settings: settings, mode: services.isDemo ? .demo : .live)
    }

    private func environment<V: View>(_ view: V) -> some View {
        view
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(services)
            .environmentObject(services.loginItem)
    }

    // MARK: Lifecycle

    package func start() {
        store.start()
    }

    package func stop() {
        store.stop()
    }

    /// Nothing to delete: the list and the token are only ever in memory, and the refresh choice is a setting.
    package func deleteSavedData() {}

    // MARK: Menu bar

    package func segment(for section: SectionID) -> MenuBarSegment {
        Self.segment(counts: store.counts, problem: store.problem, glyph: symbol)
    }

    static func segment(counts: GitHubGroupCounts, problem: GitHubProblem?, glyph: String) -> MenuBarSegment {
        let needsSignIn = problem?.needsSignIn == true
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        if needsSignIn {
            // A small orange person badge while you need to sign in.
            title.append(NSAttributedString(string: " "))
            title.append(MenuBarDrawing.symbol("person.crop.circle.badge.exclamationmark.fill", color: .systemOrange, font: font,
                                               sizeDelta: -2, monochrome: true))
        } else {
            for group in shownGroups where counts[group] > 0 {
                title.append(NSAttributedString(string: " "))
                // Monochrome keeps the check and the cross cut out; one palette color fills them in.
                title.append(MenuBarDrawing.symbol(group.symbol, color: group.nsColor, font: font, sizeDelta: -2, monochrome: true))
                title.append(MenuBarDrawing.count(counts[group], font: font))
            }
        }
        let spoken = shownGroups.filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.countLabel)" }
        let summary = needsSignIn
            ? "GitHub: sign in to see your pull requests"
            : spoken.isEmpty ? "GitHub: nothing needs you" : "GitHub: " + spoken.joined(separator: ", ")
        return MenuBarSegment(
            glyph: glyph, title: title, summary: summary, count: counts.needsYou,
            needsAttention: counts.needsYou > 0 || needsSignIn,
            // Like the counts it draws: none until you've signed in.
            states: needsSignIn ? StateCounts() : counts.states,
            problem: needsSignIn ? summary : nil
        )
    }

    package var segmentsChanged: AnyPublisher<Void, Never> {
        store.$counts.removeDuplicates().map { _ in () }
            .merge(with: store.$problem.removeDuplicates().map { _ in () })
            .eraseToAnyPublisher()
    }

    /// Pull requests to review or with changes requested, failing, or ready to merge. Waiting ones aren't in any state.
    package func stateRows(for section: SectionID) -> [StateRow] {
        guard store.problem?.needsSignIn != true else { return [] }
        return store.items.compactMap { item in
            item.group.state.map { state in
                StateRow(id: item.id, state: state, date: item.since, view: AnyView(environment(PullRequestRow(item: item))))
            }
        }
    }

    /// The same pull requests, each in a sentence in BriefBar's own words, without Apple Intelligence.
    package func briefLines(for section: SectionID) -> [BriefLine] {
        guard store.problem?.needsSignIn != true else { return [] }
        return store.items.compactMap { item in
            item.group.state.map { state in
                BriefLine(
                    id: "github/\(item.id)/\(item.reason.rawValue)", source: id, state: state, date: item.since,
                    sentence: item.briefSentence, open: { [store] in store.open(item) }
                )
            }
        }
    }

    package var stateRowsChanged: AnyPublisher<Void, Never> {
        store.$items.map { _ in () }
            .merge(with: store.$problem.removeDuplicates().map { _ in () })
            .eraseToAnyPublisher()
    }

    package func panel(for section: SectionID) -> AnyView {
        AnyView(environment(MenuPanelView()))
    }

    package func panelWillShow(_ section: SectionID) {
        store.refreshIfStale()
    }

    // MARK: Widgets

    package func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView {
        AnyView(environment(WidgetSectionView(rows: rows)))
    }

    package func widgetHeight(for section: SectionID, rows: Int) -> CGFloat {
        WidgetSectionView.height(rows: rows)
    }

    package func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat {
        size.width
    }

    package func widgetMenu(for section: SectionID) -> AnyView {
        AnyView(environment(SourceMenuContent()))
    }

    // MARK: Settings

    package func settingsView() -> AnyView {
        AnyView(environment(GitHubSettings()))
    }

    package func statusView() -> AnyView? {
        guard store.mode == .live else { return nil }
        return AnyView(environment(SignInStatusView()))
    }

    // MARK: Rendering

    package func loadForRendering() async {
        await store.loadOnce()
    }
}

/// How the GitHub CLI's sign-in stands, on GitHub's page in Settings.
struct SignInStatusView: View {
    @EnvironmentObject private var store: GitHubStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if needsSignIn {
                Button(store.problem == .cliNotFound ? "Install the GitHub CLI…" : "Sign In…") { store.signIn() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var needsSignIn: Bool { store.problem?.needsSignIn == true }
    private var ok: Bool { !needsSignIn }

    private var title: String {
        if store.problem == .cliNotFound { return "The GitHub CLI isn't installed" }
        if needsSignIn { return "Not signed in to the GitHub CLI" }
        if let login = store.login { return "Signed in with the GitHub CLI as \(login)" }
        return store.isStarted ? "Checking the GitHub CLI's sign-in…" : "Turn GitHub on to check the GitHub CLI's sign-in"
    }

    private var detail: String {
        needsSignIn
            ? "BriefBar reads your GitHub pull requests with the GitHub CLI's sign-in."
            : "BriefBar uses whatever account the GitHub CLI is signed in to on github.com."
    }
}
