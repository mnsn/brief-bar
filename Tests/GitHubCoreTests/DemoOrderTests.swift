import BriefBarCore
import Foundation
import Testing
@testable import GitHubCore

/// The made-up pull requests read what an order needs only when asked, as the real query does.
@Suite struct DemoOrderTests {
    @Test func theDemoReadsWhatAnOrderNeedsOnlyWhenAsked() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(GitHubDemoData.load(now: now, order: false) == GitHubDemoData.load(now: now))
        #expect(GitHubDemoData.load(now: now, order: false).items.allSatisfy { $0.pullRequest.order == nil })

        let items = GitHubDemoData.load(now: now, order: true).items.map(\.pullRequest)
        #expect(items.allSatisfy { $0.order?.defaultBranch == "main" && $0.order?.isFork == false })
        let stacked = items.filter { $0.order?.stack != nil }.map { "\($0.repository)#\($0.number)" }
        #expect(Set(stacked) == ["contoso/shop-api#201", "contoso/shop-api#203"])
        let bases = Dictionary(uniqueKeysWithValues: items.map { ("\($0.repository)#\($0.number)", $0.order?.baseBranch) })
        #expect(bases["contoso/shop-api#203"] == "validate-coupons")
        #expect(bases["contoso/shop-web#409"] == "rename-cart-service")
        #expect(bases.filter { $0.value != "main" }.count == 2)
    }
}
