import BriefBarCore
import Foundation

/// Why a prompt didn't reach a session through BriefBar's extension in it.
public enum SendFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// A program holds the session, but BriefBar's extension doesn't listen in it.
    case noListener
    /// Nothing opened the session to load it, or it didn't load in time.
    case notLoaded
    /// No extension took the request in time.
    case unanswered
    /// The extension took it, but didn't say how it went in time: it may have gone.
    case lost
    /// The session's extension doesn't do this.
    case unsupported
    /// The extension said it didn't, and why.
    case failed(OutboxResult.Failure, String?)
    /// The app doesn't record the session the extension says it forked as a fork of it.
    case unconfirmedFork
    /// BriefBar's outbox can't be used: why.
    case outbox(String)
    /// BriefBar stopped it, as when its window closed.
    case cancelled
    /// BriefBar may send nothing anymore: Send Work to Copilot, or Send Prompts to Copilot Sessions, was turned off.
    case turnedOff
    /// BriefBar is sending the session another prompt.
    case busy
    /// Copilot works in the session's checkout for a task BriefBar sent, or BriefBar sends another session that works there
    /// a prompt.
    case checkoutBusy

    public var description: String {
        switch self {
        case .noListener: return "BriefBar's extension isn't running in the session."
        case .notLoaded: return "The session didn't load in the Copilot app."
        case .unanswered: return "BriefBar's extension in the session didn't answer."
        case .lost: return "BriefBar's extension in the session didn't say whether it got the prompt."
        case .unsupported: return "BriefBar's extension in the session can't do that."
        case .failed(let failure, let message):
            let detail = message.map { ": \($0)" } ?? "."
            switch failure {
            case .invalid: return "BriefBar's extension in the session couldn't read the request."
            case .expired: return "The request expired before the session took it."
            case .sendFailed: return "The session didn't take the prompt" + detail
            case .forkUnavailable: return "The session can't be forked this way, as chats can't."
            case .forkFailed: return "The Copilot app didn't fork the session" + detail
            case .stopFailed: return "The session didn't stop" + detail
            case .unknown: return "BriefBar's extension in the session couldn't do it" + detail
            case .unreadable: return "BriefBar couldn't read what its extension in the session said."
            }
        case .unconfirmedFork: return "The Copilot app doesn't record the fork that BriefBar's extension made."
        case .outbox(let why): return why
        case .cancelled: return "BriefBar stopped sending it."
        case .turnedOff: return "BriefBar can't send anything now."
        case .busy: return "BriefBar is sending it a prompt already."
        case .checkoutBusy: return "Copilot is working in its checkout for another task BriefBar sent."
        }
    }
}

extension SendFailure {
    /// It may have happened all the same: the extension took it but didn't say how it went, or said what BriefBar couldn't
    /// read; it said the session didn't take the prompt, as after a connection dropped once the session had it, or didn't
    /// fork, as when it couldn't read the fork's ID; or it named a fork that the app doesn't record.
    public var mayHaveGone: Bool {
        switch self {
        case .lost, .failed(.sendFailed, _), .failed(.forkFailed, _), .failed(.unreadable, _), .unconfirmedFork: return true
        default: return false
        }
    }
}

/// What became of a prompt sent through BriefBar's extension (`SessionSender`).
public enum SendOutcome: Sendable, Equatable {
    /// The session got it.
    case sent
    /// The session forked, and the fork got it.
    case forkedAndSent(fork: String)
    /// It didn't reach the session, or the session didn't fork: why. Nothing was sent, unless it was `lost`.
    case notSent(SendFailure)
    /// The session forked, but the prompt didn't reach the fork: why.
    case forkedNotSent(fork: String, SendFailure)
}

/// What became of a prompt that BriefBar asked the extension that sends it to report, and, once the session, or its fork,
/// got it, which report says how its turn goes.
public struct SendReceipt: Sendable, Equatable {
    public var outcome: SendOutcome
    /// The request whose report says how the prompt's turn goes (`CopilotOutbox.report(of:sentTo:)`): nil when nothing
    /// reports it, as an extension that started before BriefBar asked for reports doesn't.
    public var report: String?

    public init(_ outcome: SendOutcome, report: String? = nil) {
        self.outcome = outcome
        self.report = report
    }
}

