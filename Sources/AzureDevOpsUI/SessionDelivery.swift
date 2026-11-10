import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization

/// How a prompt would reach a session that's there already through BriefBar's extension in it, as things stand, for the
/// composer to say before you send it (`CopilotTasksStore.reach(of:)`).
enum SessionReach: Equatable {
    /// BriefBar's extension listens in the session: it takes the prompt at once, and forks the session if `canFork`.
    case listening(canFork: Bool)
    /// Nothing has the session open: opening it in the Copilot app loads it, with BriefBar's extension, which takes the
    /// prompt then.
    case loads
    /// The Copilot app, or a CLI, has the session open without BriefBar's extension, since before Send Prompts to Copilot
    /// Sessions was on.
    case noListener(inApp: Bool)
    /// Nothing has it open, and it isn't one of the Copilot app's sessions, such as a task's that BriefBar started with the
    /// CLI, so the app can't load it.
    case notInApp
    /// Send Prompts to Copilot Sessions is off.
    case off

    /// BriefBar sends it itself, rather than copying it for you to paste.
    func sends(forking: Bool) -> Bool {
        whyNot(forking: forking) == nil
    }

    /// Why BriefBar can't send it itself, and what to do about it; nil when it can.
    func whyNot(forking: Bool) -> String? {
        switch self {
        case .listening(canFork: false) where forking:
            return "BriefBar's extension in the session can't fork it."
        case .listening, .loads:
            return nil
        case .noListener(let inApp):
            return inApp
                ? "The Copilot app has had the session open since before \(CopilotSessionPrompts.title) was on. Restart the session for BriefBar to send it prompts."
                : "A Copilot CLI has the session open, without BriefBar's extension. Restart it there for BriefBar to send it prompts."
        case .notInApp:
            return "It isn't one of the Copilot app's sessions, so BriefBar can't send it prompts there."
        case .off:
            return "To have BriefBar send prompts to the Copilot app's sessions, turn on \(CopilotSessionPrompts.title) in Settings › Agents."
        }
    }
}

/// What became of a prompt for a session that's there already (`CopilotTasksStore.deliver`).
enum SessionDelivery: Equatable {
    /// BriefBar's extension in the session sent it the prompt.
    case sent
    /// The session forked, and BriefBar's extension in the fork sent it the prompt.
    case forkedAndSent(fork: String)
    /// BriefBar couldn't send it, so it copied what to paste, and opened the session to paste it in.
    case fellBack(SessionFallback)
    /// Nothing went, and nothing opened: why.
    case notSent(String)
}

/// What BriefBar did once it couldn't send a prompt itself, as Open in Copilot did: it copied what to paste, the prompt or
/// `/fork <prompt>`, and opened the session to paste it in.
struct SessionFallback: Equatable {
    /// Why it couldn't, in a sentence or two.
    var reason: String
    /// The composer said so before you sent it: no extension listens in the session.
    var wasForeseen = false
    /// It copied `/fork <prompt>`, so the app's own `/fork` forks the session and sends the fork the prompt, as you paste
    /// it and send it there.
    var pastesFork = false
    /// It copied the prompt for a fork you make first, in the terminal, with the Copilot CLI's own `/fork`, which takes a
    /// name for the fork rather than a prompt.
    var forksFirst = false
    /// The session, or the fork, may have the prompt already, or the session may have forked: its extension took it but
    /// didn't say how it went, or said it failed, which it also says once it stops waiting (`SendFailure.mayHaveGone`).
    var mayHaveSent = false
    /// Where the session showed, for you to paste it in.
    var place: Place = .app
    /// The session it opened: the session itself, or the fork, once there's one.
    var session: String
    /// The fork, when the session forked but the prompt didn't reach it.
    var fork: String?

    /// What to look at before you paste it, when the session, or the fork, may have the prompt already, or the session
    /// may have forked: nil when it can't.
    var uncertainty: String? {
        guard mayHaveSent else { return nil }
        if fork != nil { return "If the fork has it already, don't." }
        return pastesFork || forksFirst ? "If the session forked already, don't." : "If the session has it already, don't."
    }
}

extension SessionFallback {
    /// Where a session showed for you to paste a prompt in.
    enum Place: Equatable {
        /// In the Copilot app.
        case app
        /// In the terminal that the Copilot CLI that has it open runs in, which came to the front: not necessarily the
        /// session's own window or tab in it.
        case terminal
    }
}

/// Sessions a delivery opened, so that it shows each once; or took, as a fork it sends to, to give back once it's done.
@MainActor private final class SessionIDs {
    var ids: Set<String> = []
}

/// Why a Push & Reply mustn't go to a session as BriefBar sends it (`CopilotTasksStore.turnProblem`): read whenever it's
/// asked, but at most once a second, from a task that may run anywhere; of the fork it goes to instead, and the checkout
/// that works in, once BriefBar took the fork for it (`watch`).
private final class TurnWatch: Sendable {
    private let read: @Sendable (CopilotTasksStore.PushOnItsWay) -> String?
    private let state: Mutex<(push: CopilotTasksStore.PushOnItsWay, at: ContinuousClock.Instant?, problem: String?)>

