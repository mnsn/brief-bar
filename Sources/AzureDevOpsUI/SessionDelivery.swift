import AppKit
import AzureDevOpsCore
import BriefBarCore
import CopilotTasks
import Foundation

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

    /// Why a session that a CLI has open didn't come up, once BriefBar copied the prompt for it.
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
    /// the prompt, once the session forked but the prompt didn't reach it. Once the prompt's sent, or copied and the
    /// session showing, what `handOff` says it takes care of leaves Needs You. Only while Send Work to Copilot is on, never
    /// in the demo, and one prompt at a time for each session.
    /// - Returns: sent; forked and sent, with the fork; why it fell back; or why nothing went.
    func deliver(_ prompt: String, to choice: SessionChoice, forking: Bool = false, handOff: CommentHandOff? = nil) async -> SessionDelivery {
        guard canSend, isOn, !hasStopped, ItemRef.session(choice.id) != nil else { return .notSent(Self.cantSendNow) }
        let id = choice.id
        if forking, !choice.canFork { return .notSent("The Copilot app can't fork this session.") }
        // Sending to it while Copilot works in it would fork its history; while Copilot works in its checkout, their work would mix.
        if let busy = busyReason(for: choice) { return .notSent(busy) }
        guard !delivering.contains(id) else { return .notSent("BriefBar is sending it a prompt already.") }
        delivering.insert(id)
        defer { delivering.remove(id) }
        let reach = await reach(of: choice)
        // Again, after that wait: Send Work to Copilot may have been turned off, or a task started in it, meanwhile.
        guard canSend, isOn, !hasStopped, let reach else { return .notSent(Self.cantSendNow) }
        if let busy = busyReason(for: choice) { return .notSent(busy) }
        if let why = reach.whyNot(forking: forking) {
            return await fallBack(prompt, in: id, forking: forking, reason: why, foreseen: true, handOff: handOff)
        }
        if case .loads = reach, !canOpenInApp { return .notSent(Self.cantOpenInApp) }
        // Where it works stays as it is until the prompt has gone, or been taken back.
        if let folder = choice.folder ?? folder(of: choice) { deliveringFolders[id] = folder }
        defer { deliveringFolders[id] = nil }

        let opened = SessionIDs()
        let reserved = SessionIDs()
        defer { delivering.subtract(reserved.ids) }
        let homes = await sessionHomes()
        let appHome = appHome
        let effects = SessionSender.Effects(
            open: { [weak self] id in
                await MainActor.run {
                    // Stopped, or turned off, while this waited for its turn: nothing opens.
                    guard !Task.isCancelled, let self, self.maySendToSessions else { return false }
                    opened.ids.insert(id)
                    return self.load(id)
                }
            },
            isHeld: { id in homes.contains { AppSessions.isOpen(id, home: $0) } },
            forkRecord: { id in AppSessions.forkRecord(of: id, home: appHome) },
            forks: { original, since in AppSessions.forks(of: original, since: since, home: appHome) },
            mayGoOn: { [weak self] in
                await MainActor.run { self?.maySendToSessions ?? false }
            },
            reserve: { [weak self] fork in
                await MainActor.run {
                    guard let self, !self.delivering.contains(fork) else { return false }
                    self.delivering.insert(fork)
                    reserved.ids.insert(fork)
                    return true
                }
            }
        )
        let sender = SessionSender(outbox: outbox, effects: effects, timing: deliveryTimingForTests ?? SessionSender.Timing())
        let work = Task.detached(priority: .userInitiated) {
            forking ? await sender.forkAndSend(prompt, from: id) : await sender.send(prompt, to: id)
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
            return .notSent(Self.cantSendNow)
        case .notSent(let why):
            Log.app.error("Couldn't send a prompt to a session in the Copilot app: \(why.kind, privacy: .public)")
            guard goesOn else { return .notSent(Self.cantSendNow) }
            return await fallBack(prompt, in: id, forking: forking, reason: why.description, mayHaveSent: why.mayHaveGone, handOff: handOff)
        case .forkedNotSent(let fork, let why):
            Log.app.error("Forked a session in the Copilot app, but couldn't send the fork a prompt: \(why.kind, privacy: .public)")
            guard goesOn else { return .notSent(Self.cantSendNow) }
            return await fallBack(
                prompt, in: fork, forking: forking, fork: fork, reason: why.description, mayHaveSent: why.mayHaveGone, handOff: handOff
            )
        }
    }

    /// Copies what to paste, and shows the session to paste it in: the prompt, or, to fork a session that hasn't forked,
    /// `/fork <prompt>`. Hands it off once the session shows. Nothing's copied or shown once it's stopped, as when its
    /// window closed, or once Send Work to Copilot is off, as looked at right before.
    private func fallBack(
        _ prompt: String, in session: String, forking: Bool, fork: String? = nil, reason: String, foreseen: Bool = false,
        mayHaveSent: Bool = false, handOff: CommentHandOff?
    ) async -> SessionDelivery {
        let way: Showing?
        if openForTests != nil {
            way = await cliHolder(of: session).map(Showing.terminal) ?? .app
        } else {
            way = await showing(session)
        }
        guard !Task.isCancelled else { return .notSent(SendFailure.cancelled.description) }
        // A fallback that the window said it would do goes on whether or not Send Prompts to Copilot Sessions is on; one
        // from a send that BriefBar tried, only while it is.
        guard canSend, isOn, !hasStopped, foreseen || sessionPromptsAreOn else { return .notSent(Self.cantSendNow) }
        guard let way else {
            Log.app.error("Couldn't open a session in the Copilot app")
            return .notSent(Self.cantOpenInApp)
        }
        let place: SessionFallback.Place
        if case .terminal = way { place = .terminal } else { place = .app }
        // The app's own /fork takes a prompt, and sends it to the fork; the CLI's takes a name for the fork, so in its
        // terminal you fork the session first, then paste the prompt.
        let forksHere = forking && fork == nil
        let pastesFork = forksHere && place == .app
        guard copyAndShow(pastesFork ? "/fork \(prompt)" : prompt, in: session, way) else {
            if case .terminal = way {
                Log.app.error("Couldn't bring up the terminal of the Copilot CLI that has a session open")
                return .notSent(forksHere ? Self.cantBringUpToFork : Self.cantBringUp)
            }
            Log.app.error("Couldn't open a session in the Copilot app")
            return .notSent(Self.cantOpenInApp)
        }
        Log.app.info("Copied a prompt for a session in the Copilot app, and showed the session")
        if let handOff { handedOff(handOff, prompt) }
        return .fellBack(SessionFallback(
            reason: reason, wasForeseen: foreseen, pastesFork: pastesFork, forksFirst: forksHere && place == .terminal,
            mayHaveSent: mayHaveSent, place: place, session: session, fork: fork
        ))
    }

    /// Puts the text on the clipboard, and shows the session the way it found it shows (`showing`): false when it didn't.
    private func copyAndShow(_ text: String, in id: String, _ way: Showing) -> Bool {
        if let openForTests { return openForTests(id, text) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
    private func sessionHomes() async -> [URL] {
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
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }
}
