import BriefBarUI
import Foundation
import TeamsCore

/// One-sentence summaries of chats, from Apple's on-device model (`OnDeviceModel`), which runs on this
/// Mac, so messages and summaries don't leave it. Summaries live in memory only.
@MainActor
final class Summarizer: ObservableObject {
    enum State: Equatable {
        case loading
        case done(String)
        case failed(String)
    }

    private struct Result {
        var key: String
        var state: State
    }

    @Published private var results: [String: Result] = [:]

    /// Why summaries aren't available, or nil when they are.
    nonisolated static var unavailableReason: String? { OnDeviceModel.unavailableReason }

    /// The chat's summary, if it covers its current messages.
    func state(for conversation: ConversationSummary) -> State? {
        guard let result = results[conversation.id], result.key == SummaryPrompt.key(for: conversation) else { return nil }
        return result.state
    }

    func summarize(_ conversation: ConversationSummary) {
        let key = SummaryPrompt.key(for: conversation)
        if let result = results[conversation.id], result.key == key, result.state == .loading { return }
        results[conversation.id] = Result(key: key, state: .loading)
        let prompt = SummaryPrompt.prompt(for: conversation)
        Task {
            let state = await Self.summarize(prompt: prompt)
            // A newer request for this chat wins.
            if results[conversation.id]?.key == key {
                results[conversation.id] = Result(key: key, state: state)
            }
        }
    }

    nonisolated static func summarize(prompt: String) async -> State {
        switch await OnDeviceModel.respond(to: prompt, instructions: SummaryPrompt.instructions, maximumTokens: 120) {
        case .success(let response):
            let text = SummaryPrompt.clean(response)
            return text.isEmpty ? .failed("Apple Intelligence gave no summary.") : .done(text)
        case .failure(let failure):
            return .failed(message(for: failure))
        }
    }

    nonisolated static func message(for failure: OnDeviceModel.Failure) -> String {
        switch failure {
        case .unavailable(let reason): return reason
        case .unsupportedLanguage: return "Apple Intelligence can't summarize this language yet."
        case .refused: return "Apple Intelligence wouldn't summarize this chat."
        case .tooLong: return "This chat is too long to summarize."
        case .notReady: return "Apple Intelligence is still getting ready."
        case .busy: return "Apple Intelligence is busy. Try again in a moment."
        case .empty: return "Apple Intelligence gave no summary."
        case .failed: return "Couldn't summarize this chat."
        }
    }
}