    init(_ push: CopilotTasksStore.PushOnItsWay, read: @escaping @Sendable (CopilotTasksStore.PushOnItsWay) -> String?) {
        self.read = read
        state = Mutex((push: push, at: nil, problem: nil))
    }

    /// The last read, while it's less than a second old; a new one otherwise.
    func problem() -> String? {
        let now = ContinuousClock.now
        let last = state.withLock { $0 }
        if let at = last.at, now - at < .seconds(1) { return last.problem }
        let problem = read(last.push)
        // Unless it watches another session since.
        state.withLock {
            guard $0.push.session == last.push.session else { return }
            $0.at = now
            $0.problem = problem
        }
        return problem
    }

    /// Watches the session the push goes to instead from now on, and the checkout it works in: read anew when next asked.
    func watch(_ push: CopilotTasksStore.PushOnItsWay) {
        state.withLock { $0 = (push: push, at: nil, problem: nil) }
    }

    var lastProblem: String? {
        state.withLock { $0.problem }
    }
}

extension SendFailure {
    /// What went wrong, for the log: never the extension's own words.
    var kind: String {
        switch self {
        case .noListener: return "no extension listens in the session"
        case .notLoaded: return "the session didn't load"
        case .unanswered: return "the extension didn't answer"
        case .lost: return "the extension didn't say how it went"
        case .unsupported: return "the extension can't do it"
        case .failed(let failure, _): return "the extension said \(failure.rawValue)"
        case .unconfirmedFork: return "the app doesn't record the fork"
        case .outbox: return "the outbox can't be used"
        case .cancelled: return "cancelled"
        case .turnedOff: return "turned off"
        case .busy: return "a prompt is on its way to it already"
        case .checkoutBusy: return "Copilot works in its checkout"
        }
    }
}

extension SessionChoice {
    /// The Copilot app can fork it, with its history and its changes, into a worktree of its own: one of the app's project
    /// sessions, or a task of BriefBar's that went on with one. Not a chat; nor BriefBar's own sessions, which aren't the
    /// app's.
    var canFork: Bool {
        if let session = appSession { return !session.isChat }
        return run?.isAppSession == true
    }
}

extension CopilotTasksStore {
    static let cantSendNow = "BriefBar can't send anything now."

    /// Why a session that a CLI has open didn't come up, once BriefBar copied the prompt for it: why BriefBar couldn't send
    /// it itself, unless the window said so already; where to paste it; and, when the session may have it already, to look
    /// first.
    static func cantBringUp(_ fallback: SessionFallback) -> String {
        explaining(fallback.forksFirst ? cantBringUpToFork : cantBringUp, fallback)
    }

    /// Why a session didn't open in the Copilot app, once BriefBar couldn't send it the prompt itself: why it couldn't,
    /// unless the window said so already; that nothing opens the app's sessions; and, when the session may have it already,
    /// to look first, rather than send it again, with the CLI or otherwise.
    static func cantOpenInApp(_ fallback: SessionFallback) -> String {
        explaining(cantOpenInApp, fallback)
    }

    /// What BriefBar says when a session didn't show for a prompt it couldn't send itself: why it couldn't, unless the
    /// window said so already; `what` happened then; and, when the session may have it already, to look first.
    private static func explaining(_ what: String, _ fallback: SessionFallback) -> String {
        var parts = [what]
        if !fallback.wasForeseen {
            var reason = fallback.reason
            if let last = reason.last, !".!?".contains(last) { reason += "." }
            parts.insert(reason, at: 0)
        }
        if let uncertainty = fallback.uncertainty { parts.append(uncertainty) }
        return parts.joined(separator: " ")
    }

    /// Where to paste the prompt when a CLI has the session open where BriefBar can't bring it up.
    static let cantBringUp = "BriefBar copied the prompt, but the Copilot CLI has the session open where BriefBar can't bring it up, such as in tmux or over SSH. Paste it there, and send it: opening the session in a second terminal, or in the app, would fork its history."

    /// Why a session that a CLI has open didn't come up, once BriefBar copied the prompt for a fork of it that you make
    /// there first: the CLI's own `/fork` takes a name for the fork, not a prompt, and pasted in the session itself, the
    /// prompt would go to it rather than to a fork.
    static let cantBringUpToFork = "BriefBar copied the prompt, but the Copilot CLI has the session open where BriefBar can't bring it up, such as in tmux or over SSH. Fork the session there with /fork, then paste the prompt in the fork, and send it. Don't open the session in a second terminal, or in the app: the CLI wouldn't see what happens there."

    /// Where BriefBar's requests to its extension go (`CopilotOutbox`).
    var outbox: CopilotOutbox { outboxForTests ?? .standard }

