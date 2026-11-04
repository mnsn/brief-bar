import BriefBarCore
import Foundation

extension GitHubDemoData {
    /// The made-up pull requests, with what the order's query reads of each while Pull Request Order is on: in shop-api, a
    /// GitHub stack, its first pull request merged (#199), then #201, then #203; in shop-web, #409 targeting #405's
    /// branch, so it merges after it. Every other one merges into main.
    public static func load(now: Date = Date(), order: Bool) -> GitHubLoad {
        var load = load(now: now)
        guard order else { return load }
        for index in load.items.indices {
            load.items[index].pullRequest.order = orderFields(of: load.items[index].pullRequest)
        }
        return load
    }

    /// shop-api's GitHub stack.
    static let stack = GitHubStack(repository: "contoso/shop-api", number: 7, baseBranch: "main", members: [
        .init(position: 1, ref: .gitHubPullRequest(repository: "contoso/shop-api", number: 199), state: .merged),
        .init(position: 2, ref: .gitHubPullRequest(repository: "contoso/shop-api", number: 201), state: .open),
        .init(position: 3, ref: .gitHubPullRequest(repository: "contoso/shop-api", number: 203), state: .open),
    ])

    static func orderFields(of pullRequest: GitHubPullRequest) -> GitHubPullRequest.OrderFields {
        let base: String
        var inStack = false
        switch (pullRequest.repository, pullRequest.number) {
        case ("contoso/shop-api", 201):
            base = "main"
            inStack = true
        case ("contoso/shop-api", 203):
            base = "validate-coupons"
            inStack = true
        case ("contoso/shop-web", 409):
            base = "rename-cart-service"
        default:
            base = "main"
        }
        return GitHubPullRequest.OrderFields(baseBranch: base, isFork: false, defaultBranch: "main", stack: inStack ? stack : nil)
    }
}
