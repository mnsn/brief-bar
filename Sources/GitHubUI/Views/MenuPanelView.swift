import BriefBarCore
import BriefBarUI
import GitHubCore
import SwiftUI

/// The menu-bar popover: your pull requests grouped by what they need.
struct MenuPanelView: View {
    @EnvironmentObject private var store: GitHubStore
    @EnvironmentObject private var loginItem: LoginItem

    @LocalState private var contentHeight: CGFloat = 0

    static let width: CGFloat = 380
    private static let maxListHeight: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                list
                    .padding(8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .panelListHeight(contentHeight, max: Self.maxListHeight)
            Divider()
            footer
        }
        .panelFrame(width: Self.width)
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        HStack {
            PageLink(.githubPullRequests, name: "Pull Requests") {
                HStack {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(.tint)
                    Text("Pull Requests")
                        .font(.headline)
                }
            }
            Spacer()
            if store.isRefreshing && !store.hasLoaded {
                ProgressView()
                    .controlSize(.small)
            } else {
                CountChips(counts: store.counts)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = store.problem {
                ProblemView(problem: problem) { store.signIn() }
            }
            if let notice = store.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.hasLoaded && store.items.isEmpty && store.problem?.needsSignIn != true {
                QuietView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            ForEach(GitHubPRGroup.allCases, id: \.self) { group in
                let items = store.items(in: group)
                if !items.isEmpty {
                    section(group, items)
                }
            }

            if store.moreThanShown {
                Button {
                    store.openPullRequestsPage()
                } label: {
                    Label("More on GitHub", systemImage: "arrow.up.forward")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .help("BriefBar shows your 50 most recently changed pull requests of each kind")
            }
        }
    }

    private func section(_ group: GitHubPRGroup, _ items: [GitHubPRSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(group.title) (\(items.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(group.color)
                .padding(.horizontal, 8)
            ForEach(items) { item in
                PullRequestRow(item: item)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                store.openPullRequestsPage()
            } label: {
                Label("Open GitHub", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            if let login = store.login {
                Text(login)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Signed in to the GitHub CLI as \(login)")
            }
            Spacer()
            Menu {
                SettingsMenuContent()
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A pull request in a list: GitHub's own, and a list by state that mixes every source's. It opens on GitHub.
struct PullRequestRow: View {
    let item: GitHubPRSnapshot

    @EnvironmentObject private var store: GitHubStore

    var body: some View {
        PRRowView(item: item, now: store.now) { store.open(item) }
    }
}

/// Why the list is missing or may be out of date, with a way to sign in when that's the reason.
struct ProblemView: View {
    let problem: GitHubProblem
    var signIn: () -> Void

    var body: some View {
        if problem.needsSignIn {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(problem.message)
                        .font(.system(size: 12, weight: .semibold))
                } icon: {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(problem == .cliNotFound ? "Install the GitHub CLI…" : "Sign In…", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
            .padding(.horizontal, 4)
        } else {
            Label(problem.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        if problem == .cliNotFound {
            return "Install it with Homebrew (brew install gh), then sign in once. No personal access token needed."
        }
        return "BriefBar uses the GitHub CLI's sign-in, so there's no token to create. Sign In opens Terminal to run "
            + "gh auth login in your browser; it stays signed in after that."
    }
}

struct QuietView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("All quiet")
                .font(.system(size: 13, weight: .semibold))
            Text("No open pull requests for you")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
