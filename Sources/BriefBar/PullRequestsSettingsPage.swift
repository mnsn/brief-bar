import BriefBarCore
import BriefBarUI
import SwiftUI

/// Settings' Pull Requests page: the settings about pull requests, each here and nowhere else in the window, under where it
/// works (`PullRequestSettings`): Pull Request Order, with Azure DevOps' and GitHub's pull requests, then each source's own,
/// which work only while it's on. While a source is off or paused, its settings show all the same, disabled, saying so, with
/// a way to its page. A source's menu that has some of them has the same settings.
struct PullRequestsSettingsPage: View {
    @ObservedObject var model: AppModel
    /// Pull Request Order: the app's, or, for `--render`, one of its own.
    @ObservedObject var order: PullRequestOrder
    /// Whether each source is on: as it is, or, for `--render`, as the picture shows it.
    let state: @MainActor (SourceID) -> SourceState
    var go: (SettingsDestination) -> Void

    static let title = "Pull Requests"
    static let symbol = "arrow.triangle.branch"
    static let summary = "What BriefBar does with your pull requests, each setting under the sources it works with"

    init(
        model: AppModel, order: PullRequestOrder? = nil, state: (@MainActor (SourceID) -> SourceState)? = nil,
        go: @escaping (SettingsDestination) -> Void
    ) {
        self.model = model
        self.order = order ?? model.services.pullRequestOrder
        self.state = state ?? { [model] in model.state(of: $0) }
        self.go = go
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol)
                    .font(style: .largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title)
                        .font(style: .title2, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.summary)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                ForEach(groups, id: \.sources) { group in
                    Section {
                        if let notice = notice(group) {
                            notice
                        }
                        settings(group)
                    } header: {
                        heading(group)
                    }
                }
            }
            .environment(\.inSettingsForm, true)
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Pull Request Order's, then each source's own.
    private var groups: [PullRequestSettings.Group] {
        PullRequestSettings.groups(model.sources.map { (id: $0.id, settings: $0.pullRequestSettings) })
    }

    @ViewBuilder
    private func settings(_ group: PullRequestSettings.Group) -> some View {
        if group == PullRequestSettings.shared {
            PullRequestOrderSettingView(order: order) { model.agents.pullRequestOrderChanged($0) }
        } else if let id = group.sources.first, let view = model.source(id)?.pullRequestSettingsView(state: state(id)) {
            view
        }
    }

    /// Where its settings work.
    private func heading(_ group: PullRequestSettings.Group) -> some View {
        let place = PullRequestSettings.place(names(group))
        return Text(place)
            .accessibilityLabel("Works with \(place)")
            .accessibilityAddTraits(.isHeader)
    }

    /// What it says while none of its sources is on, with a way to a source's page when it's its own.
    private func notice(_ group: PullRequestSettings.Group) -> PullRequestSettingsNotice? {
        let states = group.sources.map(state)
        guard let text = PullRequestSettings.notice(names: names(group), states: states, count: group.settings.count) else {
            return nil
        }
        guard group.sources.count == 1, let id = group.sources.first, let name = names(group).first else {
            return PullRequestSettingsNotice(text: text, action: nil)
        }
        let action = states.first == .needsReview
            ? PullRequestSettingsNotice.Action(title: "Review…", label: "Review \(name)…") { go(.source(id)) }
            : PullRequestSettingsNotice.Action(title: "Turn On…", label: "Turn On \(name)…") { go(.source(id)) }
        return PullRequestSettingsNotice(text: text, action: action)
    }

    private func names(_ group: PullRequestSettings.Group) -> [String] {
        group.sources.map { id in model.source(id)?.name ?? id.rawValue }
    }
}

/// A group's settings don't work now, and why: at the top of its box, with what to do.
struct PullRequestSettingsNotice: View {
    /// A way to its source's page.
    struct Action {
        let title: String
        /// What VoiceOver says, which names the source.
        let label: String
        let perform: () -> Void
    }

    let text: String
    let action: Action?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.perform)
                    .accessibilityLabel(action.label)
            }
        }
    }
}