    /// Whether Send Prompts to Copilot Sessions is on, in Settings › Agents, which installs BriefBar's extension in the
    /// Copilot app's sessions that start afterwards. While it's off, BriefBar sends no session anything, even one whose
    /// extension still listens, as one does until the session restarts.
    var sessionPromptsAreOn: Bool {
        CopilotSessionPrompts.isOn(in: settings.defaults)
    }

    /// Whether BriefBar may send a prompt to a session, or go on with one on its way: Send Work to Copilot and Send
    /// Prompts to Copilot Sessions are on, outside the demo, and Azure DevOps hasn't stopped.
    var maySendToSessions: Bool {
        canSend && isOn && sessionPromptsAreOn && !hasStopped
    }

    /// How a prompt would reach the session now (`SessionReach`): not at all while Send Prompts to Copilot Sessions is off;
    /// through BriefBar's extension in it, as the outbox says, if that still runs; and if not, by loading it, unless the
    /// Copilot app or a CLI has it open already, as its lock says. Read off the main thread, and nothing while Send Work to
    /// Copilot is off, or in the demo.
    func reach(of choice: SessionChoice) async -> SessionReach? {
        guard canSend, isOn, !hasStopped, ItemRef.session(choice.id) != nil else { return nil }
        guard sessionPromptsAreOn else { return .off }
        let id = choice.id
        let outbox = outbox
        let homes = await sessionHomes()
        // Again, after that wait.
        guard canSend, isOn, !hasStopped else { return nil }
        guard sessionPromptsAreOn else { return .off }
        let found = await Task.detached(priority: .userInitiated) { () -> (listener: OutboxListener?, holder: pid_t?) in
            let listener = outbox.listener(of: id).flatMap { CopilotOutbox.isLive($0) ? $0 : nil }
            return (listener, homes.lazy.compactMap { AppSessions.holder(of: id, home: $0) }.first)
        }.value
        // Again, after that read.
        guard canSend, isOn, !hasStopped else { return nil }
        guard sessionPromptsAreOn else { return .off }
        if let listener = found.listener, listener.kinds.contains(.send) {
            return .listening(canFork: listener.kinds.contains(.fork))
        }
        if let holder = found.holder { return .noListener(inApp: holdsInApp(holder)) }
        return choice.appSession != nil || choice.run?.isAppSession == true ? .loads : .notInApp
    }

    /// Delivers a prompt to a session that's there already: the one way to, for the composer and for whatever else sends
    /// one. BriefBar's extension in the session sends it the prompt as your own message, or, `forking`, forks the session
    /// with the Copilot app's own fork, and the fork's extension sends the fork the prompt; then the session, or the fork,
    /// shows (`show`). When the extension can't, BriefBar does what Open in Copilot did: it copies the prompt, or for a
    /// fork `/fork <prompt>`, which the app's own `/fork` takes, and shows the session to paste it in; or the fork, with
    /// the prompt, once the session forked but the prompt didn't reach it. Once the prompt's sent, what `handOff` says it
    /// takes care of leaves Needs You; once it's copied, as BriefBar sees it in a message sent the session, which says you
    /// pasted it (`copiedPrompts`), so a prompt you don't paste leaves the comments on Needs You. Only while Send Work to
    /// Copilot is on, never in the demo, and one prompt at a time for each session.
    /// - Parameter about: what of the pull request it's about, its threads, a build or its conflicts, and what for: once it's
    ///   sent, or copied for you to paste, BriefBar keeps that, to follow its turn in the session (`SentPrompt`). Whatever
    ///   it's about, the turns of the prompts sent the session before that weren't seen to end aren't followed after
    ///   (`overlap`).
    ///   - sentAt: as delivering it starts, which its sender may tell, as the time it took on what it's about: what the
    ///     session does from then on is its turn, even one over before BriefBar heard it went. It's free then, or nothing
    ///     goes.
    ///   - checkingPush: the pull request a Push & Reply pushes to, as the window wrote its prompt: nothing goes, not even
    ///     copied, while Copilot runs a turn in the session, or in its checkout (`turnProblem`), up to the moment the
    ///     session's extension takes the prompt, or BriefBar copies it; sent to a fork, as a comment's fix sent to push and
    ///     reply may be, in the fork, or in the checkout it works in, once BriefBar took the fork for it, or copies the
    ///     prompt for it; nor while the folder the session works in holds a merge of commits that the branch the prompt
    ///     names, its `targetBranch`, doesn't have, or that can't be checked (`pushProblem`); nor once the pull request
    ///     merges into another branch, as Azure DevOps says right before git checks, and again after
    ///     (`freshTargetProblem`), or as the list reads later (`retargetProblem`).
    /// - Returns: sent; forked and sent, with the fork; why it fell back; or why nothing went.
    func deliver(
        _ prompt: String, to choice: SessionChoice, forking: Bool = false, handOff: CommentHandOff? = nil, about: SentPrompt.About? = nil,
        at sentAt: Date = Date(), checkingPush: TaskPullRequest? = nil
    ) async -> SessionDelivery {
        // Until it's known whether it went, the turns of the prompts sent the session before aren't followed: it may reach
        // the session, and its turn end, before BriefBar hears it went (`pauseFollowing`). A fork's goes to the fork.
        if !forking { pauseFollowing(choice.id) }
        defer { if !forking { resumeFollowing(choice.id) } }
        let outcome = await deliverPrompt(prompt, to: choice, forking: forking, handOff: handOff, checkingPush: checkingPush)
        keep(about, sentTo: outcome, from: choice.id, forking: forking, at: sentAt, copying: prompt, handOff: handOff)
        return outcome
    }

