import BriefBarCore
import Foundation

/// Names missions with Apple Intelligence's on-device model, on this Mac, as By Mission shows them (§7.4.7): only while
/// Apple Intelligence is on, only the missions on screen, one at a time, each once it's settled, what it's named from
/// unchanged for `settleFor`, and again only when that changes; always with the likeliest words, so the same question gets
/// the same name, today and after a restart. A refusal or a failure keeps the name it had. Nothing leaves this Mac, and
/// what it names stays in memory, while BriefBar runs, never in the log. Pull Request Order tells it what's on screen,
/// without the missions you named.
@MainActor
package final class MissionNamer {
    package typealias Respond = @MainActor (_ prompt: String, _ instructions: String) async -> Result<String, OnDeviceModel.Failure>

    /// A mission on screen, what it's named from, and whether that's all read.
    package struct Request: Equatable {
        package var key: MissionKey
        package var inputs: MissionNameInputs
        package var isSettled: Bool

        package init(key: MissionKey, inputs: MissionNameInputs, isSettled: Bool) {
            self.key = key
            self.inputs = inputs
            self.isSettled = isSettled
        }
    }

    /// How long what a mission is named from stays the same before it's asked, so names don't flicker as what BriefBar
    /// reads lands.
    package static let settleFor: TimeInterval = 5
    /// How long it waits after Apple Intelligence was busy or still getting ready.
    package static let retryAfter: TimeInterval = 30

    /// Tells the name Apple Intelligence gave a mission.
    package var named: @MainActor (MissionKey, String) -> Void = { _, _ in }

    private var requests: [Request] = []
    /// What each mission was asked with last: it isn't asked again until that changes.
    private var asked: [MissionKey: MissionNameInputs] = [:]
    /// Since when each mission on screen has been named from what it is now.
    private var since: [MissionKey: (inputs: MissionNameInputs, at: Date)] = [:]
    private var asking: MissionKey?
    /// The answer under way no longer counts: Pull Request Order went off, or its mission's name was forgotten, meanwhile.
    private var dropsAnswer = false
    private var waitUntil: Date?
    private var timer: Timer?
    /// When it comes back to see what's due, if it will.
    package private(set) var wakesAt: Date?
    private let unavailability: @MainActor () -> OnDeviceModel.Unavailability?
    private let respond: Respond
    private let now: () -> Date

    /// - Parameter unavailability: why Apple Intelligence can't answer now, or nil when it can.
    package init(
        unavailability: @escaping @MainActor () -> OnDeviceModel.Unavailability? = { OnDeviceModel.unavailability },
        respond: @escaping Respond = { prompt, instructions in
            await OnDeviceModel.respond(to: prompt, instructions: instructions, maximumTokens: 24, likeliestWords: true)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.unavailability = unavailability
        self.respond = respond
        self.now = now
    }

    /// The missions on screen now, the first first, with what each is named from: it asks for the first that's settled and
    /// hasn't been asked with what it's named from now, once that stayed the same for `settleFor`.
    package func update(_ requests: [Request]) {
        let date = now()
        var since: [MissionKey: (inputs: MissionNameInputs, at: Date)] = [:]
        for request in requests {
            if let was = self.since[request.key], was.inputs == request.inputs {
                since[request.key] = was
            } else {
                since[request.key] = (request.inputs, date)
            }
        }
        self.since = since
        self.requests = requests
        next()
    }

    /// Pull Request Order went off: it asks for nothing more, and forgets what it asked, and the answer under way. Once
    /// nothing's on screen, `update` with none, which keeps what it asked, so the same missions aren't asked again when they
    /// show again.
    package func stop() {
        requests = []
        since = [:]
        asked = [:]
        if asking != nil { dropsAnswer = true }
        cancelWake()
    }

    /// Forgets what it asked for these missions, whose names went, as when their source was turned off, and the answer under
    /// way for one: shown again, they're asked again.
    package func forget(where matches: (MissionKey) -> Bool) {
        asked = asked.filter { !matches($0.key) }
        since = since.filter { !matches($0.key) }
        if let asking, matches(asking) { dropsAnswer = true }
    }

    /// Asks for the next mission that's due, or comes back when one will be: while Apple Intelligence is off or getting
    /// ready, every `retryAfter`, as long as one waits for a name; never on a Mac that can't run it. With nothing on
    /// screen, it doesn't come back.
    package func next() {
        guard !requests.isEmpty else {
            cancelWake()
            return
        }
        guard asking == nil else { return }
        let date = now()
        if let unavailable = unavailability() {
            if unavailable != .notEligible, requests.contains(where: { $0.isSettled && asked[$0.key] != $0.inputs }) {
                wake(at: date.addingTimeInterval(Self.retryAfter))
            } else {
                cancelWake()
            }
            return
        }
        if let waitUntil, date < waitUntil {
            wake(at: waitUntil)
            return
        }
        var soonest: Date?
        for request in requests where request.isSettled && asked[request.key] != request.inputs {
            guard let since = since[request.key] else { continue }
            let due = since.at.addingTimeInterval(Self.settleFor)
            if due <= date {
                ask(request)
                return
            }
            soonest = min(soonest ?? due, due)
        }
        if let soonest { wake(at: soonest) }
    }

    private func ask(_ request: Request) {
        asking = request.key
        let prompt = MissionNaming.prompt(request.inputs)
        Task { [weak self, respond] in
            let answer = await respond(prompt, MissionNaming.instructions)
            guard let self else { return }
            asking = nil
            // Stopped or forgotten meanwhile, or named from something else now: the answer doesn't count, and the mission is
            // asked again once it settles.
            let isStale = dropsAnswer || requests.contains { $0.key == request.key && $0.inputs != request.inputs }
            dropsAnswer = false
            guard !isStale else {
                next()
                return
            }
            switch answer {
            case .success(let text):
                asked[request.key] = request.inputs
                if let name = MissionNaming.clean(text) {
                    named(request.key, name)
                } else {
                    Log.app.info("A mission keeps its name: Apple Intelligence's answer wasn't one")
                }
            case .failure(.busy), .failure(.notReady), .failure(.unavailable):
                waitUntil = now().addingTimeInterval(Self.retryAfter)
                Log.app.info("A mission's name waits: Apple Intelligence is busy, getting ready or off")
            case .failure(let failure):
                asked[request.key] = request.inputs
                Log.app.info("A mission keeps its name: \(String(describing: failure), privacy: .public)")
            }
            next()
        }
    }

    private func wake(at date: Date) {
        timer?.invalidate()
        wakesAt = date
        let interval = max(date.timeIntervalSince(now()), 0) + 0.05
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wakesAt = nil
                self?.next()
            }
        }
        // A second or a few later is as good, and lets the Mac sleep in between.
        timer.tolerance = min(interval / 5, 5)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelWake() {
        timer?.invalidate()
        timer = nil
        wakesAt = nil
    }
}
