import BriefBarCore
import Foundation
import FoundationModels
import Synchronization

/// Apple Intelligence's on-device model, for the summaries some sources write. Always
/// `SystemLanguageModel.default`, which runs on this Mac: never Private Cloud Compute or any other model,
/// so what's summarized doesn't leave the Mac.
package enum OnDeviceModel {
    /// The model, made once and kept, as Apple's examples keep theirs: its availability follows the Mac's.
    /// `SystemLanguageModel.default` makes a new one each time it's read, and what watching each one's availability took
    /// stayed once it went: views that read it as they update, such as the Pull Requests page, kept a little more each time.
    private static let model = SystemLanguageModel.default

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

    /// Why it can't run on this Mac now.
    package enum Unavailability: Sendable, Equatable {
        /// This Mac can't run it.
        case notEligible
        /// It's turned off in System Settings.
        case notEnabled
        /// It's still getting ready, as after it's turned on.
        case notReady
        case other
    }

    /// Why it can't run on this Mac now, or nil when it can.
    package static var unavailability: Unavailability? {
        switch model.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .notReady
        case .unavailable: .other
        }
    }

    /// Why summaries aren't available, or nil when they are.
    package static var unavailableReason: String? {
        switch unavailability {
        case nil: nil
        case .notEligible?: "This Mac can't run Apple Intelligence."
        case .notEnabled?: "Turn on Apple Intelligence in System Settings to get summaries."
        case .notReady?: "Apple Intelligence is still getting ready."
        case .other?: "Apple Intelligence isn't available."
        }
    }

    package static var isAvailable: Bool { unavailableReason == nil }

    /// Whether it always picks the likeliest words, rather than varying them a little: then, as Apple documents, the
    /// same question always gets the same answer.
    private static let picksLikeliestWords = Mutex(false)

    /// From now on, answers the same question the same way: for `--render`, whose parts different processes draw.
    package static func useLikeliestWords() {
        picksLikeliestWords.withLock { $0 = true }
    }

    /// Asks the on-device model, giving up after `timeout`.
    /// - Parameters:
    ///   - likeliestWords: always the likeliest words, so the same question gets the same answer, as mission names need;
    ///     otherwise only after `useLikeliestWords`.
    ///   - shape: what the answer must be, by guided generation: then it's that one string alone, never wrapped in talk,
    ///     Markdown or other lines.
    package static func respond(
        to prompt: String, instructions: String, maximumTokens: Int, temperature: Double = 0.2, timeout: TimeInterval = 20,
        likeliestWords: Bool = false, shape: Shape? = nil
    ) async -> Result<String, Failure> {
        await withTaskGroup(of: Result<String, Failure>?.self) { group in
            group.addTask {
                await answer(
                    prompt, instructions: instructions, maximumTokens: maximumTokens, temperature: temperature,
                    likeliestWords: likeliestWords, shape: shape
                )
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.busy)
        }
    }

    /// An answer in a set shape, as guided generation makes it: the string property of a schema of its own, or, for a
    /// suggested split, the groups of parts (`MissionSplitting.Answer`), as JSON. Built from a schema made as the app runs
    /// (`DynamicGenerationSchema`), since `@Generable`'s macro comes only with Xcode.
    package struct Shape: Sendable {
        fileprivate let schema: GenerationSchema
        /// The string property that's the answer; nil for the whole answer, as JSON.
        fileprivate let property: String?

        /// One string, `property`, that `description` says what it is, of a schema called `name`.
        package init(_ name: String, property: String, description: String) throws {
            schema = try GenerationSchema(
                root: DynamicGenerationSchema(name: name, properties: [
                    DynamicGenerationSchema.Property(
                        name: property, description: description, schema: DynamicGenerationSchema(type: String.self)
                    ),
                ]),
                dependencies: []
            )
            self.property = property
        }

        /// Whether a mission's parts are all one piece of work, and its groups, two or three, each with the numbers of its
        /// parts, from 1 to `parts`: an answer that can hold nothing else.
        package static func split(parts count: Int) throws -> Shape {
            typealias Answer = MissionSplitting.Answer
            let number = DynamicGenerationSchema(type: Int.self, guides: [.range(1...max(count, 1))])
            let group = DynamicGenerationSchema(name: Answer.group, properties: [
                DynamicGenerationSchema.Property(
                    name: Answer.parts, description: Answer.partsDescription,
                    schema: DynamicGenerationSchema(arrayOf: number, minimumElements: 1, maximumElements: max(count, 1))
                ),
            ])
            let root = DynamicGenerationSchema(name: Answer.name, properties: [
                DynamicGenerationSchema.Property(
                    name: Answer.oneWork, description: Answer.oneWorkDescription, schema: DynamicGenerationSchema(type: Bool.self)
                ),
                DynamicGenerationSchema.Property(
                    name: Answer.groups, description: Answer.groupsDescription,
                    schema: DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(referenceTo: Answer.group), minimumElements: 1,
                        maximumElements: MissionSplitting.mostGroups
                    )
                ),
            ])
            return Shape(schema: try GenerationSchema(root: root, dependencies: [group]), property: nil)
        }

        private init(schema: GenerationSchema, property: String?) {
            self.schema = schema
            self.property = property
        }

        /// The string an answer of this shape holds, from the content the model generated, as JSON; the JSON itself for the
        /// whole answer.
        package func text(ofJSON json: String) throws -> String {
            guard let property else { return try GeneratedContent(json: json).jsonString }
            return try GeneratedContent(json: json).value(String.self, forProperty: property)
        }
    }

    private static func answer(
        _ prompt: String, instructions: String, maximumTokens: Int, temperature: Double, likeliestWords: Bool, shape: Shape?
    ) async -> Result<String, Failure> {
        if let reason = unavailableReason { return .failure(.unavailable(reason)) }
        // Explicitly the on-device model.
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = likeliestWords || picksLikeliestWords.withLock { $0 }
            ? GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumTokens)
            : GenerationOptions(temperature: temperature, maximumResponseTokens: maximumTokens)
        do {
            let text: String
            if let shape {
                let response = try await session.respond(to: prompt, schema: shape.schema, options: options)
                if let property = shape.property {
                    text = try response.content.value(String.self, forProperty: property)
                } else {
                    text = response.content.jsonString
                }
            } else {
                text = try await session.respond(to: prompt, options: options).content
            }
            return text.isEmpty ? .failure(.empty) : .success(text)
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
