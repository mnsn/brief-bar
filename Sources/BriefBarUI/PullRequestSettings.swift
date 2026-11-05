import BriefBarCore

/// The Settings window's Pull Requests page: the settings about pull requests, each there and nowhere else in the window,
/// under the sources whose pull requests it works with. Those that work with several sources' come first, then each
/// source's own (`BriefBarSource.pullRequestSettings`), in the sources' order. They're kept where they always were, so
/// what a source's menu has of them is the same setting.
package enum PullRequestSettings {
    /// Settings that work with the same sources' pull requests.
    package struct Group: Equatable, Sendable {
        /// The sources whose pull requests they work with, while each is on.
        package var sources: [SourceID]
        /// Their names, in the order the page shows them.
        package var settings: [String]

        package init(sources: [SourceID], settings: [String]) {
            self.sources = sources
            self.settings = settings
        }
    }

    /// Those that work with several sources' pull requests: Pull Request Order, with Azure DevOps' and GitHub's.
    package static let shared = Group(sources: [.azureDevOps, .github], settings: [PullRequestOrderSettingView.title])

    /// The page's groups: `shared`, then each source's own, leaving out the sources without any.
    package static func groups(_ sources: [(id: SourceID, settings: [String])]) -> [Group] {
        [shared] + sources.filter { !$0.settings.isEmpty }.map { Group(sources: [$0.id], settings: $0.settings) }
    }

    /// Whether the page has settings for `source`'s pull requests, its own or shared, for its page to say where they are.
    package static func has(_ source: SourceID, ownSettings: [String]) -> Bool {
        !ownSettings.isEmpty || shared.sources.contains(source)
    }

    /// Where a group's settings work, as its heading says, from its sources' names: "Azure DevOps and GitHub", or
    /// "Azure DevOps only".
    package static func place(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return "\(last) only" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// What a group says while it doesn't work, as none of its sources is on, or nil while one is: that its source is off
    /// or paused, and when its settings work. A group of several sources works while any of them is on, with that one's
    /// pull requests.
    /// - Parameters:
    ///   - names: its sources' names, in its order.
    ///   - states: whether each of them is on, in the same order.
    ///   - count: how many settings it has.
    package static func notice(names: [String], states: [SourceState], count: Int) -> String? {
        guard !states.contains(.on), let first = names.first else { return nil }
        let work = count == 1 ? "it works" : "these work"
        if names.count > 1 {
            let neither = names.count == 2 ? "Neither \(first) nor \(names[1])" : "None of \(place(names))"
            return "\(neither) is on: \(work) with the pull requests of whichever you turn on."
        }
        if states.first == .needsReview {
            return "\(first) is paused until you look at what it reads now: \(work) once it's on again."
        }
        return "\(first) is off: \(work) once you turn it on."
    }
}
