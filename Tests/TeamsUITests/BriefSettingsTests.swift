import BriefBarUI
import Combine
import Foundation
import Testing
@testable import TeamsUI

/// What the brief says of a chat follows Show Message Previews and Summarize with Apple Intelligence at once: a list by
/// state looks again when you change either, even with nothing new in Teams.
@MainActor
@Suite struct BriefSettingsTests {
    /// What the settings were each time lists were told to look again.
    @MainActor
    private final class Seen {
        var settings: [(previews: Bool, summaries: Bool)] = []
    }

    /// Lets what the settings start go on until `done`, for as long as a busy machine could need: four minutes, as the
    /// other targets' `waitLimit`, since `make test` runs every test's async work on one thread, and a test may get its
    /// turn only after most of the others. A wait that's answered still returns as soon as it is.
    private func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func listsLookAgainWhenPreviewsOrSummariesChange() async {
        let source = TeamsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true))
        let seen = Seen()
        let subscription = source.stateRowsChanged.sink {
            MainActor.assumeIsolated { seen.settings.append((source.settings.showPreviews, source.settings.showSummaries)) }
        }
        defer { subscription.cancel() }

        // Each time once the new value is in place, so the list reads it.
        source.settings.showPreviews = false
        await settle { seen.settings.count == 1 }
        source.settings.showSummaries = false
        await settle { seen.settings.count == 2 }
        source.settings.showPreviews = true
        await settle { seen.settings.count == 3 }
        #expect(seen.settings.map(\.previews) == [false, false, true])
        #expect(seen.settings.map(\.summaries) == [true, false, false])
    }
}
