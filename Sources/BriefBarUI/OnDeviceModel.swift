import Foundation
import FoundationModels

/// Apple Intelligence's on-device model, for the summaries some sources write. Always
/// `SystemLanguageModel.default`, which runs on this Mac: never Private Cloud Compute or any other model,
/// so what's summarized doesn't leave the Mac.
package enum OnDeviceModel {
    package enum Failure: Error, Equatable, Sendable {
        /// Not on this Mac, or not now: why, in a sentence.
        case unavailable(String)
        case unsupportedLanguage
        /// Its guardrails, or the model itself, declined.
        case refused
        case tooLong
        case notReady
        case busy
        /// It answered with nothing.
        case empty
        case failed
    }

    /// Why summaries aren't available, or nil when they are.
    package static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to get summaries."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready."
        case .unavailable:
            return "Apple Intelligence isn't available."
        }
    }

    package static var isAvailable: Bool { unavailableReason == nil }

    /// Asks the on-device model, giving up after `timeout`.
    package static func respond(
        to prompt: String, instructions: String, maximumTokens: Int, temperature: Double = 0.2, timeout: TimeInterval = 20
    ) async -> Result<String, Failure> {
        await withTaskGroup(of: Result<String, Failure>?.self) { group in
            group.addTask { await answer(prompt, instructions: instructions, maximumTokens: maximumTokens, temperature: temperature) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.busy)
        }
    }

    private static func answer(
        _ prompt: String, instructions: String, maximumTokens: Int, temperature: Double
    ) async -> Result<String, Failure> {
        if let reason = unavailableReason { return .failure(.unavailable(reason)) }
        // Explicitly the on-device model.
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(temperature: temperature, maximumResponseTokens: maximumTokens)
            )
            return response.content.isEmpty ? .failure(.empty) : .success(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale: return .failure(.unsupportedLanguage)
            case .guardrailViolation, .refusal: return .failure(.refused)
            case .exceededContextWindowSize: return .failure(.tooLong)
            case .assetsUnavailable: return .failure(.notReady)
            case .rateLimited, .concurrentRequests: return .failure(.busy)
            default: return .failure(.failed)
            }
        } catch {
            return .failure(.failed)
        }
    }
}
