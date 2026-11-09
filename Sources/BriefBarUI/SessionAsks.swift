import BriefBarCore
import Combine
import Foundation

/// Ask…: what you ask your Copilot sessions, such as where one stands or why it changed something, and what each answers,
/// by session, wherever it shows: on its page, under its heading, and under its row in a list. Each question is asked aside,
/// of a throwaway copy of the session with no tools, which the Copilot CLI deletes after, so it changes no file and the
/// session's history stays as it was; with the session's own model, as one premium request, as Explain asks one about a
/// pull request. It asks only through what the app gives it (`setAsker`): Azure DevOps, while Send Work to Copilot is on,
/// or its demo, which makes the answers up. While there's none, Ask… doesn't show. What's asked and answered, and what you
/// write in a field before you ask, stay in memory only, until you dismiss it, BriefBar quits, or asking turns off, which
/// stops what's being asked.
@MainActor
package final class SessionAsks: ObservableObject {
    /// What a session is asked.
    package struct Request: Equatable, Sendable {
        /// The session's ID.
        package var session: String
        /// What you asked, in your words; nil for where it stands (`SessionAskPrompt.whereItStands`).
        package var question: String?
        /// What it answered before, which this follows up on.
        package var earlier: SessionAnswer?
        /// The question in full (`SessionAskPrompt.prompt`).
        package var prompt: String

        package init(session: String, question: String?, earlier: SessionAnswer?, prompt: String) {
            self.session = session
            self.question = question
            self.earlier = earlier
            self.prompt = prompt
        }
    }

    /// Why there's no answer, for you, in a sentence; and what the Copilot CLI said, as it said it, when the sentence says it
    /// in other words.
    package struct Problem: Error, Equatable, Sendable {
        package var message: String
        package var detail: String?

        package init(_ message: String, detail: String? = nil) {
            self.message = message
            self.detail = detail
        }
    }

    /// Asks a session, aside: what it answers, or why there's none. Cancelled, it stops, and deletes its copy of the session.
    package typealias Asker = @Sendable (Request) async -> Result<String, Problem>

    /// A question, and how it stands.
    package struct Question: Equatable, Sendable {
        package enum State: Equatable, Sendable {
            case asking
            case answered(String)
            case failed(Problem)
        }

        /// What you asked, in your words; nil for where it stands.
        package var asked: String?
        package var askedAt: Date
        package var state: State
        /// When it was answered, or couldn't be.
        package var endedAt: Date?
        /// What it answered before, which this follows up on.
        package var earlier: SessionAnswer?

        package init(asked: String?, askedAt: Date, state: State, endedAt: Date? = nil, earlier: SessionAnswer? = nil) {
            self.asked = asked
            self.askedAt = askedAt
            self.state = state
            self.endedAt = endedAt
            self.earlier = earlier
        }

        package var isAsking: Bool { state == .asking }

        /// What you asked, as it shows: your words, or "Where do you stand?", or, following up, "Where do you stand now?".
        package var shownQuestion: String {
            asked ?? (earlier == nil ? SessionAskPrompt.whereItStands : SessionAskPrompt.whereItStandsNow)
        }

        /// What it answered, once it did, for a follow-up to build on.
        package var answer: SessionAnswer? {
            if case .answered(let text) = state { return SessionAnswer(question: asked, answer: text) }
            return nil
        }
    }

    /// The field that's open, one at a time, as Explain's composer is: the session it asks, and what you wrote in it, until you
    /// ask or close it.
    package struct Field: Equatable, Sendable {
        package var session: ItemRef
        package var words: String
    }

    /// What was asked of each session, and how it stands, by the session.
    @Published package private(set) var questions: [ItemRef: Question] = [:]
    /// The field that's open: one at a time, wherever its session shows.
    @Published package private(set) var field: Field?
    /// Whether it can ask now: the app gave it a way to (`setAsker`).
    @Published package private(set) var canAsk = false

    private var asker: Asker?
    /// What's being asked of each session, until it's answered or stopped.
    private var asking: [ItemRef: Task<Void, Never>] = [:]
    /// The answers and failures VoiceOver heard of, each once, however many views show them (`announcesOnce`).
    private var announced: Set<Announced> = []

    private struct Announced: Hashable {
        var session: ItemRef
        var endedAt: Date
    }

    package init() {}

    /// Gives it a way to ask, or, with nil, takes it away: then Ask… doesn't show, what's being asked stops, its copy of the
    /// session being deleted, and what was asked and answered, and what you wrote in a field, are forgotten.
    package func setAsker(_ asker: Asker?) {
        self.asker = asker
        if canAsk != (asker != nil) { canAsk = asker != nil }
        if asker == nil { forgetAll() }
    }

    /// What was asked of a session, and how it stands.
    package func question(for session: ItemRef) -> Question? {
        questions[session]
    }

    // MARK: The field

    /// Whether a session's field is open.
    package func isFieldOpen(for session: ItemRef) -> Bool {
        field?.session == session
    }

    /// What you wrote in a session's field.
    package func words(for session: ItemRef) -> String {
        isFieldOpen(for: session) ? field?.words ?? "" : ""
    }

    /// Opens a session's field, wherever the session shows, closing any other session's: with what you wrote in it, if it's
    /// open already.
    package func openField(for session: ItemRef) {
        guard offers(session), !isFieldOpen(for: session) else { return }
        field = Field(session: session, words: "")
    }

    /// Keeps what you write in a session's open field.
    package func setWords(_ words: String, for session: ItemRef) {
        guard isFieldOpen(for: session), field?.words != words else { return }
        field?.words = words
    }

    /// Closes a session's field, forgetting what you wrote in it.
    package func closeField(for session: ItemRef) {
        if isFieldOpen(for: session) { field = nil }
    }

    /// Whether Ask… is offered for something: a Copilot session, while it can ask.
    package func offers(_ ref: ItemRef?) -> Bool {
        canAsk && ref?.kind == .session
    }

    // MARK: Asking

    /// Asks a session your question, or else where it stands, following up on what it answered, while that shows: in place
    /// of what was asked of it before, which stops if it's still being asked. Its field closes.
    /// - Parameter question: what you want to know, in your words; nil or blank for where it stands.
    package func ask(_ session: ItemRef, question: String?) {
        guard let asker, offers(session) else { return }
        closeField(for: session)
        start(session, asked: question, earlier: questions[session]?.answer, asker: asker)
    }

    /// Asks again what a session couldn't answer, as it was asked: following up on what that followed up on.
    package func tryAgain(_ session: ItemRef) {
        guard let asker, let question = questions[session], case .failed = question.state else { return }
        start(session, asked: question.asked, earlier: question.earlier, asker: asker)
    }

    /// Stops what's being asked of a session, deleting its copy of the session, and forgets what was asked and answered.
    package func dismiss(_ session: ItemRef) {
        asking.removeValue(forKey: session)?.cancel()
        questions[session] = nil
    }

    /// Whether VoiceOver should hear that a question ended, as a view that shows it hears of it: once, though the session
    /// shows in more than one place, such as its page and its row.
    package func announcesOnce(_ session: ItemRef) -> Bool {
        guard let endedAt = questions[session]?.endedAt else { return false }
        return announced.insert(Announced(session: session, endedAt: endedAt)).inserted
    }

    private func start(_ session: ItemRef, asked: String?, earlier: SessionAnswer?, asker: @escaping Asker) {
        asking.removeValue(forKey: session)?.cancel()
        let words = asked?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = Question(asked: words?.isEmpty == false ? words : nil, askedAt: Date(), state: .asking, earlier: earlier)
        questions[session] = question
        let request = Request(
            session: session.id, question: question.asked, earlier: earlier,
            prompt: SessionAskPrompt.prompt(question: question.asked, earlier: earlier)
        )
        // That a session was asked, never what, nor what it answered.
        Log.app.info("Asked a Copilot session a question")
        asking[session] = Task { [weak self] in
            let result = await asker(request)
            // Stopped, or asked again, meanwhile: this answer isn't wanted.
            guard let self, !Task.isCancelled, self.questions[session] == question else { return }
            self.asking[session] = nil
            var ended = question
            ended.endedAt = Date()
            switch result {
            case .success(let text):
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                ended.state = answer.isEmpty ? .failed(Problem("Copilot answered nothing.")) : .answered(answer)
            case .failure(let problem):
                ended.state = .failed(problem)
                Log.app.error("A Copilot session couldn't answer a question")
            }
            self.questions[session] = ended
        }
    }

    private func forgetAll() {
        asking.values.forEach { $0.cancel() }
        asking = [:]
        if !questions.isEmpty { questions = [:] }
        if field != nil { field = nil }
        announced = []
    }

    // MARK: For --render

    /// For `--render`: what was asked of a session, and how it stands, as given, or nothing for nil; and its field open,
    /// with your words, or not, for nil. Nothing is asked.
    package func useForRendering(_ session: ItemRef, question: Question?, field words: String? = nil) {
        asking.removeValue(forKey: session)?.cancel()
        questions[session] = question
        if let words {
            field = Field(session: session, words: words)
        } else {
            closeField(for: session)
        }
    }
}