/// Sends a prompt to one of the Copilot app's sessions, or forks the session and sends the fork the prompt, through
/// BriefBar's extension in it (`CopilotOutbox`), and waits for the extension to say how it went: only as you ask, never
/// in the demo. It waits without blocking a thread, looking at the outbox every `Timing.poll`.
///
/// A request goes to the session's extension when one listens; to a session that nothing holds, which opening it in the
/// app loads, with its extension; or, given time, to one that a program has just loaded. An extension claims a request
/// within moments, or BriefBar withdraws it; once claimed, it's finished, however long that takes, and its result says
/// how it went. A fork is the app's own: the session's extension runs `fork_session`, then the fork's own extension,
/// which runs by the time the fork is made, sends it the prompt, once the app's database records it as a fork of the
/// session.
public struct SessionSender: Sendable {
    /// What a send does beyond the outbox, which tests stand in for.
    public struct Effects: Sendable {
        /// Opens a session in the Copilot app, which loads it, with its extension, when nothing holds it: false when nothing
        /// opened it.
        public var open: @Sendable (String) async -> Bool
        /// Whether a program holds the session now, as the Copilot app does while it has it loaded (`SessionLock`).
        public var isHeld: @Sendable (String) -> Bool
        /// What the app records of a session that's said to be a fork (`AppSessions.forkRecord`).
        public var forkRecord: @Sendable (String) -> ForkRecord
        /// The forks the app records of a session, made at a given time or later (`AppSessions.forks`): nil when it can't
        /// tell now.
        public var forks: @Sendable (_ original: String, _ since: Date) -> [String]?
        /// Whether an extension that says it listens still runs (`CopilotOutbox.isLive`).
        public var isLive: @Sendable (OutboxListener) -> Bool
        /// Whether BriefBar may still send, as you turned it on: asked before each request, and while one waits for an
        /// extension to take it.
        public var mayGoOn: @Sendable () async -> Bool
        /// Takes the fork for this send, and the checkout it works in, before its prompt is written, so that no other prompt
        /// goes to it or to its checkout meanwhile: nil once it's taken; why not when BriefBar sends it another prompt
        /// already (`busy`), or Copilot works in its checkout (`checkoutBusy`).
        public var reserve: @Sendable (String) async -> SendFailure?
        public var now: @Sendable () -> Date

        public init(
            open: @escaping @Sendable (String) async -> Bool, isHeld: @escaping @Sendable (String) -> Bool,
            forkRecord: @escaping @Sendable (String) -> ForkRecord,
            forks: @escaping @Sendable (_ original: String, _ since: Date) -> [String]? = { _, _ in nil },
            isLive: @escaping @Sendable (OutboxListener) -> Bool = { CopilotOutbox.isLive($0) },
            mayGoOn: @escaping @Sendable () async -> Bool = { true },
            reserve: @escaping @Sendable (String) async -> SendFailure? = { _ in nil },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.open = open
            self.isHeld = isHeld
            self.forkRecord = forkRecord
            self.forks = forks
            self.isLive = isLive
            self.mayGoOn = mayGoOn
            self.reserve = reserve
            self.now = now
        }
    }

    /// How long each step may take. As measured, an extension takes a request at once, a send is taken at once, and a
    /// fork takes about 22 seconds, the app recording it as the session's well before it's done; a session that the app
    /// hadn't loaded loads as it opens, and its extension listens about 11 seconds later.
    public struct Timing: Sendable {
        /// How often BriefBar looks at the outbox, and the app's database, while it waits.
        public var poll: Duration = .milliseconds(150)
        /// How long a listening extension has to claim a request.
        public var claim: TimeInterval = 10
        /// How long a session that nothing had open has to load once it's opened, until a program holds it.
        public var load: TimeInterval = 45
        /// How long an extension has to listen, once a program holds its session.
        public var listen: TimeInterval = 30
        /// How long a claimed send has to say how it went.
        public var sent: TimeInterval = 60
        /// How long a claimed fork has to say how it went.
        public var forked: TimeInterval = 120
        /// How long the app has to record a fork as the session's.
        public var confirm: TimeInterval = 10

        public init() {}
    }

    public let outbox: CopilotOutbox
    public let effects: Effects
    public let timing: Timing

    public init(outbox: CopilotOutbox = .standard, effects: Effects, timing: Timing = Timing()) {
        self.outbox = outbox
        self.effects = effects
        self.timing = timing
    }

    /// Sends the session a prompt.
    public func send(_ prompt: String, to session: String) async -> SendOutcome {
        await send(prompt, to: session, report: false).outcome
    }

    /// Sends the session a prompt, and, with `report`, asks its extension to report how the prompt's turn goes.
    public func send(_ prompt: String, to session: String, report: Bool) async -> SendReceipt {
        switch await request(.send(prompt, to: session, report: report, now: effects.now())) {
        case .success(let result): return SendReceipt(.sent, report: result.reports ? result.requestId : nil)
        case .failure(let why): return SendReceipt(.notSent(why))
        }
    }

