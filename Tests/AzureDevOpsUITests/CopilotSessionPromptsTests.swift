import BriefBarUI
import CopilotTasks
import Foundation
import Testing

/// Send Prompts to Copilot Sessions, as BriefBar keeps it: off until it's turned on, and nothing left of it once it's
/// turned off.
@Suite struct CopilotSessionPromptsTests {
    @Test func isOffUntilTurnedOn() {
        let defaults = MemoryDefaults()
        #expect(!CopilotSessionPrompts.isOn(in: defaults))

        CopilotSessionPrompts.set(true, in: defaults)
        #expect(CopilotSessionPrompts.isOn(in: defaults))
        #expect(defaults.object(forKey: CopilotSessionPrompts.defaultsKey) as? Bool == true)

        CopilotSessionPrompts.set(false, in: defaults)
        #expect(!CopilotSessionPrompts.isOn(in: defaults))
        #expect(defaults.object(forKey: CopilotSessionPrompts.defaultsKey) == nil)
        #expect(defaults.dictionaryRepresentation().isEmpty)
    }

    @Test func isNamedAsBriefBarNamesOptions() {
        #expect(CopilotSessionPrompts.title == "Send Prompts to Copilot Sessions")
    }
}
