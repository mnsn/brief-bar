import BriefBarCore
import Foundation
import Testing
@testable import BriefBarUI

/// Full Disk Access is the whole app's, so these check that nothing checks or asks for it except for a
/// source that's on.
@MainActor
@Suite struct FullDiskAccessTests {
    private func makeAccess() -> (FullDiskAccess, MemorySettings) {
        let defaults = MemorySettings()
        return (FullDiskAccess(defaults: defaults), defaults)
    }

    @Test func checksNothingWhileNoSourceNeedsIt() {
        let (access, _) = makeAccess()
        #expect(!access.isNeeded)
        #expect(access.check() == nil)
        access.report(granted: true)
        #expect(access.isGranted == nil)
    }

    @Test func checksOnlyWithTheSourcesThatAreOn() {
        let (access, _) = makeAccess()
        var probes = 0
        access.register(.teams, name: "Teams", reason: "Reasons.") {
            probes += 1
            return false
        }
        #expect(access.isNeeded)
        #expect(access.check() == false)
        #expect(probes == 1)
        #expect(access.requesterNames == ["Teams"])

        access.unregister(.teams)
        #expect(!access.isNeeded)
        #expect(access.check() == nil)
        #expect(probes == 1)
        #expect(access.isGranted == nil)
    }

    @Test func remembersHavingHadTheAccess() {
        let (access, defaults) = makeAccess()
        access.register(.teams, name: "Teams", reason: "Reasons.") { true }
        #expect(access.check() == true)
        #expect(!access.lostAccess)
        access.report(granted: false)
        #expect(access.lostAccess)

        // Another run of the app knows too.
        let again = FullDiskAccess(defaults: defaults)
        again.register(.teams, name: "Teams", reason: "Reasons.") { false }
        again.check()
        #expect(again.lostAccess)
    }
}
