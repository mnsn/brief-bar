import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

/// Fix Grammar's models, for a reply you write in a pull request's thread (`GrammarFix`): Apple Intelligence, on this Mac,
/// unless you chose one through Copilot (`AppSettings.grammarModel`), with the choices summaries offer. A model through
/// Copilot gets the reply's text from the Copilot CLI, with no tools at all, one premium request each time; Apple
/// Intelligence never sends it anywhere, and when it can't run, it says so, for you to choose another: what it can't do
/// never goes to Copilot instead. The demo makes its corrections up, and runs no model.
@MainActor
final class GrammarFixer {
    /// Why there's no correction, in a sentence; what the model said, as it said it, when the sentence says it in other
    /// words; and whether choosing another model may help.
    struct Problem: Error, Equatable {
        var message: String
        var detail: String?
        var choosesModel = false
    }

    private let isDemo: Bool
    /// Asked for once, as Fix Grammar first goes to Copilot.
    private lazy var copilot = CopilotSummarizer()
    /// Why Apple Intelligence can't run on this Mac now, or nil; the demo and tests say.
    var onDeviceUnavailable: () -> OnDeviceModel.Unavailability? = { OnDeviceModel.unavailability }
    /// Asks Apple Intelligence; tests stand in for it.
    var askOnDevice: (_ text: String, _ maximumTokens: Int) async -> Result<String, OnDeviceModel.Failure> = { text, maximumTokens in
        await OnDeviceModel.respond(to: text, instructions: GrammarFix.instructions, maximumTokens: maximumTokens, temperature: 0, timeout: 45)
    }
    /// Asks a model through the Copilot CLI; tests stand in for it.
    var askCopilot: ((_ prompt: String, _ model: String) async -> Result<String, CopilotSummarizer.Failure>)?

    init(isDemo: Bool) {
        self.isDemo = isDemo
        if isDemo { onDeviceUnavailable = { nil } }
    }

    /// The text corrected by `model`, or why it can't be: with what it held back from the model put back as it was.
    func fix(_ text: String, with model: String) async -> Result<String, Problem> {
        if isDemo {
            try? await Task.sleep(for: .milliseconds(500))
            return .success(GrammarFix.madeUp(text))
        }
        let request = GrammarFix.request(for: text)
        let answer: Result<String, Problem>
        if model == StorySummaries.appleIntelligenceModel {
            if let unavailability = onDeviceUnavailable() { return .failure(Self.unavailable(unavailability)) }
            // About as long as the text, and room to spare.
            let tokens = min(4_000, max(256, request.text.utf8.count / 2))
            answer = await askOnDevice(request.text, tokens).mapError(Self.onDevice)
        } else {
            let name = CopilotModel.name(of: model)
            let asked = await (askCopilot ?? askThroughCLI)(request.prompt, model)
            answer = asked.mapError { Problem(message: $0.message(model: name), detail: $0.detail, choosesModel: Self.choosesModel($0)) }
        }
        guard !Task.isCancelled else { return .failure(Problem(message: "Fix Grammar was stopped.")) }
        return answer.flatMap { said in
            GrammarFix.corrected(said, for: request).mapError { failure in
                switch failure {
                case .empty: Problem(message: "The model answered nothing.", choosesModel: true)
                case .changedHeld:
                    Problem(
                        message: "The model changed your code, a link or a mention, so your reply stays as it is. Try again, or choose another model.",
                        choosesModel: true
                    )
                }
            }
        }
    }

    private func askThroughCLI(_ prompt: String, _ model: String) async -> Result<String, CopilotSummarizer.Failure> {
        await copilot.summarize(prompt, options: CopilotRunOptions(model: model, effort: "low"), name: CopilotSummarizer.grammarSessionName)
    }

    private static func choosesModel(_ failure: CopilotSummarizer.Failure) -> Bool {
        if case .modelUnavailable = failure { return true }
        return false
    }

    /// Why Apple Intelligence can't correct a reply on this Mac now, and that a Copilot model can.
    static func unavailable(_ unavailability: OnDeviceModel.Unavailability) -> Problem {
        let why = switch unavailability {
        case .notEligible: "This Mac can't run Apple Intelligence."
        case .notEnabled: "Apple Intelligence is turned off: turn it on in System Settings, or choose a Copilot model instead."
        case .notReady: "Apple Intelligence is still getting ready: try again later, or choose a Copilot model instead."
        case .other: "Apple Intelligence isn't available."
        }
        let then = unavailability == .notEnabled || unavailability == .notReady ? "" : " Choose a Copilot model instead."
        return Problem(message: why + then, choosesModel: true)
    }

    /// Why Apple Intelligence didn't correct it, in a sentence, with what may help.
    static func onDevice(_ failure: OnDeviceModel.Failure) -> Problem {
        switch failure {
        case .unavailable(let reason):
            return Problem(message: "\(reason) Choose a Copilot model instead.", choosesModel: true)
        case .unsupportedLanguage:
            return Problem(message: "Apple Intelligence doesn't support the language of this reply. Choose a Copilot model instead.", choosesModel: true)
        case .refused:
            return Problem(message: "Apple Intelligence declined to correct this reply. Choose a Copilot model instead.", choosesModel: true)
        case .tooLong:
            return Problem(message: "This reply is too long for Apple Intelligence. Choose a Copilot model instead.", choosesModel: true)
        case .notReady:
            return Problem(message: "Apple Intelligence is still getting ready. Try again later, or choose a Copilot model.", choosesModel: true)
        case .busy:
            return Problem(message: "Apple Intelligence is busy or took too long. Try again.")
        case .empty:
            return Problem(message: "Apple Intelligence answered nothing.", choosesModel: true)
        case .failed:
            return Problem(message: "Apple Intelligence couldn't correct this reply. Try again, or choose a Copilot model.", choosesModel: true)
        }
    }
}
