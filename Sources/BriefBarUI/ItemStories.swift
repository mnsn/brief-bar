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
    /// Reads more of a thing than its story says, for a summary only, as one is written: a session's conversation, a
    /// pull request's description and comments. Each part has a label and its text, cut to fit; none when the source
    /// has nothing more.
    package typealias ContextReader = @MainActor (ItemRef) async -> [ItemStory.Fact]

    private struct Registration {
        var kinds: Set<ItemRef.Kind>
        var tell: Teller
    }

    private struct ContextRegistration {
        var kinds: Set<ItemRef.Kind>
        var read: ContextReader
    }

    /// A story as told, for the version of the row it was told for.
    private struct Told {
        var story: ItemStory?
        var version: String
        var at: Date
    }

    /// A story being told: for which version of its row, and which request is telling it, which alone may say what was
    /// told, so a request that was taken back, or replaced, never does; and its task, which whoever else asks for the same
    /// row waits for (`tell(_:)`).
    private struct Telling {
        var version: String
        var token: Int
        var task: Task<Void, Never>
    }

    /// How long a story is kept once told: what it says has moved on by then.
    static let lifetime: TimeInterval = 15 * 60
    /// How long it's current while its row stays the same: a session's checkpoints come without its state changing.
    static let freshFor: TimeInterval = 60

    /// The sources that stop, as each does, once what they told is gone: what was made of it, such as a summary, goes too.
    package let withdrawn = PassthroughSubject<SourceID, Never>()

    private let links: Links
    private var tellers: [SourceID: Registration] = [:]
    private var readers: [SourceID: ContextRegistration] = [:]
    @Published private var told: [ItemRef: Told] = [:]
    @Published private var telling: [ItemRef: Telling] = [:]
    private var nextToken = 0
    private var cancellable: AnyCancellable?
    /// For tests: what "now" is.
    var now: () -> Date = Date.init

    package init(links: Links) {
        self.links = links
        // Turning Show Links off forgets every story.
        cancellable = links.$isOn.removeDuplicates().filter { !$0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetAll() } }
    }

    /// Forgets every story, and stops telling them: what's asked and not read yet isn't read.
    private func forgetAll() {
        for telling in telling.values { telling.task.cancel() }
        told = [:]
        telling = [:]
    }

    // MARK: The sources

    /// A source tells about these kinds of its things from now on, replacing what it told before.
    package func register(_ source: SourceID, kinds: Set<ItemRef.Kind>, teller: @escaping Teller) {
        tellers[source] = Registration(kinds: kinds, tell: teller)
        forget(kinds)
    }

    /// A source reads more of these kinds of its things for summaries from now on (`context(for:)`), replacing what read
    /// them before. Withdrawing the source takes it back too.
    package func registerContext(_ source: SourceID, kinds: Set<ItemRef.Kind>, reader: @escaping ContextReader) {
        readers[source] = ContextRegistration(kinds: kinds, read: reader)
    }

    /// A source stopped: what it told goes with it, and it reads nothing more for summaries.
    package func withdraw(_ source: SourceID) {
        let reader = readers.removeValue(forKey: source)
        guard let registration = tellers.removeValue(forKey: source) else {
            if reader != nil { withdrawn.send(source) }
            return
        }
        forget(registration.kinds)
        withdrawn.send(source)
    }

    private func forget(_ kinds: Set<ItemRef.Kind>) {
        for (ref, telling) in telling where kinds.contains(ref.kind) { telling.task.cancel() }
        told = told.filter { !kinds.contains($0.key.kind) }
        telling = telling.filter { !kinds.contains($0.key.kind) }
    }

    // MARK: What views show

    /// What's been told of a thing, while it's current.
    package func story(for ref: ItemRef) -> ItemStory? {
        guard links.isOn, let told = told[ref], now().timeIntervalSince(told.at) < Self.lifetime else { return nil }
        return told.story
    }

    /// Tells a thing's story again the next time it's asked for, as when more of it was read, such as a work item's
    /// details: what was told shows until then, and one being told now is told again.
    package func invalidate(_ ref: ItemRef) {
        told[ref]?.version = ""
        if let current = telling[ref] { start(ref, version: current.version) }
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
        start(item.ref, version: version)
    }

    /// Tells every one of them and waits, for a summary and for `--render`: one being told already for the row as it is,
    /// as the details asked, is waited for rather than told again. Once the task that waits is cancelled, it asks nothing
    /// more, and what it asked is taken back.
    package func tell(_ items: [LinkedItem]) async {
        for item in items {
            guard !Task.isCancelled else { return }
            await tell(item)
        }
    }

    /// Tells one, or waits while it's told. Whoever asked for what it waits for may take it back before it's told: then
    /// it's asked again, a few times at most.
    private func tell(_ item: LinkedItem) async {
        let version = Self.version(of: item)
        for _ in 0..<3 {
            guard !Task.isCancelled else { return }
            if let current = telling[item.ref], current.version == version {
                await current.task.value
            } else if needsTelling(item.ref, version: version) {
                let task = start(item.ref, version: version)
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            } else {
                return
            }
        }
    }

    private func needsTelling(_ ref: ItemRef, version: String) -> Bool {
        guard links.isOn, tellers.values.contains(where: { $0.kinds.contains(ref.kind) }) else { return false }
        sweep()
        if telling[ref]?.version == version { return false }
        guard let told = told[ref] else { return true }
        return told.version != version || now().timeIntervalSince(told.at) >= Self.freshFor
    }

    /// Starts telling a story, in place of any telling it for an older row: that one's work is taken back.
    @discardableResult
    private func start(_ ref: ItemRef, version: String) -> Task<Void, Never> {
        telling[ref]?.task.cancel()
        nextToken += 1
        let token = nextToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.tell(ref, token: token)
        }
        telling[ref] = Telling(version: version, token: token, task: task)
        return task
    }

    /// Whether a request is still the one telling a story, while Show Links is on: not taken back by turning Show Links off,
    /// by its source stopping or starting again, or by a newer request.
    private func isCurrent(_ ref: ItemRef, token: Int) -> Bool {
        links.isOn && !Task.isCancelled && telling[ref]?.token == token
    }

    /// Asks each source that tells about its kind, in the sources' order, and puts together what they tell. Each is asked
    /// only while the request is current, so nothing is read for one that was taken back. However it ends, the story isn't
    /// being told by this request anymore, though one that took its place may tell it.
    private func tell(_ ref: ItemRef, token: Int) async {
        defer {
            if telling[ref]?.token == token { telling[ref] = nil }
        }
        var story: ItemStory?
        for source in SourceID.allCases {
            guard isCurrent(ref, token: token) else { return }
            guard let registration = tellers[source], registration.kinds.contains(ref.kind) else { continue }
            guard let told = await registration.tell(ref) else { continue }
            story = story.map { $0.merged(with: told) } ?? told
        }
        guard isCurrent(ref, token: token), let version = telling[ref]?.version else { return }
        told[ref] = Told(story: story.flatMap { $0.isEmpty ? nil : $0 }, version: version, at: now())
    }

    // MARK: More, for a summary

    /// What the sources read of each of these things for a summary, now: each source that reads more of a thing's kind is
    /// asked in the sources' order, and a part a source before it gave, by its label, isn't taken twice. Nothing is kept,
    /// and nothing more is read once Show Links goes off or the task that asks is cancelled.
    package func context(for refs: [ItemRef]) async -> [ItemRef: [ItemStory.Fact]] {
        var context: [ItemRef: [ItemStory.Fact]] = [:]
        for ref in refs where context[ref] == nil {
            var parts: [ItemStory.Fact] = []
            for source in SourceID.allCases {
                guard links.isOn, !Task.isCancelled else { return context }
                guard let reader = readers[source], reader.kinds.contains(ref.kind) else { continue }
                for part in await reader.read(ref) where !part.value.isEmpty && !parts.contains(where: { $0.label == part.label }) {
                    parts.append(part)
                }
            }
            context[ref] = parts
        }
        return context.filter { !$0.value.isEmpty }
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