    private func deliverPrompt(
        _ prompt: String, to choice: SessionChoice, forking: Bool, handOff: CommentHandOff?, checkingPush: TaskPullRequest?
    ) async -> SessionDelivery {
        guard canSend, isOn, !hasStopped, ItemRef.session(choice.id) != nil else { return .notSent(Self.cantSendNow) }
        let id = choice.id
        if forking, !choice.canFork { return .notSent("The Copilot app can't fork this session.") }
        // Sending to it while Copilot works in it would fork its history; while Copilot works in the checkout it works in
        // now, their work would mix.
        if let busy = busyReason(for: choice, in: currentFolder(of: choice) ?? choice.folder) { return .notSent(busy) }
        guard !delivering.contains(id) else { return .notSent("BriefBar is sending it a prompt already.") }
        delivering.insert(id)
        defer { delivering.remove(id) }
        // Whether BriefBar could send prompts to sessions as you sent this one: once it could, turning that off stops it.
        let promptsWereOn = sessionPromptsAreOn
        let reach = await reach(of: choice)
        // Again, after that wait: Send Work to Copilot may have been turned off, or a task started in it, meanwhile. Where it
        // works now, where the window found it only when that can't be told now, is the checkout that has to be free, and
        // that stays as it is until the prompt has gone, been taken back, or been copied with the session showing.
        guard canSend, isOn, !hasStopped, let reach else { return .notSent(Self.cantSendNow) }
        // Turned off meanwhile: nothing's sent, copied or opened, rather than copying it as when it was off already.
        guard sessionPromptsAreOn || !promptsWereOn else { return .notSent(Self.cantSendNow) }
        let checkout = currentFolder(of: choice) ?? choice.folder
        if let busy = busyReason(for: choice, in: checkout) { return .notSent(busy) }
        if let checkout { deliveringFolders[id] = checkout }
        defer { deliveringFolders[id] = nil }
        // While the checkout is BriefBar's to send to, so no task of its own changes it meanwhile: not while a turn runs in the
        // session, or in its checkout, nor once the pull request merges into another branch than the prompt names, as Azure
        // DevOps says right before git checks what it would push, and again after.
        let push = checkingPush.map {
            PushOnItsWay(pullRequest: $0, session: id, name: CopilotWork.quoted(choice.name, isTask: choice.run != nil), checkout: checkout)
        }
        if let push {
            if let problem = await stillGoesProblem(push) { return .notSent(problem) }
            if let problem = await freshTargetProblem(push.pullRequest) { return .notSent(problem) }
            if let problem = await pushProblem(push.pullRequest, in: checkout, name: push.name) { return .notSent(problem) }
            // Again, after git's wait, as after the one above.
            guard canSend, isOn, !hasStopped, sessionPromptsAreOn || !promptsWereOn else { return .notSent(Self.cantSendNow) }
            if let problem = await freshTargetProblem(push.pullRequest) { return .notSent(problem) }
            guard canSend, isOn, !hasStopped, sessionPromptsAreOn || !promptsWereOn else { return .notSent(Self.cantSendNow) }
            if let problem = await stillGoesProblem(push) { return .notSent(problem) }
        }
        if let why = reach.whyNot(forking: forking) {
            return await fallBack(prompt, in: id, forking: forking, reason: why, foreseen: true, promptsWereOn: promptsWereOn, push: push)
        }
        if case .loads = reach, !canOpenInApp { return .notSent(Self.cantOpenInApp) }

        let opened = SessionIDs()
        let reserved = SessionIDs()
        defer {
            for fork in reserved.ids { deliveringFolders[fork] = nil }
            delivering.subtract(reserved.ids)
        }
        let homes = await sessionHomes()
        let appHome = appHome
        // Read right before the request is written, and at most once a second while it waits for the extension to take it.
        let watch = push.map { TurnWatch($0) { Self.turnProblem($0, home: appHome) } }
        let effects = SessionSender.Effects(
            open: { [weak self] id in
                await MainActor.run {
                    // Stopped, or turned off, while this waited for its turn: nothing opens.
                    guard !Task.isCancelled, let self, self.maySendToSessions else { return false }
                    // One that didn't open shows again once the prompt has reached it.
                    guard self.load(id) else { return false }
                    opened.ids.insert(id)
                    return true
                }
            },
            isHeld: { id in homes.contains { AppSessions.isOpen(id, home: $0) } },
            forkRecord: { id in AppSessions.forkRecord(of: id, home: appHome) },
            forks: { original, since in AppSessions.forks(of: original, since: since, home: appHome) },
            mayGoOn: { [weak self] in
                // Nor a push while a turn runs in the session or its checkout, or once the pull request merges into another
                // branch than its prompt names.
                let turn = watch?.problem()
                return await MainActor.run {
                    guard let self else { return false }
                    return self.maySendToSessions && turn == nil && self.retargetProblem(checkingPush) == nil
                }
            },
            reserve: { [weak self] fork in
                // The checkout the fork works in, as its own state says, which another session may work in too: it has to
                // be free, unless it's this send's own, as when the fork works where the session does; and it stays as it
                // is, as the session's does, until the fork's prompt has gone, or been taken back.
                let folder = AppSessions.folder(of: fork, home: appHome)
                let key = folder.map(Self.checkoutKey)
                let isOwn = key != nil && key == checkout.map(Self.checkoutKey)
                let refused = await MainActor.run { () -> SendFailure? in
                    guard let self, !self.delivering.contains(fork) else { return .busy }
                    if let folder, !isOwn, self.isWorking(inFolder: folder) { return .checkoutBusy }
                    if let folder { self.deliveringFolders[fork] = folder }
                    self.delivering.insert(fork)
                    reserved.ids.insert(fork)
                    return nil
                }
                // A push goes from the fork from now on, which has the session's changes, in a worktree of its own: until the
                // fork's extension takes the prompt, it's the fork, and the checkout it works in, that mustn't run a turn,
                // read anew right before the request is written (`mayGoOn`).
                if refused == nil, let push { watch?.watch(push.forked(fork, in: folder)) }
                return refused
            }
        )
        let sender = SessionSender(outbox: outbox, effects: effects, timing: deliveryTimingForTests ?? SessionSender.Timing())
        // What a test notes (`ThisMac.noting`) goes with the sender into its own task, which loads the session there.
        let notes = ThisMac.noting
        let work = Task.detached(priority: .userInitiated) {
            await ThisMac.$noting.withValue(notes) {
                forking ? await sender.forkAndSend(prompt, from: id) : await sender.send(prompt, to: id)
            }
        }
        // Stopped, as when its window closes: a request that no extension took yet is taken back.
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        // Once it's stopped, or Send Work to Copilot or Send Prompts to Copilot Sessions is turned off, nothing more shows,
        // and nothing's copied.
        let goesOn = maySendToSessions && !Task.isCancelled
        switch outcome {
        case .sent, .forkedAndSent:
            let shown: String
            if case .forkedAndSent(let fork) = outcome {
                shown = fork
                Log.app.info("Forked a session in the Copilot app, and sent the fork a prompt")
            } else {
                shown = id
                Log.app.info("Sent a prompt to a session in the Copilot app")
            }
            if goesOn, !opened.ids.contains(shown) { _ = await show(shown) }
            if let handOff { handedOff(handOff, prompt) }
            if case .forkedAndSent(let fork) = outcome { return .forkedAndSent(fork: fork) }
            return .sent
        case .notSent(.cancelled), .forkedNotSent(_, .cancelled):
            return .notSent(SendFailure.cancelled.description)
        case .notSent(.turnedOff), .forkedNotSent(_, .turnedOff):
            return .notSent(retargetProblem(checkingPush) ?? watch?.lastProblem ?? Self.cantSendNow)
        case .notSent(let why):
            Log.app.error("Couldn't send a prompt to a session in the Copilot app: \(why.kind, privacy: .public)")
            guard goesOn else { return .notSent(Self.cantSendNow) }
            return await fallBack(prompt, in: id, forking: forking, reason: why.description, mayHaveSent: why.mayHaveGone, push: push)
        case .forkedNotSent(let fork, let why):
            Log.app.error("Forked a session in the Copilot app, but couldn't send the fork a prompt: \(why.kind, privacy: .public)")
            guard goesOn else { return .notSent(Self.cantSendNow) }
            // Pasted in the fork, a push goes from there: it's the fork, and the checkout it works in, that mustn't run a turn.
            let forked = push.map { $0.forked(fork, in: AppSessions.folder(of: fork, home: appHome)) }
            return await fallBack(
                prompt, in: fork, forking: forking, fork: fork, reason: why.description, mayHaveSent: why.mayHaveGone, push: forked
            )
        }
    }