    /// Forks the session, then sends the fork the prompt. The session itself gets no message: the app only notes the fork
    /// in it. The fork is one that the app's database records as the session's, made since the request: the one its
    /// extension names; or, when it named none, or one that isn't, or didn't say it made one, the one fork of the session
    /// made since, if there's just one. Otherwise there's no telling which, if any.
    public func forkAndSend(_ prompt: String, from session: String) async -> SendOutcome {
        await forkAndSend(prompt, from: session, report: false).outcome
    }

    /// Forks the session, then sends the fork the prompt, as `forkAndSend(_:from:)` does, and, with `report`, asks the
    /// fork's extension to report how the prompt's turn goes there.
    public func forkAndSend(_ prompt: String, from session: String, report: Bool) async -> SendReceipt {
        // When it starts, to the instant: the request's own times are whole seconds, and a fork made earlier in the same
        // second is none of its own.
        let started = effects.now()
        let unnamed: SendFailure
        switch await request(.fork(session, now: started)) {
        case .success(let result):
            guard let id = result.forkSessionId else {
                unnamed = .failed(.forkFailed, nil)
                break
            }
            switch await confirm(id, asForkOf: session, madeSince: started) {
            case nil: return await sendFork(prompt, to: id, report: report)
            case .unconfirmedFork?: unnamed = .unconfirmedFork
            case let stopped?: return SendReceipt(.forkedNotSent(fork: id, stopped))
            }
        case .failure(let why):
            guard Self.mayHaveForked(why) else { return SendReceipt(.notSent(why)) }
            unnamed = why
        }
        switch await theFork(of: session, madeSince: started) {
        case .success(let found?): return await sendFork(prompt, to: found, report: report)
        case .success(nil): return SendReceipt(.notSent(unnamed))
        case .failure(let stopped): return SendReceipt(.notSent(stopped))
        }
    }

    /// Stops the turn that runs in the session now, as the app's own Stop does, through its extension: only one that listens
    /// in it now, and can (`OutboxRequest.Kind.stop`), as one that started before BriefBar could ask it to can't. It never
    /// opens or loads the session, whose turn would have stopped with it.
    public func stop(_ session: String) async -> Result<Void, SendFailure> {
        guard let listener = liveListener(of: session) else { return .failure(.noListener) }
        guard listener.kinds.contains(.stop) else { return .failure(.unsupported) }
        switch await request(.stop(session, now: effects.now())) {
        case .success: return .success(())
        case .failure(let why): return .failure(why)
        }
    }

    /// Sends the fork the prompt, once no other is on its way to it, or to its checkout.
    private func sendFork(_ prompt: String, to fork: String, report: Bool) async -> SendReceipt {
        if let busy = await effects.reserve(fork) { return SendReceipt(.forkedNotSent(fork: fork, busy)) }
        // The fork's extension listens by the time the fork is made: its request goes first, then the fork opens.
        switch await request(.send(prompt, to: fork, report: report, now: effects.now()), opens: true) {
        case .success(let result): return SendReceipt(.forkedAndSent(fork: fork), report: result.reports ? result.requestId : nil)
        case .failure(let why): return SendReceipt(.forkedNotSent(fork: fork, why))
        }
    }

