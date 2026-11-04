import BriefBarCore
import BriefBarUI
import GitHubCore
import SwiftUI

/// GitHub's Pull Requests page in a window: your pull requests by what they need, each group in a card; or, with Pull
/// Request Order on, By Mission, as Azure DevOps' page lists them (`MissionsBody`), with the missions' Azure DevOps pull
/// requests on its page. A click opens a pull request on GitHub.
struct PullRequestsPage: View {
    /// By Mission, for pictures; nil for what you chose.
    var byMission: Bool? = nil
    /// By Mission's view, for pictures; nil for the one you chose.
    var view: OrderView? = nil

    @EnvironmentObject private var store: GitHubStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ordering: PullRequestOrder
    @EnvironmentObject private var services: AppServices
    @Environment(\.interfaceOptions) private var options

    static let kinds: Set<ItemRef.Kind> = [.gitHubPullRequest]

    /// By Mission only while Pull Request Order is on.
    private var listsByMission: Bool {
        ordering.isOn && (byMission ?? settings.listsByMission)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Pull Requests", subtitle: subtitle) {
                if ordering.isOn {
                    orderMenu
                }
                if listsByMission {
                    OrderViewPicker(order: ordering, shown: view)
                }
                Button {
                    store.openPullRequestsPage()
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.forward.app")
                        .font(size: 13)
                }
                .glassButtonStyle()
            }
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    if listsByMission {
                        byMissionBody
                    } else {
                        groups(store.items)
                    }
                    more
                }
            }
        }
    }

    private var subtitle: String {
        let parts = GitHubSource.shownGroups.filter { store.counts[$0] > 0 }.map { "\(store.counts[$0]) \($0.countLabel)" }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return store.hasLoaded ? "Nothing needs you" : "Your pull requests on GitHub, and the ones you review"
    }

    /// By Status or By Mission, while Pull Request Order is on.
    private var orderMenu: some View {
        Menu {
            Picker("Sort", selection: $settings.listsByMission) {
                Text("By Status").tag(false)
                Text("By Mission").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(listsByMission ? "By Mission" : "By Status", systemImage: "arrow.up.arrow.down")
                .font(size: 13)
        }
        .menuStyle(.button)
        .glassButtonStyle()
        .fixedSize()
        .help("By Status groups them by what they need from you; By Mission lists the ones that go together, in the order they merge")
        .accessibilityLabel("Sort Pull Requests")
        .accessibilityValue(listsByMission ? "By Mission" : "By Status")
    }

    @ViewBuilder
    private var notices: some View {
        if let problem = store.problem {
            ProblemView(problem: problem) { store.signIn() }
        }
        if let notice = store.notice {
            Label(notice, systemImage: "info.circle")
                .font(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if store.isAllQuiet {
            QuietView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if !store.hasLoaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your pull requests…")
                    .font(style: .body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private var byMissionBody: some View {
        let byRef = Dictionary(store.items.map { (Self.ref(of: $0), $0) }, uniquingKeysWith: { first, _ in first })
        return MissionsBody(
            view: view ?? ordering.view, ordering: ordering, kinds: Self.kinds, elsewhere: "Azure DevOps",
            openElsewhere: services.hasPage(.azureDevOpsPullRequests) ? { services.openWindow(.azureDevOpsPullRequests) } : nil,
            listed: store.items.map(Self.ref(of:)),
            row: { step, mission in
                byRef[step.ref].map { item in
                    AnyView(row(item, order: OrderRowContext(step: step, mission: mission, isReady: item.group == .ready)))
                }
            },
            place: { byRef[$0]?.pullRequest.repository }, isSelected: { _ in false },
            select: { ref in
                guard let item = byRef[ref] else { return false }
                store.open(item)
                return true
            },
            rest: { refs in AnyView(groups(refs.compactMap { byRef[$0] })) }
        )
    }

    /// The groups, each in a card: every pull request By Status, or those in no mission By Mission.
    private func groups(_ items: [GitHubPRSnapshot]) -> some View {
        let shown = GitHubPRGroup.allCases.filter { group in items.contains { $0.group == group } }
        return ForEach(shown, id: \.self) { group in
            section(group, items.filter { $0.group == group })
        }
    }

    private func section(_ group: GitHubPRGroup, _ items: [GitHubPRSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.color)
                Text(group.title)
                    .foregroundStyle(.primary)
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(size: 12, weight: .semibold)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 44).padding(.trailing, 12)
                    }
                    row(item)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
            .background(GlassCard(cornerRadius: 18))
        }
    }

    /// - Parameter order: where it stands in the mission whose card it's in; nil elsewhere, for the one its capsule speaks
    ///   for.
    private func row(_ item: GitHubPRSnapshot, order: OrderRowContext? = nil) -> PRRowView {
        PRRowView(item: item, now: store.now, order: order ?? rowOrder(item)) { store.open(item) }
    }

    /// Where a pull request stands in its mission, for its capsule, while Pull Request Order is on: By Status, a click on
    /// it shows the mission By Mission.
    private func rowOrder(_ item: GitHubPRSnapshot) -> OrderRowContext? {
        guard ordering.isOn else { return nil }
        let byMission = listsByMission
        return OrderRowContext.of(Self.ref(of: item), in: ordering.missions, isReady: item.group == .ready, open: byMission ? nil : { key in
            settings.listsByMission = true
            ordering.reveal(key)
        })
    }

    @ViewBuilder
    private var more: some View {
        if store.moreThanShown {
            Button {
                store.openPullRequestsPage()
            } label: {
                Label("More on GitHub", systemImage: "arrow.up.forward")
            }
            .buttonStyle(.borderless)
            .font(size: 12)
            .padding(.horizontal, 4)
            .help("BriefBar shows your 50 most recently changed pull requests of each kind")
        }
    }

    static func ref(of item: GitHubPRSnapshot) -> ItemRef {
        .gitHubPullRequest(repository: item.pullRequest.repository, number: item.pullRequest.number)
    }
}