    /// A Push & Reply on its way to a session: its pull request, the session, as a sentence names it, and the checkout it
    /// works in, which BriefBar checks up to the moment the prompt goes or is copied (`stillGoesProblem`).
    struct PushOnItsWay: Sendable {
        var pullRequest: TaskPullRequest
        var session: String
        var name: String
        var checkout: URL?

        /// The same push, on its way to a fork of the session instead, as a comment's fix sent to push and reply goes: the
        /// fork, "a fork of ‘Retry backoff’", and the worktree of its own it works in, when its state says which.
        func forked(_ fork: String, in folder: URL?) -> PushOnItsWay {
            PushOnItsWay(pullRequest: pullRequest, session: fork, name: "a fork of \(name)", checkout: folder)
        }
    }

    /// Why a Push & Reply on its way mustn't go now: the list has read that its pull request merges into another branch than
    /// its prompt names (`retargetProblem`), or Copilot runs a turn in the session, or in its checkout (`turnProblem`). Nil
    /// when it may, or for anything but a push.
    private func stillGoesProblem(_ push: PushOnItsWay?) async -> String? {
        guard let push else { return nil }
        if let problem = retargetProblem(push.pullRequest) { return problem }
        let home = appHome
        return await Task.detached(priority: .userInitiated) { Self.turnProblem(push, home: home) }.value
    }

