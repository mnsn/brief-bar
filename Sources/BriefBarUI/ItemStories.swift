import BriefBarCore
import Combine
import Foundation

/// What the sources tell about their things beyond their rows (`ItemStory`), for the details: each source tells about its
/// own kinds of things, only when a view asks and only while Show Links is on, and what they tell is kept in memory only,
/// for a quarter of an hour at most.
@MainActor
package final class ItemStories: ObservableObject {
    /// Tells a thing's story, or nil when the source doesn't know it.
    package typealias Teller = @MainActor (ItemRef) async -> ItemStory?

    private struct Registration {
        var kinds: Set<ItemRef.Kind>
        var tell: Teller
    }

    /// A story as told, for the version of the row it was told for.
    private struct Told {
        var story: ItemStory?
        var version: String
        var at: Date
    }

    /// How long a story is kept once told: what it says has moved on by then.
    static let lifetime: TimeInterval = 15 * 60
    /// How long it's current while its row stays the same: a session's checkpoints come without its state changing.
    static let freshFor: TimeInterval = 60

    private let links: Links
    private var tellers: [SourceID: Registration] = [:]
    @Published private var told: [ItemRef: Told] = [:]
    @Published private var telling: [ItemRef: String] = [:]
    private var cancellable: AnyCancellable?
    /// For tests: what "now" is.
    var now: () -> Date = Date.init

    package init(links: Links) {
        self.links = links
        // Turning Show Links off forgets every story.
        cancellable = links.$isOn.removeDuplicates().filter { !$0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetAll() } }
    }

    private func forgetAll() {
        told = [:]
        telling = [:]
    }

    // MARK: The sources

    /// A source tells about these kinds of its things from now on, replacing what it told before.
    package func register(_ source: SourceID, kinds: Set<ItemRef.Kind>, teller: @escaping Teller) {
        tellers[source] = Registration(kinds: kinds, tell: teller)
        forget(kinds)
    }

    /// A source stopped: what it told goes with it.
    package func withdraw(_ source: SourceID) {
        guard let registration = tellers.removeValue(forKey: source) else { return }
        forget(registration.kinds)
    }

    private func forget(_ kinds: Set<ItemRef.Kind>) {
        told = told.filter { !kinds.contains($0.key.kind) }
        telling = telling.filter { !kinds.contains($0.key.kind) }
    }

    // MARK: What views show

    /// What's been told of a thing, while it's current.
    package func story(for ref: ItemRef) -> ItemStory? {
        guard links.isOn, let told = told[ref], now().timeIntervalSince(told.at) < Self.lifetime else { return nil }
        return told.story
    }

    /// Whether its story is being told now, for the first time or again.
    package func isTelling(_ ref: ItemRef) -> Bool {
        telling[ref] != nil
    }

    /// Whether anything was told of it, even that there's nothing to tell.
    package func hasTold(_ ref: ItemRef) -> Bool {
        told[ref] != nil
    }

    /// Asks for a thing's story, unless it's being told, or was told lately for the row as it is. Nothing while Show Links
    /// is off.
    package func request(_ item: LinkedItem) {
        let version = Self.version(of: item)
        guard needsTelling(item.ref, version: version) else { return }
        telling[item.ref] = version
        Task { [weak self] in await self?.tell(item.ref, version: version) }
    }

    /// Tells every one of them and waits, for `--render`.
    package func tell(_ items: [LinkedItem]) async {
        for item in items {
            let version = Self.version(of: item)
            guard needsTelling(item.ref, version: version) else { continue }
            telling[item.ref] = version
            await tell(item.ref, version: version)
        }
    }

    private func needsTelling(_ ref: ItemRef, version: String) -> Bool {
        guard links.isOn, tellers.values.contains(where: { $0.kinds.contains(ref.kind) }) else { return false }
        sweep()
        if telling[ref] == version { return false }
        guard let told = told[ref] else { return true }
        return told.version != version || now().timeIntervalSince(told.at) >= Self.freshFor
    }

    /// Asks each source that tells about its kind, in the sources' order, and puts together what they tell.
    private func tell(_ ref: ItemRef, version: String) async {
        let asked = SourceID.allCases.compactMap { tellers[$0] }.filter { $0.kinds.contains(ref.kind) }
        var story: ItemStory?
        for registration in asked {
            guard let told = await registration.tell(ref) else { continue }
            story = story.map { $0.merged(with: told) } ?? told
        }
        // A newer row asked again meanwhile, or the source stopped: that one's story counts.
        guard telling[ref] == version else { return }
        telling[ref] = nil
        guard links.isOn, tellers.values.contains(where: { $0.kinds.contains(ref.kind) }) else { return }
        told[ref] = Told(story: story.flatMap { $0.isEmpty ? nil : $0 }, version: version, at: now())
    }

    /// Forgets what was told too long ago.
    private func sweep() {
        let now = now()
        let stale = told.filter { now.timeIntervalSince($0.value.at) >= Self.lifetime }.map(\.key)
        for ref in stale { told[ref] = nil }
    }

    /// What tells a row's change: its state, its status, its title and when it last changed.
    static func version(of item: LinkedItem) -> String {
        [item.state?.rawValue ?? "", item.status ?? "", item.title, item.date.map { String($0.timeIntervalSince1970) } ?? ""]
            .joined(separator: "|")
    }
}
