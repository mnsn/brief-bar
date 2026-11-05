import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsCore
@testable import AzureDevOpsUI

/// What `--json` writes of each pull request, which scripts read: each field under its name, as it always was.
@Suite struct SnapshotJSONTests {
    /// A pull request's detail is a line, as the lists show it, its branches as they are: how the classifier keeps the
    /// branches apart in it, for agents to get each quoted (`PRSnapshot.detailText`), isn't what `--json` writes.
    @Test func writesEachDetailAsALine() throws {
        let json = try #require(AzureDevOpsCommandLine.json(CommandLineOptions(arguments: [], demo: true)))
        let items = try #require(json["items"] as? [[String: Any]])
        let conflicts = try #require(items.first { $0["title"] as? String == "Rename the order status enum" })
        #expect(conflicts["reason"] as? String == "conflicts")
        #expect(conflicts["detail"] as? String == "rename-order-status into main")
        for item in items {
            #expect(item["detailText"] == nil)
            #expect(item["detail"] == nil || item["detail"] is String, "\(item["detail"] ?? "")")
        }
    }

    /// Every field a snapshot keeps is written, under its name, its detail under `detail`: none is left out of what
    /// `--json` writes as it's added (`PRSnapshot.CodingKeys`).
    @Test func writesEveryFieldOfASnapshot() throws {
        let record = PRRecord(pullRequest: makePR(4071), role: .author, details: makeDetails(for: makePR(4071)), me: People.me.id)
        let item = try #require(PRClassifier.snapshot(for: record, seenCutoff: t(-day), dismissedCutoff: t(-day), now: t(0)))
        let keys = Set(PRSnapshot.CodingKeys.allCases.map(\.stringValue))
        let fields = Mirror(reflecting: item).children.compactMap(\.label).map { $0 == "detailText" ? "detail" : $0 }
        #expect(Set(fields) == keys)
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(Set(written.keys).isSubset(of: keys))
        #expect(written["detail"] is String)
    }
}