    /// Why a Push & Reply mustn't go to a session now: Copilot runs a turn in it, or another of the app's sessions runs one
    /// in the checkout it works in, by the app's own flag, as its database says now; or BriefBar can't tell, as when that
    /// database can't be read, or doesn't keep the flag as BriefBar reads it (`AppSessions.running(home:strictly:)`). The
    /// prompt would wait for that turn, which may change what BriefBar checked, as a merge would. Nil when none does, as
    /// without the app's database, which no session of the app runs a turn without.
    nonisolated static func turnProblem(_ push: PushOnItsWay, home: URL) -> String? {
        let running: [String]
        do {
            running = try AppSessions.running(home: home, strictly: true)
        } catch {
            let why = (error as? AppSessions.TurnsUnknown) ?? .unreadable
            return "BriefBar couldn't tell whether Copilot is running a turn in \(push.name), or in the checkout it works in, so nothing went: \(why)"
        }
        if running.contains(push.session) {
            return "Copilot is running a turn in \(push.name), so nothing went: what that turn changes would go with the push, unchecked. Send it again once that turn is done."
        }
        guard let checkout = push.checkout else { return nil }
        let key = AppSessions.checkoutKey(checkout)
        guard running.contains(where: { $0 != push.session && AppSessions.folder(of: $0, home: home).map(AppSessions.checkoutKey) == key })
        else { return nil }
        return "Another Copilot session is running a turn in the checkout \(push.name) works in, so nothing went: what that turn changes would go with the push, unchecked. Send it again once that's done."
    }

    /// Why a Push & Reply mustn't go to a session: the folder it works in holds a merge of commits that the branch its prompt
    /// names, the pull request's `targetBranch`, doesn't have (`Git.checkPush(in:source:target:)`), as when it was
    /// retargeted after its conflicts were resolved there; or BriefBar couldn't check, as when the folder isn't a clone of
    /// the pull request's repository. Nil when it may go.
    /// - Parameter name: the session, as a sentence names it.
    private func pushProblem(_ pullRequest: TaskPullRequest, in folder: URL?, name: String) async -> String? {
        let target = pullRequest.targetBranch
        guard let folder else { return "BriefBar can't tell which folder \(name) works in, so it couldn't check what it would push, and nothing went." }
        let git = await git()
        do {
            try await git.checkClone(at: folder, of: pullRequest)
            switch try await git.checkPush(in: folder, source: pullRequest.sourceBranch, target: target) {
            case .clean: return nil
            case .foreignMerge: return "\(name) holds a merge that \(target) doesn't have, so nothing went. Fix the pull request in a new session."
            }
        } catch {
            Log.app.error("Couldn't check what a session would push: \(String(describing: type(of: error)), privacy: .public)")
            let why = (error as? GitError)?.description ?? String(describing: error)
            return "BriefBar couldn't check what \(name) would push, so nothing went: \(why)"
        }
    }

