import BriefBarCore
import Combine
import Foundation

/// Summarize with Copilot: a short summary of a thing and what's linked to it, which the Copilot CLI writes when you ask,
/// never by itself, from what the details show (`StorySummaryPrompt`), with no tools at all. It's off until you turn it
/// on, and works only while Show Links is on. A summary is kept in memory only, until BriefBar quits, it's dismissed, or
/// Show Links or this goes off, and says when what it summed up changed since.
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
        case written(StorySummary, at: Date, inputs: String, model: String)
        case failed(Problem, at: Date)
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
    private var tasks: [ItemRef: Task<Void, Never>] = [:]
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
        tasks[subject]?.cancel()
        let started = now()
        states[subject] = .writing(since: started)
        let options = Options(model: model, effort: "low")
        tasks[subject] = Task { [weak self] in
            guard let self else { return }
            // What's known of it and of each, as it is now.
            await self.stories.tell([self.links.describe(subject)] + self.links.connections(of: subject).map(\.item))
            guard self.isCurrent(subject, started: started) else { return }
            guard let input = self.input(for: subject) else {
                self.states[subject] = nil
                return
            }
            let answer: Result<String, Problem> = if let write = self.write {
                await write(input.prompt, options)
            } else {
                .failure(Problem("BriefBar can't ask the Copilot CLI here."))
            }
            self.finish(subject, started: started, answer: answer, inputs: input.inputs, model: options.model)
        }
    }

    /// Whether the summary started then is still the one being written.
    private func isCurrent(_ subject: ItemRef, started: Date) -> Bool {
        guard isAvailable, !Task.isCancelled, case .writing(let since)? = states[subject] else { return false }
        return since == started
    }

    /// Writes one and waits, for `--render`.
    package func summarizeAndWait(_ subject: ItemRef) async {
        summarize(subject)
        await tasks[subject]?.value
    }

    private func finish(_ subject: ItemRef, started: Date, answer: Result<String, Problem>, inputs: String, model: String) {
        // Taken back meanwhile: cancelled, dismissed, asked again, or turned off.
        guard isCurrent(subject, started: started) else { return }
        tasks[subject] = nil
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
        tasks.removeValue(forKey: subject)?.cancel()
        if case .writing? = states[subject] { states[subject] = nil }
    }

    /// Forgets one.
    package func dismiss(_ subject: ItemRef) {
        tasks.removeValue(forKey: subject)?.cancel()
        states[subject] = nil
    }

    /// Whether what a written summary summed up changed since: what's linked, or where one of them stands.
    package func isOutOfDate(_ subject: ItemRef) -> Bool {
        guard case .written(_, _, let inputs, _)? = states[subject] else { return false }
        return input(for: subject).map { $0.inputs != inputs } ?? true
    }

    private func forgetAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        states = [:]
    }

    // MARK: What's summed up

    /// The prompt for a thing and what's linked to it, as the details show them, the most pressing first; and what
    /// tells when that changes: each one's row as it is. Nil when nothing's linked to it.
    func input(for subject: ItemRef) -> (prompt: String, inputs: String)? {
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
        let inputs = ([described] + connections.map(\.item)).map { "\($0.ref)#\(ItemStories.version(of: $0))" }.joined(separator: ",")
        return (prompt, inputs)
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
