import BriefBarCore
import Foundation

/// Names missions with Apple Intelligence's on-device model, on this Mac, as By Mission shows them (§7.4.7): only while
/// Apple Intelligence is on, only the missions on screen, one at a time, each once it's settled, what it's named from
/// unchanged for `settleFor`, and again only when that changes; always with the likeliest words, so the same question gets
/// the same name, today and after a restart. A refusal or a failure keeps the name it had. Nothing leaves this Mac, and
/// what it names stays in memory, while BriefBar runs, never in the log. Pull Request Order tells it what's on screen,
/// without the missions you named.
///
/// Then, once no name is due, it asks whether a mission on screen has become different pieces of work (§7.4.8), the same
/// way: one at a time, once settled, what it's made of unchanged for `settleFor`, and again only when that changes, not when
/// a title alone does. Twice, its parts in order with what it's for, then reversed without, and only what both answers
/// separate counts (`MissionSplitting.join`); then it names the groups that need a name, as it names missions. Between one
/// answer and the next, it stops once the mission has left the screen, keeping what it found for when it's back, or once
/// what it finds can't count. Pull Request Order tells it which missions to look at, without those you kept together.
@MainActor
package final class MissionNamer {
    package typealias Respond = @MainActor (_ prompt: String, _ instructions: String) async -> Result<String, OnDeviceModel.Failure>
    /// Asks whether a mission's parts are different pieces of work: the answer as JSON (`MissionSplitting.Answer`).
    package typealias RespondSplit = @MainActor (_ prompt: String, _ instructions: String, _ parts: Int) async
        -> Result<String, OnDeviceModel.Failure>

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

    /// A mission on screen it may suggest splitting, with its question, which is asked only once what the mission is made
    /// of can be told (`MissionSplitQuestion.isWorthAsking`).
    package struct SplitRequest: Equatable {
        package var question: MissionSplitQuestion

        package var key: MissionKey { question.key }

        package init(question: MissionSplitQuestion) {
            self.question = question
        }
    }

    /// How long what a mission is named from stays the same before it's asked, so names don't flicker as what BriefBar
    /// reads lands.
    package static let settleFor: TimeInterval = 5
    /// How long it waits after Apple Intelligence was busy or still getting ready.
    package static let retryAfter: TimeInterval = 30

    /// Tells the name Apple Intelligence gave a mission.
    package var named: @MainActor (MissionKey, String) -> Void = { _, _ in }
    /// Tells the split Apple Intelligence suggests for a mission, or that it suggests none, for the question it was asked.
    package var suggested: @MainActor (MissionKey, MissionSplitQuestion.Basis, MissionSplit?) -> Void = { _, _, _ in }

    private var requests: [Request] = []
    /// What each mission was asked with last, without its current name: it isn't asked again until that changes.
    private var asked: [MissionKey: MissionNameInputs] = [:]
    /// Since when each mission on screen has been named from what it is now, without its current name.
    private var since: [MissionKey: (inputs: MissionNameInputs, at: Date)] = [:]
    private var splitRequests: [SplitRequest] = []
    /// Since when each mission it may split has been made of what it is now.
    private var splitSince: [MissionKey: (makeup: MissionSplitQuestion.Makeup?, at: Date)] = [:]
    /// What both questions grouped each mission's parts into, by what it was made of then; nil where they didn't agree on a
    /// split: asked again only once that changes.
    private var groupings: [MissionKey: (makeup: MissionSplitQuestion.Makeup?, grouping: [Set<ItemRef>]?)] = [:]
    /// The names it gave each mission's groups, by what each was named from; nil where it gave none.
    private var groupNames: [MissionKey: [MissionNameInputs: String?]] = [:]
    /// What each mission's suggestion was told for last: not worked out again until that changes.
    private var splitsTold: [MissionKey: MissionSplitQuestion.Basis] = [:]
    /// Missions a split you confirmed named: what they're named from when they show is what they were asked with.
    private var adopted: Set<MissionKey> = []
    private var asking: MissionKey?
    /// The answer under way no longer counts: Pull Request Order went off, or its mission's name was forgotten, meanwhile.
    private var dropsAnswer = false
    private var waitUntil: Date?
    private var timer: Timer?
    /// When it comes back to see what's due, if it will.
    package private(set) var wakesAt: Date?
    private let unavailability: @MainActor () -> OnDeviceModel.Unavailability?
    private let respond: Respond
    private let respondSplit: RespondSplit
    private let now: () -> Date

    /// What an answer is: the mission's name alone, by guided generation, so it never comes wrapped in talk, Markdown or
    /// other lines. `MissionNaming.clean` still reads it, as a name can still decline or talk about itself.
    nonisolated package static let answerShape = try? OnDeviceModel.Shape("MissionName", property: "name", description: "The mission's name")

    /// - Parameter unavailability: why Apple Intelligence can't answer now, or nil when it can.
    package init(
        unavailability: @escaping @MainActor () -> OnDeviceModel.Unavailability? = { OnDeviceModel.unavailability },
        respond: @escaping Respond = { prompt, instructions in
            await OnDeviceModel.respond(
                to: prompt, instructions: instructions, maximumTokens: 32, likeliestWords: true, shape: MissionNamer.answerShape
            )
        },
        respondSplit: @escaping RespondSplit = { prompt, instructions, parts in
            guard let shape = try? OnDeviceModel.Shape.split(parts: parts) else { return .failure(.failed) }
            return await OnDeviceModel.respond(
                to: prompt, instructions: instructions, maximumTokens: 200, likeliestWords: true, shape: shape
            )
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.unavailability = unavailability
        self.respond = respond
        self.respondSplit = respondSplit
        self.now = now
    }

    /// Whether Apple Intelligence can answer now.
    package var canAsk: Bool {
        unavailability() == nil
    }

    /// The missions on screen now, the first first, with what each is named from, and those it may suggest splitting, with
    /// their questions: it asks for the first name that's settled and hasn't been asked with what it's named from now, once
    /// that stayed the same for `settleFor`; then, once no name waits, the same for a split.
    package func update(_ requests: [Request], splits: [SplitRequest] = []) {
        let date = now()
        var since: [MissionKey: (inputs: MissionNameInputs, at: Date)] = [:]
        for request in requests {
            if let was = self.since[request.key], was.inputs == request.inputs.basis {
                since[request.key] = was
            } else {
                since[request.key] = (request.inputs.basis, date)
            }
            if adopted.remove(request.key) != nil { asked[request.key] = request.inputs.basis }
        }
        var splitSince: [MissionKey: (makeup: MissionSplitQuestion.Makeup?, at: Date)] = [:]
        for split in splits {
            if let was = self.splitSince[split.key], was.makeup == split.question.makeup {
                splitSince[split.key] = was
            } else {
                splitSince[split.key] = (split.question.makeup, date)
            }
        }
        self.since = since
        self.splitSince = splitSince
        self.requests = requests
        splitRequests = splits
        next()
    }

    /// A split you confirmed gave these missions Apple Intelligence's names: what each is named from, now for one on screen,
    /// as the one that kept its key is, else as it first shows, is taken as what it was asked with, so that it isn't asked
    /// again until that changes.
    package func adopt(_ keys: [MissionKey]) {
        for key in keys {
            if let request = requests.first(where: { $0.key == key }) {
                asked[key] = request.inputs.basis
                adopted.remove(key)
            } else {
                adopted.insert(key)
            }
        }
    }

    /// Pull Request Order went off: it asks for nothing more, and forgets what it asked, and the answer under way. Once
    /// nothing's on screen, `update` with none, which keeps what it asked, so the same missions aren't asked again when they
    /// show again.
    package func stop() {
        requests = []
        since = [:]
        asked = [:]
        splitRequests = []
        splitSince = [:]
        groupings = [:]
        groupNames = [:]
        splitsTold = [:]
        adopted = []
        if asking != nil { dropsAnswer = true }
        cancelWake()
    }

    /// Forgets what it asked for these missions, whose names went, as when their source was turned off, and the answer under
    /// way for one: shown again, they're asked again.
    package func forget(where matches: (MissionKey) -> Bool) {
        asked = asked.filter { !matches($0.key) }
        since = since.filter { !matches($0.key) }
        splitSince = splitSince.filter { !matches($0.key) }
        groupings = groupings.filter { !matches($0.key) }
        groupNames = groupNames.filter { !matches($0.key) }
        splitsTold = splitsTold.filter { !matches($0.key) }
        adopted = adopted.filter { !matches($0) }
        if let asking, matches(asking) { dropsAnswer = true }
    }

    /// Asks for the next mission that's due, or comes back when one will be: while Apple Intelligence is off or getting
    /// ready, every `retryAfter`, as long as one waits for a name or a split; never on a Mac that can't run it. With nothing
    /// on screen, it doesn't come back. A split waits for every name that's due first.
    package func next() {
        guard !requests.isEmpty || !splitRequests.isEmpty else {
            cancelWake()
            return
        }
        guard asking == nil else { return }
        let date = now()
        let waitsForName = { (request: Request) in request.isSettled && self.asked[request.key] != request.inputs.basis }
        let waitsForSplit = { (split: SplitRequest) in self.splitsTold[split.key] != split.question.basis }
        if let unavailable = unavailability() {
            if unavailable != .notEligible, requests.contains(where: waitsForName) || splitRequests.contains(where: waitsForSplit) {
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
        for request in requests where waitsForName(request) {
            guard let since = since[request.key] else { continue }
            let due = since.at.addingTimeInterval(Self.settleFor)
            if due <= date {
                ask(request)
                return
            }
            soonest = min(soonest ?? due, due)
        }
        if let soonest {
            wake(at: soonest)
            return
        }
        for split in splitRequests where waitsForSplit(split) {
            guard let since = splitSince[split.key] else { continue }
            let due = since.at.addingTimeInterval(Self.settleFor)
            if due <= date {
                ask(split)
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
            let isStale = dropsAnswer || requests.contains { $0.key == request.key && $0.inputs.basis != request.inputs.basis }
            dropsAnswer = false
            guard !isStale else {
                next()
                return
            }
            switch answer {
            case .success(let text):
                asked[request.key] = request.inputs.basis
                if let name = MissionNaming.clean(text, titles: request.inputs.titles) {
                    named(request.key, name)
                } else {
                    Log.app.info("A mission keeps its name: Apple Intelligence's answer wasn't one")
                }
            case .failure(.busy), .failure(.notReady), .failure(.unavailable):
                waitUntil = now().addingTimeInterval(Self.retryAfter)
                Log.app.info("A mission's name waits: Apple Intelligence is busy, getting ready or off")
            case .failure(let failure):
                asked[request.key] = request.inputs.basis
                Log.app.info("A mission keeps its name: \(String(describing: failure), privacy: .public)")
            }
            next()
        }
    }

    /// What asking about a split came to: the grouping both answers agree on, by what the mission was made of, and the
    /// names given its groups so far, which it keeps either way; and the split, or none, unless Apple Intelligence was busy,
    /// getting ready or off, when it waits.
    private struct SplitWork {
        var grouping: (makeup: MissionSplitQuestion.Makeup?, grouping: [Set<ItemRef>]?)?
        var names: [MissionNameInputs: String?]
        var waits = false
        /// It stopped asking, as the question is no longer wanted (`stillAsks`): it tells nothing.
        var stops = false
        var split: MissionSplit?
    }

    private func ask(_ request: SplitRequest) {
        asking = request.key
        let question = request.question
        Task { [weak self] in
            guard let self else { return }
            let work = await work(on: question)
            asking = nil
            // Stopped or forgotten meanwhile, or made of something else now: nothing it found counts, and the mission is asked
            // again once it settles.
            let isStale = dropsAnswer || splitRequests.contains { $0.key == question.key && $0.question.basis != question.basis }
            dropsAnswer = false
            guard !isStale else {
                next()
                return
            }
            if let grouping = work.grouping { groupings[question.key] = grouping }
            groupNames[question.key] = work.names
            if work.waits {
                waitUntil = now().addingTimeInterval(Self.retryAfter)
                Log.app.info("A mission's split waits: Apple Intelligence is busy, getting ready or off")
            } else if work.stops {
                // Its mission left the screen meanwhile: what it found is kept, and it's asked the rest once it's back and
                // settled.
            } else {
                splitsTold[question.key] = question.basis
                if let split = work.split {
                    Log.app.info("Apple Intelligence suggests splitting a mission in \(split.plan.groups.count, privacy: .public)")
                }
                suggested(question.key, question.basis, work.split)
            }
            next()
        }
    }

    /// Asks both questions, unless it asked them of what the mission is made of now, and joins their answers; then, for the
    /// split that makes, names the groups that need a name, as it names missions, unless it did for what each is named from.
    private func work(on question: MissionSplitQuestion) async -> SplitWork {
        var work = SplitWork(names: groupNames[question.key] ?? [:])
        let grouping: [Set<ItemRef>]?
        if let known = groupings[question.key], known.makeup == question.makeup {
            grouping = known.grouping
        } else {
            let count = question.parts.count
            let instructions = MissionSplitting.instructions(for: question)
            var answers: [[[Int]]?] = []
            for reversed in [false, true] {
                guard stillAsks(question) else {
                    work.stops = true
                    return work
                }
                switch await respondSplit(MissionSplitting.prompt(question, reversed: reversed), instructions, count) {
                case .success(let json):
                    answers.append(MissionSplitting.grouping(fromJSON: json, parts: count, reversed: reversed))
                case .failure(.busy), .failure(.notReady), .failure(.unavailable):
                    work.waits = true
                    return work
                case .failure:
                    answers.append(nil)
                }
                // One that sees one piece of work settles it: only what both separate counts.
                if answers.last.map({ $0 == nil }) ?? true { break }
            }
            let joined = answers.count == 2 ? MissionSplitting.join(answers[0], answers[1], parts: count) : nil
            grouping = joined.map { MissionSplitting.refs(of: $0, in: question) }
            work.grouping = (question.makeup, grouping)
        }
        guard let grouping, let indices = MissionSplitting.indices(of: grouping, in: question),
              let plan = MissionSplitting.plan(question, grouping: indices)
        else { return work }
        var names: [String?] = []
        for group in plan.groups {
            guard MissionSplitting.isNamed(group, in: question) else {
                names.append(nil)
                continue
            }
            let inputs = MissionSplitting.inputs(of: group, in: question)
            if let known = work.names[inputs] {
                names.append(known)
                continue
            }
            guard stillAsks(question) else {
                work.stops = true
                return work
            }
            switch await respond(MissionNaming.prompt(inputs), MissionNaming.instructions) {
            case .success(let text):
                let name = MissionNaming.clean(text, titles: inputs.titles)
                work.names[inputs] = .some(name)
                names.append(name)
            case .failure(.busy), .failure(.notReady), .failure(.unavailable):
                work.waits = true
                return work
            case .failure:
                work.names[inputs] = .some(nil)
                names.append(nil)
            }
        }
        work.split = MissionSplit(key: question.key, basis: question.basis, grouping: grouping, plan: plan, names: names)
        return work
    }

    /// Whether the question it's working on is still wanted, between one answer and the next: its mission is on screen,
    /// made of what it was, and neither Pull Request Order nor its source went off meanwhile. Else Apple Intelligence is
    /// asked nothing more of it, so that what's off isn't asked about, and what's on again doesn't wait for it.
    private func stillAsks(_ question: MissionSplitQuestion) -> Bool {
        !dropsAnswer && splitRequests.contains { $0.key == question.key && $0.question.basis == question.basis }
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