    /// Copies what to paste, and shows the session to paste it in: the prompt, or, to fork a session that hasn't forked,
    /// `/fork <prompt>`. It's handed off only once its turn is seen to start (`deliver`). Nothing's copied or shown once it's
    /// stopped, as when its window closed, or once Send Work to Copilot is off, as looked at right before; nor once Send
    /// Prompts to Copilot Sessions is off, unless the window said it would copy it because that was off as you sent it
    /// (`promptsWereOn`); nor a Push & Reply while a turn runs in its session or its checkout, or once the pull request
    /// merges into another branch than its prompt names (`push`, `stillGoesProblem`).
    private func fallBack(
        _ prompt: String, in session: String, forking: Bool, fork: String? = nil, reason: String, foreseen: Bool = false,
        mayHaveSent: Bool = false, promptsWereOn: Bool = true, push: PushOnItsWay? = nil
    ) async -> SessionDelivery {
        let way: Showing?
        if openForTests != nil {
            way = await cliHolder(of: session).map(Showing.terminal) ?? .app
        } else {
            way = await showing(session)
        }
        guard !Task.isCancelled else { return .notSent(SendFailure.cancelled.description) }
        // A fallback that the window said it would do, since Send Prompts to Copilot Sessions was off as you sent it, goes
        // on whether or not it's on now; any other, only while it is.
        guard canSend, isOn, !hasStopped, sessionPromptsAreOn || (foreseen && !promptsWereOn) else {
            return .notSent(Self.cantSendNow)
        }
        // Nor a Push & Reply while a turn runs in its session or its checkout, or once its pull request merges into another
        // branch than its prompt names; and, after that look, as above.
        if push != nil {
            if let problem = await stillGoesProblem(push) { return .notSent(problem) }
            guard !Task.isCancelled else { return .notSent(SendFailure.cancelled.description) }
            guard canSend, isOn, !hasStopped, sessionPromptsAreOn || (foreseen && !promptsWereOn) else {
                return .notSent(Self.cantSendNow)
            }
        }
        // Where it shows: in the terminal of a CLI that has it open; otherwise in the app, if anything opens its sessions.
        let place: SessionFallback.Place
        if case .terminal? = way { place = .terminal } else { place = .app }
        // The app's own /fork takes a prompt, and sends it to the fork; the CLI's takes a name for the fork, so in its
        // terminal you fork the session first, then paste the prompt.
        let forksHere = forking && fork == nil
        let pastesFork = forksHere && place == .app
        let fallback = SessionFallback(
            reason: reason, wasForeseen: foreseen, pastesFork: pastesFork, forksFirst: forksHere && place == .terminal,
            mayHaveSent: mayHaveSent, place: place, session: session, fork: fork
        )
        // Not only that the app doesn't open its sessions, which would have you run it with the CLI: why BriefBar didn't
        // send it, and when the session may have it already, to look first.
        guard let way else {
            Log.app.error("Couldn't open a session in the Copilot app")
            return .notSent(Self.cantOpenInApp(fallback))
        }
        guard copyAndShow(pastesFork ? "/fork \(prompt)" : prompt, in: session, way) else {
            if case .terminal = way {
                Log.app.error("Couldn't bring up the terminal of the Copilot CLI that has a session open")
                return .notSent(Self.cantBringUp(fallback))
            }
            Log.app.error("Couldn't open a session in the Copilot app")
            return .notSent(Self.cantOpenInApp(fallback))
        }
        Log.app.info("Copied a prompt for a session in the Copilot app, and showed the session")
        return .fellBack(fallback)
    }

    /// Puts the text on the clipboard, and shows the session the way it found it shows (`showing`): false when it didn't.
    private func copyAndShow(_ text: String, in id: String, _ way: Showing) -> Bool {
        if let openForTests { return openForTests(id, text) }
        ThisMac.copy(text)
        return Self.reveal(id, way)
    }

    /// How BriefBar shows a session (`show`).
    enum Showing: Equatable {
        /// In the Copilot app, by its `ghapp://sessions/` link.
        case app
        /// In the terminal that the CLI that has it open runs in, by the CLI's process.
        case terminal(pid_t)
    }

    /// Shows a session that a prompt was sent to, the way BriefBar opens one: in the Copilot app; or, while a CLI has it
    /// open, the terminal that CLI runs in, which comes to the front, since the app loading it too would fork its history.
    /// Not once it's stopped, or sending to sessions is off, as looked at right before. False when it didn't show.
    func show(_ id: String) async -> Bool {
        let way: Showing? = showForTests != nil ? .app : await showing(id)
        guard !Task.isCancelled, maySendToSessions, let way else { return false }
        if let showForTests { return showForTests(id) }
        return Self.reveal(id, way)
    }

