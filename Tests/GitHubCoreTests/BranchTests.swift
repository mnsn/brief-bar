import Foundation
import Testing
@testable import GitHubCore

@Suite struct BranchTests {
    @Test func readsTheBranchEachPullRequestMerges() throws {
        var object = Fixture.pullRequest(12)
        object["headRefName"] = "robin/tax-rounding"
        #expect(try Fixture.decoded(object).branch == "robin/tax-rounding")
        // Without one, as in an answer from before, it has none.
        #expect(try Fixture.decoded(Fixture.pullRequest(13)).branch == nil)
        #expect(PullRequestQuery.text.contains(" headRefName"))
    }

    @Test func theDemosPullRequestsHaveBranches() {
        let items = GitHubDemoData.load(now: Date()).items
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.pullRequest.branch?.isEmpty == false })
    }
}
