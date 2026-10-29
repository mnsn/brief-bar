import BriefBarCore
import Combine
import Foundation
import SwiftUI

/// On-demand summaries from Apple Intelligence on this Mac, or a model you choose through Copilot, with no tools.
/// Off until you turn it on, and only while Show Links is on. Summaries stay in memory and go away when either setting
/// goes off or a source stops. The saved keys keep existing consent and model choices.
@MainActor
package final class StorySummaries: ObservableObject {
    package static let enabledKey = "summaries.copilot.enabled"
    package static let modelKey = "summaries.copilot.model"
    nonisolated package static let appleIntelligenceModel = "apple-intelligence"
    package static let defaultModel = appleIntelligenceModel
    package static let appleIntelligence = Model(id: appleIntelligenceModel, name: "Apple Intelligence")

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

    /// Why there's no summary, in a sentence; what the provider said, as it said it, when the sentence says it in other
    /// words; and what would help, beside trying again.
    package struct Problem: Error, Equatable, Sendable {
        /// What would help, beside trying again.
        package enum Fix: Equatable, Sendable {
            /// Choosing another model, in the setting.
            case chooseModel
        }

        package var message: String
        package var detail: String?
        package var fix: Fix?

        package init(_ message: String, detail: String? = nil, fix: Fix? = nil) {
            self.message = message
            self.detail = detail
            self.fix = fix
        }
    }

    /// A summary as it stands for one thing.
    package enum State: Equatable {
        /// The selected model is writing it.
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
        /// What its story said, as the prompt has it but for its notes: where it stands, its facts, its runs and the first
        /// error of one that failed, and what Copilot recorded of its work; nil when its story wasn't known.
        package var story: String?
        /// Its story's notes, as the prompt has them, such as a work item's description and latest comments, when they
        /// were all read (`ItemStory.notesRead`): empty for none; nil when they weren't, or only some were.
        package var notes: String?

        package init(ref: ItemRef, label: String, row: String, story: String?, notes: String? = nil) {
            self.ref = ref
            self.label = label
            self.row = row
            self.story = story
            self.notes = notes
        }

        /// Whether it says something else now: its row; or its story, when it's known both then and now, with its notes
        /// when they were read both then and now, such as its first comment. A story known only then or only now, such as
        /// one that's been forgotten since, says nothing either way, and so do notes: a work item's are read only with its
        /// details.
        func differs(from now: Input) -> Bool {
            if row != now.row { return true }
            guard let story, let current = now.story else { return false }
            if story != current { return true }
            guard let notes, let currentNotes = now.notes else { return false }
            return notes != currentNotes
        }
    }

    @Published package private(set) var isOn: Bool
    @Published package private(set) var model: String
    @Published private var states: [ItemRef: State] = [:]
    /// The written ones you closed, kept to show again without generating another.
    @Published private var hidden: Set<ItemRef> = []
    /// Whether the Copilot CLI is there, as it was last looked for (`lookForCLI`); nil until then.
    @Published package private(set) var hasCLI: Bool?
    /// The models Settings offers; the app fills it in.
    package var models: [Model] = [appleIntelligence]
    /// Asks the selected provider; nil until the app sets it, and then summaries can't be written.
    package var write: Writer?
    /// Looks for the Copilot CLI, nil when it couldn't tell; nil where nothing's looked for, as in the demo.
    package var findCLI: (@Sendable () async -> Bool?)?
    /// Your name as each source knows it, while it's on, for a summary to call you "you".
    private var yourNames: [SourceID: @MainActor () -> String?] = [:]
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

    /// Sets how a source knows your name, or, with nil, that it doesn't: Azure DevOps, once it read your pull requests, or
    /// GitHub, your login.
    package func setYourName(_ source: SourceID, _ name: (@MainActor () -> String?)?) {
        yourNames[source] = name
    }

    /// Your name: as your pull requests have it in Azure DevOps, or else your GitHub login.
    var yourName: String? {
        for source in [SourceID.azureDevOps, .github] {
            if let name = yourNames[source]?(), !name.isEmpty { return name }
        }
        return nil
    }

    /// Whether ✨ Summarize shows: this is on, and so is Show Links.
    package var isAvailable: Bool { isOn && links.isOn }

    package func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.enabledKey)
        Log.app.info("Summaries \(on ? "on" : "off", privacy: .public)")
        if !on { forgetAll() }
    }

    package func setModel(_ model: String) {
        guard !model.isEmpty, model != self.model else { return }
        // Don't keep writing with a provider after the user switches away from it.
        for subject in Array(writing.keys) { cancel(subject) }
        self.model = model
        defaults.set(model, forKey: Self.modelKey)
    }

    package var usesOnDeviceModel: Bool { model == Self.appleIntelligenceModel }

    package var actionTitle: String {
        usesOnDeviceModel ? "Summarize with Apple Intelligence" : "Summarize with Copilot"
    }

    package var requestDescription: String { usesOnDeviceModel ? "on this Mac" : "1 request" }

    package func attribution(for model: String) -> String {
        model == Self.appleIntelligenceModel ? "Apple Intelligence on this Mac" : "\(name(of: model)) through GitHub Copilot"
    }

    /// The model's name, as Settings says it.
    package func name(of model: String) -> String {
        models.first { $0.id == model }?.name ?? model
    }

    /// Looks for the Copilot CLI while this is on, for Settings to say when it isn't there.
    package func lookForCLI() async {
        guard isAvailable, !usesOnDeviceModel, let findCLI, let found = await findCLI() else { return }
        hasCLI = found
    }

    // MARK: Summaries

    package func state(for subject: ItemRef) -> State? {
        states[subject]
    }

    /// Whether there's something to sum up: two things linked to it or more, or one and parts of its own, such as a story's
    /// tasks. Nothing while this or Show Links is off.
    package func hasSomethingToSum(_ subject: ItemRef) -> Bool {
        guard isAvailable else { return false }
        let linked = links.connections(of: subject).count
        return linked >= 2 || (linked == 1 && links.describe(subject).parts > 0)
    }

    /// Whether a pull request's or a session's row offers Summarize: this and Show Links are on, and a
    /// source says what it is. With nothing linked, its own story is what's summed up.
    package func canSummarize(_ subject: ItemRef) -> Bool {
        isAvailable && subject.kind != .workItem && links.isDescribed(subject)
    }

    /// For `--render`: a summary as it would stand, without asking a model.
    package func useForRendering(_ subject: ItemRef, state: State?) {
        states[subject] = state
    }

    /// Asks the selected provider for a summary of a thing and what's linked to it, as the details show them now, in
    /// place of the one it has; of a pull request or a session with nothing linked, of what's known of it. Nothing
    /// unless this and Show Links are on.
    package func summarize(_ subject: ItemRef) {
        guard isAvailable else { return }
        writing[subject]?.task.cancel()
        nextToken += 1
        let token = nextToken
        hidden.remove(subject)
        states[subject] = .writing(since: now())
        let options = Options(model: model, effort: usesOnDeviceModel ? nil : "low")
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
                .failure(Problem("BriefBar can't write summaries here."))
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
                // Once, wherever it shows.
                AccessibilityNotification.Announcement("Summary ready: \(links.describe(subject).title)").post()
            } else {
                Log.app.error("Summary response was empty")
                states[subject] = .failed(Problem("\(name(of: model)) answered nothing."), at: now())
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
        hidden.remove(subject)
    }

    /// Closes one, keeping it to show again for nothing, as long as it's kept; one that isn't written is forgotten.
    package func hide(_ subject: ItemRef) {
        guard case .written? = states[subject] else { return dismiss(subject) }
        hidden.insert(subject)
    }

    /// Shows one you closed again.
    package func show(_ subject: ItemRef) {
        hidden.remove(subject)
    }

    /// Whether you closed it, and it's kept.
    package func isHidden(_ subject: ItemRef) -> Bool {
        hidden.contains(subject)
    }

    /// What shows: its state, but nothing for one you closed.
    package func shownState(for subject: ItemRef) -> State? {
        hidden.contains(subject) ? nil : states[subject]
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
        hidden = []
    }

    // MARK: What's summed up

    /// The prompt for a thing and what's linked to it, as the details show them, the most pressing first; and what tells
    /// when that changes: what each one says. Nil when there's nothing to sum up: nothing linked to it, and nothing a
    /// source knows of it.
    func input(for subject: ItemRef) -> (prompt: String, inputs: [Input])? {
        let connections = links.connections(of: subject).sorted { lhs, rhs in
            ItemState.rank(lhs.item.state) < ItemState.rank(rhs.item.state)
        }
        guard !connections.isEmpty || (links.isDescribed(subject) && stories.story(for: subject) != nil) else { return nil }
        let described = links.describe(subject)
        let item = { (linked: LinkedItem, link: String?) in
            StorySummaryPrompt.Item(
                kind: Self.kind(of: linked), label: linked.label, title: linked.title, status: linked.statusToShare, link: link,
                story: self.stories.story(for: linked.ref)
            )
        }
        let prompt = StorySummaryPrompt.make(
            subject: item(described, nil),
            linked: connections.map { item($0.item, $0.reason) },
            reader: yourName,
            limit: usesOnDeviceModel ? 6_000 : 14_000,
            itemLimit: usesOnDeviceModel ? 1_800 : nil,
            includeInstructions: !usesOnDeviceModel
        )
        return (prompt, inputs(for: subject))
    }

    /// Routes only to the selected provider. A local failure must never send the prompt to Copilot instead.
    nonisolated package static func writer(
        copilot: @escaping Writer, onDevice: @escaping Writer = writeOnDevice
    ) -> Writer {
        { prompt, options in
            if options.model == appleIntelligenceModel {
                return await onDevice(prompt, options)
            }
            return await copilot(prompt, options)
        }
    }

    nonisolated package static func writeOnDevice(_ prompt: String, _ options: Options) async -> Result<String, Problem> {
        let answer = await OnDeviceModel.respond(
            to: prompt, instructions: StorySummaryPrompt.instructions, maximumTokens: 500, timeout: 45
        )
        return answer.mapError(onDeviceProblem)
    }

    nonisolated package static func onDeviceProblem(_ failure: OnDeviceModel.Failure) -> Problem {
        switch failure {
        case .unavailable(let reason):
            return Problem(reason, fix: .chooseModel)
        case .unsupportedLanguage:
            return Problem("Apple Intelligence doesn't support the language of this item.", fix: .chooseModel)
        case .refused:
            return Problem("Apple Intelligence declined to summarize this item.", fix: .chooseModel)
        case .tooLong:
            return Problem("This item is too long for Apple Intelligence. Choose a Copilot model to summarize it.", fix: .chooseModel)
        case .notReady:
            return Problem("Apple Intelligence is still getting ready. Try again later, or choose a Copilot model.", fix: .chooseModel)
        case .busy:
            return Problem("Apple Intelligence is busy or took too long. Try again.")
        case .empty:
            return Problem("Apple Intelligence answered nothing. Try again.")
        case .failed:
            return Problem("Apple Intelligence couldn't write a summary. Try again, or choose a Copilot model.", fix: .chooseModel)
        }
    }

    /// The thing and what's linked to it, each as it says now.
    private func inputs(for subject: ItemRef) -> [Input] {
        ([links.describe(subject)] + links.connections(of: subject).map(\.item)).map { item in
            Self.input(item, story: stories.story(for: item.ref))
        }
    }

    /// What a thing says, as the prompt has it, to tell when that changes: its row's state, title and status, as it may be
    /// shared; its story's sentence, as it may be shared, and the lines the prompt gives it, its facts, its runs and the
    /// first error of one that failed, and all Copilot recorded of its work; and its notes apart. No date goes in.
    static func input(_ item: LinkedItem, story: ItemStory?) -> Input {
        let row = [item.state?.rawValue ?? "", item.title, item.statusToShare ?? ""]
        var told: String?
        var notes: String?
        if let story {
            var withoutNotes = story
            withoutNotes.notes = []
            told = ([story.sentenceToShare] + withoutNotes.lines()).joined(separator: "\n")
            let noted = ItemStory(sentence: "", notes: story.notes).lines()
            notes = story.notesRead ? noted.joined(separator: "\n") : nil
        }
        return Input(ref: item.ref, label: item.label, row: row.joined(separator: "\n"), story: told, notes: notes)
    }

    /// What a sentence calls it: a work item's or a pull request's number, a session's name in quotes.
    static func name(_ input: Input) -> String {
        input.ref.kind == .session ? "“\(input.label)”" : input.label
    }

    /// What a summary was written from, as a sentence says it: the thing's and its pull requests' numbers, then how many
    /// Copilot sessions: "5101, !4120 and 1 Copilot session".
    package static func source(of inputs: [Input]) -> String {
        let sessions = inputs.filter { $0.ref.kind == .session }.count
        let counted = sessions == 0 ? [] : [sessions == 1 ? "1 Copilot session" : "\(sessions) Copilot sessions"]
        return list(inputs.filter { $0.ref.kind != .session }.map(\.label) + counted)
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
