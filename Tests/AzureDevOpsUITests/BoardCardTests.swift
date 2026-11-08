import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// The Board on Azure DevOps' page: Up Next's "2 more ›" from By Status, and what a card shows and VoiceOver says of it.
@MainActor
@Suite struct BoardCardTests {
    private static let account = "robin@contoso.com"
    private static let cart = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    private static func link(_ number: Int) -> String {
        "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/\(number)"
    }

    /// Pull Request Order, on, with orders sessions told: each one's pull requests in turn, each after the one before.
    private static func ordering(orders: [[Int]] = []) throws -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        var declared = DeclaredOrders()
        for numbers in orders {
            try declared.apply(OrderRequest(entries: numbers.enumerated().map { place, number in
                .init(link: link(number), after: place == 0 ? [] : ["\(numbers[place - 1])"])
            }))
        }
        declared.save(to: defaults)
        let ordering = PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        ordering.publish(
            .azureDevOps, pullRequests: orders.flatMap { $0 }.map { number in
                OrderPullRequest(
                    ref: ref(number), repository: "contoso/7a0c4e1d/repository-shop", sourceBranch: "robin/work-\(number)",
                    targetBranch: "main", author: "robin", createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
                )
            },
            account: account
        )
        return ordering
    }

    /// Its row in the list, in this group, saying this.
    private static func item(_ number: Int, group: PRGroup, headline: String, draft: Bool = false) throws -> PRSnapshot {
        let pullRequest = PullRequest(
            key: PRKey("contoso", number), title: "Pull request \(number)", author: DemoData.me,
            createdAt: Date(timeIntervalSince1970: 1_791_000_000), projectId: "7A0C4E1D", projectName: "Storefront",
            repositoryId: "Repository-Shop", repositoryName: "shop-web", sourceBranch: "robin/work-\(number)", targetBranch: "main",
            isDraft: draft
        )
        var item = try #require(PRClassifier.snapshot(
            for: PRRecord(pullRequest: pullRequest, role: .author, me: DemoData.me.id), seenCutoff: .distantPast,
            dismissedCutoff: .distantPast, now: Date(timeIntervalSince1970: 1_791_000_100)
        ))
        item.group = group
        item.headline = headline
        return item
    }

    /// Up Next's "2 more ›" lists the page By Mission, wherever it was, and shows the Board at that column.
    @Test func upNextsMoreFromByStatusShowsByMissionsBoardAtItsColumn() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.pullRequestOrder = .status
        let ordering = try Self.ordering()
        #expect(ordering.view == .list)

        PullRequestsPage.showColumn(.teammateReview, settings: settings, ordering: ordering)

        #expect(settings.pullRequestOrder == .byMission)
        #expect(ordering.view == .board)
        #expect(ordering.revealedColumn == .teammateReview)
    }

    /// A card says what needs you, what failed and a draft, as its row does, each only where its stage's why doesn't.
    @Test func aCardFlagsOnlyWhatItsStageDoesntSay() throws {
        func flags(_ item: PRSnapshot, _ reading: StageReading) -> [String] {
            PullRequestBoardCard.flags(item, reading: reading).map(\.text)
        }
        let asked = try Self.item(4110, group: .needsYou, headline: "Sam asked you to review")
        #expect(flags(asked, StageReading(stage: .yourReview, why: .asked("Sam asked you"))) == ["Sam asked you to review"])

        let failing = try Self.item(4088, group: .failing, headline: "Build failed")
        // In progress for what failed says so already; Waits doesn't.
        #expect(flags(failing, StageReading(stage: .inProgress, why: .failing("Build failed"))).isEmpty)
        let waits = StageReading(stage: .waits, why: .waitsFor([Self.ref(4085)], words: "After !4085"))
        #expect(flags(failing, waits) == ["Build failed"])
        #expect(PullRequestBoardCard.flags(failing, reading: waits).map(\.symbol) == ["xmark.circle.fill"])

        let draft = try Self.item(4105, group: .waiting, headline: "Draft", draft: true)
        #expect(flags(draft, StageReading(stage: .inProgress, why: .draft)).isEmpty)
        #expect(flags(draft, StageReading(stage: .teammateReview, why: .findReviewer)) == ["Draft"])

        let quiet = try Self.item(4120, group: .waiting, headline: "Waiting for reviewers")
        #expect(flags(quiet, StageReading(stage: .teammateReview, why: .waitingFor("Waiting on Sam"))).isEmpty)
    }

    /// VoiceOver hears, after its stage, its flags, where it stands in its order unless its stage says so, the session
    /// that told BriefBar it works on it unless its stage names it, and where it is.
    @Test func voiceOverHearsItsFlagsWhereItStandsWhoWorksOnItAndWhereItIs() throws {
        let ordering = try Self.ordering(orders: [[4085, 4093]])
        let order = try #require(OrderRowContext.of(Self.ref(4093), in: ordering.missions, isReady: false))
        let sentence = try #require(order.sentence)
        let item = try Self.item(4093, group: .needsYou, headline: "Sam wants changes")
        let changes = StageReading(stage: .inProgress, why: .changesWanted("Sam wants changes"))
        func details(_ reading: StageReading) -> [String] {
            PullRequestBoardCard.details(item, reading: reading, order: order, ordering: ordering)
        }

        #expect(details(changes) == ["Sam wants changes", sentence, "shop-web"])
        // Waits and Can merge say where it stands already.
        #expect(details(StageReading(stage: .waits, why: .waitsFor([Self.ref(4085)], words: "After !4085"))) == ["Sam wants changes", "shop-web"])
        #expect(details(StageReading(stage: .canMerge, why: .ready(autoComplete: false))) == ["Sam wants changes", "shop-web"])

        ordering.publish(
            .copilot,
            items: [LinkedItem(ref: Self.cart, label: "Cart", title: "Cart", symbol: "bolt.fill", color: .blue, state: nil, date: nil)],
            working: [Self.cart: [Self.ref(4093)]]
        )
        #expect(details(changes) == ["Sam wants changes", sentence, "Cart works on it", "shop-web"])
        #expect(PullRequestBoardCard.worker(on: Self.ref(4093), besides: changes, ordering: ordering)?.ref == Self.cart)

        // One its stage names, as "‘Cart’ is writing it" does, isn't said twice.
        let writing = StageReading(stage: .inProgress, why: .working(StageSession(ref: Self.cart, activity: .working, since: nil, name: "Cart")))
        #expect(PullRequestBoardCard.worker(on: Self.ref(4093), besides: writing, ordering: ordering) == nil)
        #expect(details(writing) == ["Sam wants changes", sentence, "shop-web"])
        let reviewing = StageSession(ref: Self.cart, activity: .working, since: nil, name: "Cart", isReview: true)
        #expect(PullRequestBoardCard.worker(
            on: Self.ref(4093), besides: StageReading(stage: .yourReview, why: .preReviewing(reviewing)), ordering: ordering
        ) == nil)
    }
}
