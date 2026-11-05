import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// What you leave in pull requests' details as you go, by pull request, kept above the views that show them, which come and
/// go as a page opens over the details, as a file's page shows in place of their parts, and as they show another pull
/// request: what you wrote in each composer that asks Copilot something (Explain, Fix, Resolve, Fix All), until you send it,
/// as `ThreadChanges` keeps your replies; and where each thread you changed, with your reply or its status, was as you first
/// did, for it to stay there while the details show its pull request (`held`), with whether its resolved threads show
/// (`showsResolved`). The details' comments and their files' pages
/// share both, beside the list and on a pull request's page over a work item's or another pull request's details. In memory
/// only: what you wrote goes once you send it, or as Send Work to Copilot or Azure DevOps is turned off, or someone else signs
/// in to the Azure CLI; where the threads were, once the details show their pull request no more (`showing`).
@MainActor
final class DetailsDrafts: ObservableObject {
    /// What you wrote in each composer, by pull request. Not published: what you type redraws its own composer only, and
    /// those that show the same composer elsewhere, which follow it (`wordsChanged`).
    private var words: [PRKey: [CopilotComposing: String]] = [:]
    /// Where each thread you changed was as you first did, by pull request, then by thread.
    private var held: [PRKey: [Int: PullRequestPanel.Thread.Held]] = [:]
    /// The pull requests whose details show their resolved threads, as you unfolded them, or as going to one of them did:
    /// with where threads were, for the same while.
    private var resolvedShown: Set<PRKey> = []
    /// Who's signed in to the Azure CLI, as the list last told.
    private var account: String?
    private var cancellables: Set<AnyCancellable> = []
    /// Which pull requests the details show (`follow`).
    private var following: AnyCancellable?

    /// A composer of a pull request's details.
    struct Composer: Hashable {
        var pullRequest: PRKey
        var composer: CopilotComposing
    }

    /// Which composer's words changed, as you write in it or they go: one that's open follows them, so the same composer open
    /// elsewhere, as in another window, neither writes over what you wrote there nor sends what's out of date.
    let wordsChanged = PassthroughSubject<Composer, Never>()

    /// - Parameter settings: what you wrote goes as Send Work to Copilot is turned off, which takes its composers away.
    init(settings: AppSettings? = nil) {
        settings?.$copilotEnabled.removeDuplicates().dropFirst()
            .sink { [weak self] isOn in
                guard !isOn else { return }
                MainActor.assumeIsolated { self?.forgetWords() }
            }
            .store(in: &cancellables)
    }

    // MARK: What you wrote

    /// What you wrote in a composer of a pull request's details, and haven't sent.
    func words(in composer: CopilotComposing, of pullRequest: PRKey) -> String {
        words[pullRequest]?[composer] ?? ""
    }

    /// Keeps what you wrote in a composer, until you send it: nothing once you've emptied it.
    func keep(_ text: String, in composer: CopilotComposing, of pullRequest: PRKey) {
        guard words(in: composer, of: pullRequest) != text else { return }
        var kept = words[pullRequest] ?? [:]
        kept[composer] = text.isEmpty ? nil : text
        words[pullRequest] = kept.isEmpty ? nil : kept
        wordsChanged.send(Composer(pullRequest: pullRequest, composer: composer))
    }

    /// What you wrote in a composer went: it's forgotten, unless you wrote more there since, as in the same composer in
    /// another window while it went.
    func sent(_ text: String, in composer: CopilotComposing, of pullRequest: PRKey) {
        guard words(in: composer, of: pullRequest) == text else { return }
        keep("", in: composer, of: pullRequest)
    }

    /// Sends what you wrote in a composer (`deliver`), and forgets it once it went, or was copied for you to paste: whatever
    /// became of the composer meanwhile. One that closed, or whose page went, calls its send off, but a session that took it
    /// has it all the same, as BriefBar's extension waits for what it does with it once it claimed it.
    func send(
        _ text: String, in composer: CopilotComposing, of pullRequest: PRKey,
        deliver: () async -> CopilotSending.Outcome
    ) async -> CopilotSending.Outcome {
        let outcome = await deliver()
        switch outcome {
        case .sent, .copied: sent(text, in: composer, of: pullRequest)
        case .notSent, .needsWindow: break
        }
        return outcome
    }

