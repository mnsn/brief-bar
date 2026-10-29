import BriefBarCore
import Combine
import Foundation

/// Summarize with Copilot: a short summary of a thing and what's linked to it, which the Copilot CLI writes when you ask,
/// never by itself, from what the details show (`StorySummaryPrompt`), with no tools at all. It's off until you turn it
/// on, and works only while Show Links is on. A summary is kept in memory only, until BriefBar quits, it's dismissed, Show
/// Links or this goes off, or a source stops, and says when what it summed up changed since. One being written stops then,
/// with Copilot.
@MainActor
package final class StorySummaries: ObservableObject {
    package static let enabledKey = "summaries.copilot.enabled"
    package static let modelKey = "summaries.copilot.model"
    /// A small, quick model: a summary needs little thinking.
    package static let defaultModel = "claude-haiku-5.5"

    /// The model, and how hard it thinks.
    package struct Options: Equatable, Sendable {
        package var model: String
        package var effort: String?

        package init(model: String, effort: String? = nil) {
            self.model = model
            self.effort = effort
        }
    }

    /// A model to choose, by its ID and its name.
    package struct Model: Equatable, Sendable, Identifiable {
        package var id: String
        package var name: String

        package init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Writes an answer to a prompt, or says why it can't, in a sentence.
    package typealias Writer = @Sendable (_ prompt: String, _ options: Options) async -> Result<String, Problem>

    /// Why there's no summary, in a sentence.
    package struct Problem: Error, Equatable, Sendable {
        package var message: String

        package init(_ message: String) {
            self.message = message
        }
    }

    /// A summary as it stands for one thing.
    package enum State: Equatable {
        /// Copilot is writing it.
        case writing(since: Date)
        /// What it wrote, with what it summed up then, to tell when that changed.
        case written(StorySummary, at: Date, inputs: [Input], model: String)
        case failed(Problem, at: Date)
    }

    /// One of the things a summary summed up, as it was then: the thing itself, or one linked to it. What it says leaves out
    /// any date or how long ago, so time passing alone doesn't change it.
    package struct Input: Equatable, Sendable {
        package var ref: ItemRef
        /// What a sentence calls it: "5101", "!4120", or a session's name.
        package var label: String
        /// What its row says: its state, its title and its status.
        package var row: String
        /// What its story said: where it stands, its facts, its runs' names and how they stand, and how many checkpoints
        /// Copilot recorded and what it said last; nil when its story wasn't known.
        package var story: String?

        package init(ref: ItemRef, label: String, row: String, story: String?) {
            self.ref = ref
            self.label = label
            self.row = row
            self.story = story
        }

        /// Whether it says something else now: its row, or its story, when it's known both then and now. A story known only
        /// then or only now, such as one that's been forgotten since, says nothing either way.
        func differs(from now: Input) -> Bool {
            if row != now.row { return true }
            guard let then = story, let now = now.story else { return false }
            return then != now
        }
    }

    @Published package private(set) var isOn: Bool
    @Published package private(set) var model: String
    @Published private var states: [ItemRef: State] = [:]
    /// The models Settings offers; the app fills it in.
    package var models: [Model] = [Model(id: StorySummaries.defaultModel, name: "Claude Haiku 5.5")]
    /// Asks Copilot; nil until the app sets it, and then summaries can't be written.
    package var write: Writer?
    /// For tests: what "now" is.
    var now: () -> Date = Date.init

    private let defaults: UserDefaults
    private let links: Links
    private let stories: ItemStories
    /// The summaries being written: which request writes each, which alone may say what was written, and its task.
    private var writing: [ItemRef: (token: Int, task: Task<Void, Never>)] = [:]
    private var nextToken = 0
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameter isDemo: the demo shows made-up summaries, in preferences that are thrown away.
    package init(defaults: UserDefaults, links: Links, stories: ItemStories, isDemo: Bool) {
        self.defaults = defaults
        self.links = links
        self.stories = stories
        isOn = isDemo || defaults.bool(forKey: Self.enabledKey)
        model = defaults.string(forKey: Self.modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModel
        // Turning Show Links off forgets every summary, and stops writing them.
        links.$isOn.removeDuplicates().filter { !$0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetAll() } }
            .store(in: &cancellables)
        // So does a source that stops: what it said goes with it, and any summary may say it.
        links.withdrawn.merge(with: stories.withdrawn)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetAll() } }
            .store(in: &cancellables)
        // Whether one written is out of date changes with what's linked, and what's told of each: what shows it looks again.
        links.objectWillChange.merge(with: stories.objectWillChange)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.lookAgain() } }
            .store(in: &cancellables)
    }

    private func lookAgain() {
        guard states.values.contains(where: { if case .written = $0 { true } else { false } }) else { return }
        objectWillChange.send()
    }

    /// Whether ✨ Summarize shows: this is on, and so is Show Links.
    package var isAvailable: Bool { isOn && links.isOn }

    package func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.enabledKey)
        Log.app.info("Summarize with Copilot \(on ? "on" : "off", privacy: .public)")
        if !on { forgetAll() }
    }

    package func setModel(_ model: String) {
        guard !model.isEmpty, model != self.model else { return }
        self.model = model
        defaults.set(model, forKey: Self.modelKey)
    }

    /// The model's name, as Settings says it.
    package func name(of model: String) -> String {
        models.first { $0.id == model }?.name ?? model
    }

    // MARK: Summaries

    package func state(for subject: ItemRef) -> State? {
        states[subject]
    }

    /// Asks Copilot for a summary of a thing and what's linked to it, as the details show them now, in place of the one
    /// it has. Nothing unless this and Show Links are on.
    package func summarize(_ subject: ItemRef) {
        guard isAvailable, !links.connections(of: subject).isEmpty else { return }
        writing[subject]?.task.cancel()
        nextToken += 1
        let token = nextToken
        states[subject] = .writing(since: now())
        let options = Options(model: model, effort: "low")
        let task = Task { [weak self] in
            guard let self else { return }
            // What's known of it and of each, as it is now.
            await self.stories.tell([self.links.describe(subject)] + self.links.connections(of: subject).map(\.item))
            guard self.isCurrent(subject, token: token) else { return }
            guard let input = self.input(for: subject) else {
                self.writing[subject] = nil
                self.states[subject] = nil
                return
            }
            let answer: Result<String, Problem> = if let write = self.write {
                await write(input.prompt, options)
            } else {
                .failure(Problem("BriefBar can't ask the Copilot CLI here."))
            }
            self.finish(subject, token: token, answer: answer, inputs: input.inputs, model: options.model)
        }
        writing[subject] = (token, task)
    }

    /// Whether a request is still the one writing a summary: not cancelled, dismissed, asked again, taken back by a source
    /// that stopped, or turned off.
    private func isCurrent(_ subject: ItemRef, token: Int) -> Bool {
        isAvailable && !Task.isCancelled && writing[subject]?.token == token
    }

    /// Writes one and waits, for `--render`.
    package func summarizeAndWait(_ subject: ItemRef) async {
        summarize(subject)
        await writing[subject]?.task.value
    }

    private func finish(_ subject: ItemRef, token: Int, answer: Result<String, Problem>, inputs: [Input], model: String) {
        // Taken back meanwhile: cancelled, dismissed, asked again, or turned off.
        guard isCurrent(subject, token: token) else { return }
        writing[subject] = nil
        switch answer {
        case .success(let text):
            if let summary = StorySummary.parse(text) {
                states[subject] = .written(summary, at: now(), inputs: inputs, model: model)
            } else {
                states[subject] = .failed(Problem("Copilot answered nothing."), at: now())
            }
        case .failure(let problem):
            Log.app.error("Summary not written")
            states[subject] = .failed(problem, at: now())
        }
    }

    /// Stops writing one.
    package func cancel(_ subject: ItemRef) {
        writing.removeValue(forKey: subject)?.task.cancel()
        if case .writing? = states[subject] { states[subject] = nil }
    }

    /// Forgets one.
    package func dismiss(_ subject: ItemRef) {
        writing.removeValue(forKey: subject)?.task.cancel()
        states[subject] = nil
    }

    /// Whether what a written summary summed up changed since: what's linked, or what one of them says.
    package func isOutOfDate(_ subject: ItemRef) -> Bool {
        whatChanged(subject) != nil
    }

    /// What changed since a written summary, in a sentence: "!4120 changed", "!4120 and 5103 changed; !4130 was linked".
    /// Nil while it's current, and for one that isn't written.
    package func whatChanged(_ subject: ItemRef) -> String? {
        guard case .written(_, _, let then, _)? = states[subject] else { return nil }
        let now = inputs(for: subject)
        let before = Dictionary(then.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(now.map(\.ref))
        let changed = now.filter { input in before[input.ref]?.differs(from: input) ?? false }
        let linked = now.filter { before[$0.ref] == nil }
        let unlinked = then.filter { !after.contains($0.ref) }
        let said = [
            changed.isEmpty ? nil : Self.list(changed.map(Self.name)) + " changed",
            linked.isEmpty ? nil : Self.list(linked.map(Self.name)) + (linked.count == 1 ? " was linked" : " were linked"),
            unlinked.isEmpty ? nil : Self.list(unlinked.map(Self.name)) + (unlinked.count == 1 ? " was unlinked" : " were unlinked"),
        ].compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: "; ")
    }

    private func forgetAll() {
        for writing in writing.values { writing.task.cancel() }
        writing = [:]
        states = [:]
    }

    // MARK: What's summed up

    /// The prompt for a thing and what's linked to it, as the details show them, the most pressing first; and what tells
    /// when that changes: what each one says. Nil when nothing's linked to it.
    func input(for subject: ItemRef) -> (prompt: String, inputs: [Input])? {
        let connections = links.connections(of: subject).sorted { lhs, rhs in
            ItemState.rank(lhs.item.state) < ItemState.rank(rhs.item.state)
        }
        guard !connections.isEmpty else { return nil }
        let described = links.describe(subject)
        let item = { (linked: LinkedItem, link: String?) in
            StorySummaryPrompt.Item(
                kind: Self.kind(of: linked), label: linked.label, title: linked.title, status: linked.statusToShare, link: link,
                story: self.stories.story(for: linked.ref)
            )
        }
        let prompt = StorySummaryPrompt.make(
            subject: item(described, nil),
            linked: connections.map { item($0.item, $0.reason) }
        )
        return (prompt, inputs(for: subject))
    }

    /// The thing and what's linked to it, each as it says now.
    private func inputs(for subject: ItemRef) -> [Input] {
        ([links.describe(subject)] + links.connections(of: subject).map(\.item)).map { item in
            Self.input(item, story: stories.story(for: item.ref))
        }
    }

    /// What a thing says, as the prompt has it, to tell when that changes: its row's state, title and status, as it may be
    /// shared; and its story's sentence, facts, runs' names and how they stand, and how many checkpoints Copilot recorded
    /// and what it said last. No date goes in, nor do its notes or a failed run's error.
    static func input(_ item: LinkedItem, story: ItemStory?) -> Input {
        let story = story.map { story in
            var lines = [story.sentenceToShare]
            lines += story.facts.map { "\($0.label): \($0.value)" }
            lines += story.runs.map { "\($0.name): \($0.status)" }
            if let account = story.account, !account.isEmpty {
                lines += ["\(account.milestoneCount) checkpoints", account.lastMessage ?? ""]
            }
            return lines.joined(separator: "\n")
        }
        let row = [item.state?.rawValue ?? "", item.title, item.statusToShare ?? ""]
        return Input(ref: item.ref, label: item.label, row: row.joined(separator: "\n"), story: story)
    }

    /// What a sentence calls it: a work item's or a pull request's number, a session's name in quotes.
    static func name(_ input: Input) -> String {
        input.ref.kind == .session ? "“\(input.label)”" : input.label
    }

    /// "!4120", "!4120 and 5103", "!4120, 5103 and #12".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "Work item", "Pull request", "Copilot session", "Task sent to Copilot".
    static func kind(of item: LinkedItem) -> String {
        if item.sent != nil { return "Task sent to Copilot" }
        switch item.ref.kind {
        case .workItem: return "Work item"
        case .pullRequest, .gitHubPullRequest: return "Pull request"
        case .session: return "Copilot session"
        }
    }
}