    /// Stops the turn that runs in one of the Copilot app's sessions, as the app's own Stop does, through BriefBar's
    /// extension in it (`SessionSender.stop`): for a prompt BriefBar sent the session, whose line says Copilot is at it. When
    /// the extension can't, as one that started before it could, or while Send Prompts to Copilot Sessions is off, BriefBar
    /// shows the session, to stop it there. Only while Send Work to Copilot is on, never in the demo.
    /// - Returns: what to say once BriefBar didn't stop it itself; nil once it did.
    func stopTurn(in session: String) async -> String? {
        guard canSend, isOn, !hasStopped, AppSessions.isSessionID(session) else { return Self.cantSendNow }
        var why = "BriefBar can't stop it while \(CopilotSessionPrompts.title) is off."
        if sessionPromptsAreOn {
            let homes = await sessionHomes()
            let appHome = appHome
            let effects = SessionSender.Effects(
                open: { _ in false },
                isHeld: { id in homes.contains { AppSessions.isOpen(id, home: $0) } },
                forkRecord: { id in AppSessions.forkRecord(of: id, home: appHome) },
                mayGoOn: { [weak self] in await MainActor.run { self?.maySendToSessions ?? false } }
            )
            let sender = SessionSender(outbox: outbox, effects: effects, timing: deliveryTimingForTests ?? SessionSender.Timing())
            let result = await Task.detached(priority: .userInitiated) { await sender.stop(session) }.value
            guard canSend, isOn, !hasStopped else { return Self.cantSendNow }
            switch result {
            case .success:
                Log.app.info("Stopped a session's turn in the Copilot app")
                return nil
            case .failure(let failure):
                Log.app.error("Couldn't stop a session's turn in the Copilot app: \(failure.kind, privacy: .public)")
                switch failure {
                case .noListener, .unsupported: why = "BriefBar's extension in the session can't stop it."
                default: why = failure.description
                }
            }
        }
        let way: Showing? = showForTests != nil ? .app : await showing(session)
        guard canSend, isOn, !hasStopped else { return Self.cantSendNow }
        let shown = way.map { way in showForTests?(session) ?? Self.reveal(session, way) } ?? false
        return shown ? "\(why) Stop it in the session, which BriefBar showed." : "\(why) Stop it in the session, in the Copilot app."
    }

    /// How the session would show now: nil when nothing would show it, as without the Copilot app.
    private func showing(_ id: String) async -> Showing? {
        if let holder = await cliHolder(of: id) { return .terminal(holder) }
        return canOpenInApp ? .app : nil
    }

    /// The process of the Copilot CLI that has the session open now, as its lock says: nil when none does, or the app does.
    /// Nothing's read once Send Work to Copilot is off, or Azure DevOps has stopped.
    private func cliHolder(of id: String) async -> pid_t? {
        guard canSend, isOn, !hasStopped else { return nil }
        let homes = await sessionHomes()
        guard canSend, isOn, !hasStopped else { return nil }
        let holder = await Task.detached(priority: .userInitiated) {
            homes.lazy.compactMap { AppSessions.holder(of: id, home: $0) }.first
        }.value
        guard let holder, !holdsInApp(holder) else { return nil }
        return holder
    }

    private static func reveal(_ id: String, _ way: Showing) -> Bool {
        switch way {
        case .app: return openInApp(id)
        case .terminal(let pid): return bringUp(pid)
        }
    }

    /// Opens a session in the Copilot app, which loads it if nothing has it open: for a delivery, only for a session that
    /// nothing has open, or a fork the app just made.
    private func load(_ id: String) -> Bool {
        if let showForTests { return showForTests(id) }
        return canOpenInApp && Self.openInApp(id)
    }

    /// Where the sessions BriefBar can send to are: the Copilot app's folder and, when your shell sets another, the CLI's.
    func sessionHomes() async -> [URL] {
        let home = appHome
        let cliHome = CopilotCLI.home(environment: await environment())
        return AppSessions.folderKey(cliHome) == AppSessions.folderKey(home) ? [home] : [home, cliHome]
    }

    /// Whether the Copilot app has a session open, by the process that holds it: one the app is responsible for, as its
    /// runtime is. A CLI that you run in a terminal is the terminal's.
    func holdsInApp(_ pid: pid_t) -> Bool {
        if let appHoldsForTests { return appHoldsForTests(pid) }
        guard let app = URL(string: "ghapp://sessions").flatMap({ NSWorkspace.shared.urlForApplication(toOpen: $0) }),
              let responsible = Responsibility.responsible(for: pid)
        else { return false }
        return Self.isApp(
            app, responsiblePath: responsible.path,
            responsibleBundle: NSRunningApplication(processIdentifier: responsible.pid)?.bundleURL
        )
    }

    /// Whether the process macOS holds responsible for another is the app: its executable is in the app, as for the
    /// Copilot app's agents, which can be responsible for themselves while macOS attributes them to it; or it runs as
    /// the app.
    nonisolated static func isApp(_ app: URL, responsiblePath: String?, responsibleBundle: URL?) -> Bool {
        let folder = AppSessions.folderKey(app)
        if let responsiblePath, AppSessions.folderKey(URL(fileURLWithPath: responsiblePath)).hasPrefix(folder + "/") { return true }
        return responsibleBundle.map { AppSessions.folderKey($0) == folder } ?? false
    }

    /// Brings the app that a CLI runs in to the front, such as Terminal: the one macOS holds responsible for it, but not
    /// necessarily the CLI's own window or tab in it. False when it can't tell, as in tmux or over SSH.
    static func bringUp(_ pid: pid_t) -> Bool {
        guard let responsible = Responsibility.responsible(for: pid), responsible.pid != pid,
              let url = NSRunningApplication(processIdentifier: responsible.pid)?.bundleURL
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        ThisMac.openApplication(at: url, configuration: configuration)
        return true
    }
}
