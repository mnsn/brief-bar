import AzureDevOpsCore
import Testing
@testable import AzureDevOpsUI

/// Where a pull request's details go, for VoiceOver to follow them there each time (`DetailsArrival`): to a build, a check,
/// a thread or a file's row they point out, a part's header, or their title. With made-up places only.
@MainActor
@Suite struct DetailsArrivalTests {
    typealias Anchor = PullRequestDetailsStore.Anchor

    /// A build asked for again while it's still pointed out, as a failing pull request opened again from the menu bar within
    /// that moment, takes VoiceOver there again: each arrival is another, though the build is the same and still highlighted.
    /// Only where they went: not anything else.
    @Test func eachArrivalTakesVoiceOverThereThoughItWentThereLast() {
        let build = Anchor.check("run 204417")
        var arrival = DetailsArrival()
        var before = arrival
        arrival.arrive(at: build)
        #expect(arrival.arrived(at: build, since: before))
        #expect(!arrival.arrived(at: .check("check Code coverage"), since: before))
        #expect(!arrival.arrived(at: .section(.checks), since: before))

        before = arrival
        arrival.arrive(at: build)
        #expect(arrival.arrived(at: build, since: before))
        // Nothing new since: no arrival.
        #expect(!arrival.arrived(at: build, since: arrival))
    }

    /// The same for a thread, a file's row, a part's header and their top, each time.
    @Test func everyPlaceTakesItEachTime() {
        let places: [Anchor] = [
            .thread(11), .file(FileChange.ID(path: "/src/PaymentsClient.cs")), .section(.comments), .files, .top,
        ]
        var arrival = DetailsArrival()
        for place in places {
            for _ in 0..<2 {
                let before = arrival
                arrival.arrive(at: place)
                #expect(arrival.arrived(at: place, since: before), "\(place)")
                #expect(places.filter { $0 != place }.allSatisfy { !arrival.arrived(at: $0, since: before) }, "\(place)")
            }
        }
        #expect(arrival.count == places.count * 2 && arrival.anchor == .top)
    }

    /// Setting out somewhere isn't getting there: what was gone to last doesn't take VoiceOver again, nor does what they're
    /// going to, until they're there.
    @Test func settingOutIsNoArrival() {
        var arrival = DetailsArrival()
        arrival.arrive(at: .thread(11))
        var before = arrival
        arrival.isGoing = true
        #expect(!arrival.arrived(at: .thread(11), since: before))
        before = arrival
        arrival.isGoing = false
        arrival.arrive(at: .thread(13))
        #expect(arrival.arrived(at: .thread(13), since: before) && !arrival.arrived(at: .thread(11), since: before))
    }
}