    /// Writes a request, and waits for its result: first for an extension to claim it, then, once one has, for the result,
    /// which comes however long the request takes, unless the extension ended meanwhile.
    /// - Parameter opens: opens the session once the request is written, even when a program holds it already.
    func request(_ request: OutboxRequest, opens: Bool = false) async -> Result<OutboxResult, SendFailure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let mayGoOn = await effects.mayGoOn()
        // Stopped while that was asked: nothing's written.
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard mayGoOn else { return .failure(.turnedOff) }
        let session = request.sessionId
        outbox.removeOld(now: effects.now())
        var listening: Date?
        if let listener = liveListener(of: session) {
            guard listener.kinds.contains(request.kind) else { return .failure(.unsupported) }
            listening = effects.now()
        }
        do {
            try outbox.write(request)
        } catch {
            return .failure(.outbox(String(describing: error)))
        }
        // A session that nothing holds loads as it opens, with its extension. One that a program holds already isn't
        // opened unless asked: a CLI's would load in the app too, and its history fork.
        let loads = listening == nil && !effects.isHeld(session)
        if loads || opens {
            let opened = await effects.open(session)
            if !opened, loads, outbox.withdraw(request) { return .failure(.notLoaded) }
            // An extension that listens has from now to claim it, however long opening the session took.
            if listening != nil { listening = effects.now() }
        }
        let start = effects.now()
        var heldSince: Date?
        claiming: while true {
            if let result = outbox.takeResult(of: request) { return Self.outcome(result) }
            guard outbox.isWaiting(request) else { break }
            let now = effects.now()
            var gaveUp: SendFailure?
            if Task.isCancelled {
                gaveUp = .cancelled
            } else if await !effects.mayGoOn() {
                gaveUp = .turnedOff
            } else if listening == nil, let listener = liveListener(of: session) {
                if listener.kinds.contains(request.kind) { listening = now } else { gaveUp = .unsupported }
            }
            if gaveUp == nil {
                if let since = listening {
                    if now.timeIntervalSince(since) > timing.claim { gaveUp = .unanswered }
                } else if effects.isHeld(session) {
                    let since = heldSince ?? now
                    heldSince = since
                    if now.timeIntervalSince(since) > timing.listen { gaveUp = .noListener }
                } else if now.timeIntervalSince(start) > timing.load {
                    gaveUp = .notLoaded
                }
            }
            if let gaveUp {
                if outbox.withdraw(request) { return .failure(gaveUp) }
                // Claimed meanwhile: its result is to come.
                break claiming
            }
            await pause()
        }
        // Claimed: it goes on, whatever BriefBar does, so BriefBar waits for how it went, even once it's stopped.
        let claimed = effects.now()
        let wait = request.kind == .fork ? timing.forked : timing.sent
        while true {
            if let result = outbox.takeResult(of: request) { return Self.outcome(result) }
            if effects.now().timeIntervalSince(claimed) > wait { return .failure(.lost) }
            await pauseEvenIfStopped()
        }
    }

    /// Why the app's database doesn't confirm the session as a fork of `original` made since `since`, or nil once it does:
    /// it's waited for as the app makes the fork, and while it can't be read, until it says so in time (`unconfirmedFork`).
    /// One that it records as a fork already, of another session or from before the request, is none of its own, as when
    /// the name a session was given misled its extension. Nothing's read once it's stopped, or turned off.
    func confirm(_ fork: String, asForkOf original: String, madeSince since: Date) async -> SendFailure? {
        let start = effects.now()
        while true {
            if let stopped = await stopped() { return stopped }
            // What it's recorded as, before the session's forks are read: one recorded as a fork by then is among them, if
            // it's one of its own.
            let record = effects.forkRecord(fork)
            if let forks = effects.forks(original, since) {
                if forks.contains(fork) { return nil }
                if case .forked = record { return .unconfirmedFork }
            }
            if effects.now().timeIntervalSince(start) > timing.confirm { return .unconfirmedFork }
            await pause()
        }
    }

    /// Why BriefBar may go no further, or nil: it was stopped, or turned off.
    private func stopped() async -> SendFailure? {
        if Task.isCancelled { return .cancelled }
        let mayGoOn = await effects.mayGoOn()
        if Task.isCancelled { return .cancelled }
        return mayGoOn ? nil : .turnedOff
    }

    /// The app may have forked the session all the same: the extension couldn't read the fork's ID from what the app's
    /// fork said, or didn't say how it went, or said what BriefBar couldn't read.
    static func mayHaveForked(_ why: SendFailure) -> Bool {
        switch why {
        case .lost, .failed(.forkFailed, _), .failed(.unreadable, _): return true
        default: return false
        }
    }

    /// The one fork of the session that the app's database records, made since `since`, read again while it can't be read,
    /// for a fork its extension didn't name: nil when there's none, or more than one, or the database can't be read in time;
    /// why not, once it's stopped or turned off, when nothing more is read.
    func theFork(of original: String, madeSince since: Date) async -> Result<String?, SendFailure> {
        let start = effects.now()
        while true {
            if let stopped = await stopped() { return .failure(stopped) }
            if let forks = effects.forks(original, since) { return .success(forks.count == 1 ? forks.first : nil) }
            if effects.now().timeIntervalSince(start) > timing.confirm { return .success(nil) }
            await pause()
        }
    }

    private func liveListener(of session: String) -> OutboxListener? {
        outbox.listener(of: session).flatMap { effects.isLive($0) ? $0 : nil }
    }

    private static func outcome(_ result: OutboxResult) -> Result<OutboxResult, SendFailure> {
        guard let failure = result.failure else { return .success(result) }
        return .failure(.failed(failure, result.message))
    }

    private func pause() async {
        try? await Task.sleep(for: timing.poll)
    }

    /// A pause that being stopped doesn't cut short, for a request that goes on anyway.
    private func pauseEvenIfStopped() async {
        let poll = timing.poll
        await Task.detached { try? await Task.sleep(for: poll) }.value
    }
}
