import BriefBarCore
import Foundation
import SwiftUI
import Testing
@testable import BriefBarUI

@MainActor
@Suite struct LinksHubTests {
    private let workItem = ItemRef.workItem(organization: "contoso", id: 5101)
    private let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4071)
    private let gitHubPullRequest = ItemRef.gitHubPullRequest(repository: "octo/shop-web", number: 12)
    private let session = ItemRef.session("6f9619ff-8b86-d011-b42d-00c04fc964ff")!

    private func item(_ ref: ItemRef, _ title: String, state: ItemState? = nil, hint: BranchHint? = nil) -> LinkedItem {
        LinkedItem(ref: ref, label: ref.id, title: title, symbol: "circle", color: .secondary, state: state, hint: hint)
    }

    private func on(_ defaults: MemoryDefaults = MemoryDefaults()) -> Links {
        let links = Links(defaults: defaults, isDemo: false)
        links.setOn(true)
        return links
    }

    @Test func itsOffUntilYouTurnItOnAndShowsNothingThen() {
        let defaults = MemoryDefaults()
        let links = Links(defaults: defaults, isDemo: false)
        #expect(!links.isOn)
        links.publish(.azureDevOps, links: [ItemLink(pullRequest, workItem, origin: .azureDevOps)!], items: [])
        #expect(links.connections(of: workItem).isEmpty)
        #expect(links.unknown([.workItem, .pullRequest]).isEmpty)
        links.setOn(true)
        #expect(links.connections(of: workItem).map(\.item.ref) == [pullRequest])
        #expect(Links(defaults: defaults, isDemo: false).isOn)
        // The demo shows them, in preferences that are thrown away.
        #expect(Links(defaults: MemoryDefaults(), isDemo: true).isOn)
    }

    @Test func aSessionOnAPullRequestsBranchIsLinkedWhicheverSourcesListThem() {
        let links = on()
        links.publish(.azureDevOps, links: [], items: [
            item(pullRequest, "Fix the coupon rounding", hint: BranchHint(branch: "coupon-rounding", target: "main", repositories: ["shop-web"])),
        ])
        links.publish(.copilot, links: [], items: [
            item(session, "Round coupons", state: .needsYou, hint: BranchHint(branch: "coupon-rounding", repositories: ["shop-web"])),
        ])
        let connections = links.connections(of: pullRequest)
        #expect(connections.map(\.item.ref) == [session])
        #expect(connections.first?.origins == [.branch])
        #expect(connections.first?.item.title == "Round coupons")
        // Once Copilot stops, its sessions and their links go.
        links.withdraw(.copilot)
        #expect(links.connections(of: pullRequest).isEmpty)
    }

    @Test func whatNoSourceDescribesIsLookedUpAndShownByItsReferenceMeanwhile() {
        let links = on()
        links.publish(.azureDevOps, links: [ItemLink(pullRequest, workItem, origin: .azureDevOps)!], items: [
            item(pullRequest, "Fix the coupon rounding"),
        ])
        #expect(links.unknown([.workItem, .pullRequest]) == [workItem])
        #expect(links.connections(of: pullRequest).first?.item.title == "Work item 5101")
        links.publish(.azureDevOps, links: [ItemLink(pullRequest, workItem, origin: .azureDevOps)!], items: [
            item(pullRequest, "Fix the coupon rounding"), item(workItem, "Round coupons half up"),
        ])
        #expect(links.unknown([.workItem, .pullRequest]).isEmpty)
        #expect(links.connections(of: pullRequest).first?.item.title == "Round coupons half up")
        // What's linked stays linked, described or not, for its source to tell from what it lists.
        #expect(links.linked([.workItem]) == [workItem])
        #expect(links.linked([.session]).isEmpty)
        // A GitHub pull request or a session can be opened by its reference alone.
        #expect(Links.fallback(gitHubPullRequest).open != nil)
        #expect(Links.fallback(session).open != nil)
        #expect(Links.fallback(workItem).open == nil)
    }

    @Test func unlinkingWhatAzureDevOpsLinksHidesItHereAndYourOwnLinksGo() {
        let defaults = MemoryDefaults()
        let links = on(defaults)
        links.publish(.azureDevOps, links: [ItemLink(pullRequest, workItem, origin: .azureDevOps)!], items: [])
        links.unlink(workItem, pullRequest)
        #expect(links.connections(of: workItem).isEmpty)
        #expect(links.connections(of: workItem, includingHidden: true).map(\.isHidden) == [true])
        links.showAgain(pullRequest, workItem)
        #expect(links.isLinked(workItem, pullRequest))

        links.link(session, workItem)
        #expect(links.connections(of: workItem).map(\.item.ref) == [pullRequest, session])
        #expect(links.connections(of: session).first?.origins == [.you])
        links.unlink(session, workItem)
        #expect(links.connections(of: session).isEmpty)
        #expect(links.connections(of: session, includingHidden: true).isEmpty)
        #expect(defaults.object(forKey: LinkEdits.defaultsKey) == nil)
    }

    @Test func yourLinksOutlastARestartAndGoWithTheSourceYouTurnOff() {
        let defaults = MemoryDefaults()
        let links = on(defaults)
        links.link(session, workItem)
        links.link(session, gitHubPullRequest)
        #expect(Links(defaults: defaults, isDemo: false).connections(of: session).count == 2)

        links.forget(.copilot)
        #expect(links.connections(of: workItem).isEmpty)
        #expect(Links(defaults: defaults, isDemo: false).connections(of: session).isEmpty)
        links.link(session, workItem)
        links.forget(.github)
        #expect(links.connections(of: session).map(\.item.ref) == [workItem])
        links.forget(.azureDevOps)
        #expect(LinkEdits.load(from: defaults).isEmpty)
    }

    @Test func theOneThatNeedsYouMostShowsFirst() {
        let links = on()
        let other = ItemRef.session(UUID().uuidString)!
        links.publish(.copilot, links: [], items: [item(session, "Idle one"), item(other, "Asking", state: .needsYou)])
        links.link(workItem, session)
        links.link(workItem, other)
        links.link(workItem, pullRequest)
        #expect(links.connections(of: workItem).map(\.item.ref) == [pullRequest, other, session])
    }

    @Test func thePickerOffersWhatCanBeLinkedAndSuggestsWhatsOnTheBranch() {
        let links = on()
        let branch = BranchHint(branch: "coupon-rounding", target: "main", repositories: ["shop-web"])
        links.publish(.azureDevOps, links: [], items: [
            item(pullRequest, "Fix the coupon rounding", hint: branch), item(workItem, "Save items for later"),
        ])
        links.publish(.github, links: [], items: [item(gitHubPullRequest, "Speed up checkout")])
        links.publish(.copilot, links: [], items: [
            item(session, "Rounding", hint: BranchHint(branch: "coupon-rounding", repositories: ["shop-web"])),
        ])
        #expect(Set(links.candidates(for: session).map(\.ref)) == [pullRequest, workItem, gitHubPullRequest])
        #expect(Set(links.candidates(for: workItem).map(\.ref)) == [pullRequest, gitHubPullRequest, session])
        // What's linked by branch already isn't suggested again.
        #expect(links.suggestions(for: session, among: links.candidates(for: session)).isEmpty)
        links.unlink(session, pullRequest)
        #expect(links.suggestions(for: session, among: links.candidates(for: session)) == [pullRequest])
    }
}
