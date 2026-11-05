import Foundation

/// Where in a pull request a link BriefBar made leads: one of its comment threads, on its page
/// (`ADOEndpoint.pullRequestPage(…, threadId:)`), or one of its runs, on the run's page (`ADOEndpoint.buildPage`), such as
/// the run after its merge that failed. Its details in BriefBar's window can show it there instead of Azure DevOps.
public enum PullRequestPlace: Sendable, Hashable {
    case thread(Int)
    case run(Int)

    /// Nil for a link to the pull request itself, or to anything else.
    public init?(link: URL) {
        if case .run(let id)? = PipelineLink(link.absoluteString)?.target {
            self = .run(id)
            return
        }
        guard !PullRequestLink.find(in: link.absoluteString).isEmpty,
              let thread = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name.caseInsensitiveCompare("discussionId") == .orderedSame })?.value.flatMap(Int.init),
              thread > 0
        else { return nil }
        self = .thread(thread)
    }
}

extension PRSnapshot {
    /// Where its link leads in it, as its row opens it: the thread of the comment that needs you or that you answered, or
    /// the run after its merge that failed or waits for an approval. Nil when it opens the pull request itself.
    public var place: PullRequestPlace? {
        PullRequestPlace(link: url)
    }

    /// Whether its row is about your review of it: a review you're asked for, or the changes you asked for, or your
    /// rejection, which wait on its author. Its details show your part among its reviewers, with your vote.
    public var isAboutYourReview: Bool {
        switch reason {
        case .reviewRequested, .reviewPending, .waitingForAuthor: true
        default: false
        }
    }
}

extension PRKey {
    /// A key as it's written (`description`), "contoso/4102", as a notification keeps it; nil for anything else.
    public init?(description: String) {
        guard let slash = description.lastIndex(of: "/") else { return nil }
        let organization = String(description[..<slash])
        guard !organization.isEmpty, let number = Int(description[description.index(after: slash)...]), number > 0 else { return nil }
        self.init(organization, number)
    }
}