    /// Forgets what you wrote, in every composer, which those open follow.
    private func forgetWords() {
        let gone = words.flatMap { pullRequest, composers in composers.keys.map { Composer(pullRequest: pullRequest, composer: $0) } }
        words = [:]
        for composer in gone { wordsChanged.send(composer) }
    }

    // MARK: Where threads were

    /// Where each thread you changed in a pull request's details was as you first did, by its ID.
    func held(in pullRequest: PRKey) -> [Int: PullRequestPanel.Thread.Held] {
        held[pullRequest] ?? [:]
    }

    /// Keeps where a thread is, as you change it with your reply or its status, for it to stay there while the details show
    /// its pull request, however it stands: where it was as you first did, though you change it again; or, for one you
    /// marked as read there before (`read`, `PullRequestDetailsStore.readHolds`), where it was then, which stays once you
    /// mark it as unread.
    func hold(_ thread: PullRequestPanel.Thread, in pullRequest: PRKey, read: [Int: PullRequestPanel.Thread.Held] = [:]) {
        let changed = held(in: pullRequest)
        guard changed[thread.id] == nil else { return }
        objectWillChange.send()
        held[pullRequest, default: [:]][thread.id] = .holding(thread, changed: changed, read: read)
    }

    /// Whether a pull request's details show its resolved threads, which they keep as you go to a file's page and back, or
    /// a page shows over them, so that a thread you reactivated, still among them, is there to go back to.
    func showsResolved(in pullRequest: PRKey) -> Bool {
        resolvedShown.contains(pullRequest)
    }

    /// Shows or hides a pull request's resolved threads, as Show Resolved and Hide Resolved do, and going to one of them.
    func setShowsResolved(_ shows: Bool, in pullRequest: PRKey) {
        guard shows != showsResolved(in: pullRequest) else { return }
        objectWillChange.send()
        if shows { resolvedShown.insert(pullRequest) } else { resolvedShown.remove(pullRequest) }
    }

    /// The pull requests the details show now, the pages over them included, by their references: the one beside the list,
    /// and those whose pages show over it or over a work item's details. Where threads were in the others goes, so a thread
    /// you resolved in one is with the resolved ones once you come back to it, as it is, rather than where it was; and
    /// whether their resolved threads showed, which fold again.
    func showing(_ shown: Set<ItemRef>) {
        let gone = Set(held.keys).union(resolvedShown).filter { !shown.contains($0.linkRef) }
        guard !gone.isEmpty else { return }
        objectWillChange.send()
        for key in gone {
            held[key] = nil
            resolvedShown.remove(key)
        }
    }

    /// Follows which pull requests the details show (`showing`): beside the list, with the pages over them (`panel`), and as
    /// pages over a work item's details (`workItem`). Not what you went on from, to another work item, to come back to. As
    /// they are once each move is done, which changes them one after the other: not as they are between, as while a pull
    /// request's page over the details goes to show beside the list instead, its pages taken away first.
    func follow(_ panel: PullRequestDetailsStore, pagesOver workItem: WorkItemDetailsStore) {
        following = Publishers.Merge3(
            panel.$selected.map { _ in () },
            panel.$pages.map { _ in () },
            workItem.$pages.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak panel, weak workItem] in
            MainActor.assumeIsolated {
                let pages = (panel?.pages ?? []) + (workItem?.pages ?? [])
                self?.showing(Set(pages + [panel?.selected?.key.linkRef].compactMap { $0 }))
            }
        }
    }

    // MARK: Forgetting

    /// Forgets all of it, as Azure DevOps stops or someone else signs in.
    func forgetAll() {
        objectWillChange.send()
        forgetWords()
        held = [:]
        resolvedShown = []
    }

    /// Stops for good, when Azure DevOps stops: all of it goes, and nothing's followed anymore.
    func stop() {
        following = nil
        cancellables = []
        forgetAll()
    }

    /// Someone signed in to the Azure CLI, as the list tells: when it's someone else than before, what you wrote was as the
    /// last one, and goes, as your replies do.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        forgetAll()
    }
}
