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

    // MARK: What they point out

    /// A thread, a file's row, a build or a check is pointed out for a moment as they go there; a part, their Files or their
    /// top isn't. Its moment's end isn't another arrival.
    @Test func whatTheyGoToIsPointedOutForAMoment() {
        var arrival = DetailsArrival()
        let build = Anchor.check("run 204417")
        arrival.arrive(at: build)
        #expect(arrival.pointedOut == build)
        let before = arrival
        arrival.endMoment(of: before.count)
        #expect(arrival.pointedOut == nil)
        #expect(!arrival.arrived(at: build, since: before))
        for place in [Anchor.thread(11), .file(FileChange.ID(path: "/src/PaymentsClient.cs"))] {
            arrival.arrive(at: place)
            #expect(arrival.pointedOut == place)
        }
        for place in [Anchor.section(.reviewers), .files, .top] {
            arrival.arrive(at: place)
            #expect(arrival.pointedOut == nil, "\(place)")
        }
    }

    /// Asked for the same build again within its moment, it's pointed out for a moment of its own: the first moment's end
    /// doesn't end it, its own does.
    @Test func goingThereAgainHasAMomentOfItsOwn() {
        var arrival = DetailsArrival()
        let build = Anchor.check("run 204417")
        arrival.arrive(at: build)
        let first = arrival.count
        arrival.arrive(at: build)
        let second = arrival.count
        arrival.endMoment(of: first)
        #expect(arrival.pointedOut == build)
        arrival.endMoment(of: second)
        #expect(arrival.pointedOut == nil)
    }

    /// Going within a build's moment to a part, their Files or their top ends it at once, and to another build points that
    /// one out instead, for its own moment: nothing stays pointed out once the last moment is over.
    @Test func goingElsewhereEndsWhatWasPointedOut() {
        for elsewhere in [Anchor.section(.checks), .files, .top] {
            var arrival = DetailsArrival()
            arrival.arrive(at: .check("run 204417"))
            let first = arrival.count
            arrival.arrive(at: elsewhere)
            #expect(arrival.pointedOut == nil, "\(elsewhere)")
            arrival.endMoment(of: first)
            #expect(arrival.pointedOut == nil, "\(elsewhere)")
        }
        var arrival = DetailsArrival()
        arrival.arrive(at: .check("run 204417"))
        let first = arrival.count
        arrival.arrive(at: .check("check Code coverage"))
        let second = arrival.count
        arrival.endMoment(of: first)
        #expect(arrival.pointedOut == .check("check Code coverage"))
        arrival.endMoment(of: second)
        #expect(arrival.pointedOut == nil)
    }
}
