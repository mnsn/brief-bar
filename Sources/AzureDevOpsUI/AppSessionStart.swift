import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

/// Why a work item's new session can't start in the Copilot app, as things stand (`CopilotTasksStore.appStart(in:)`):
/// what the composer says under its choices, and what has Send with … open the composer instead.
enum AppStartProblem: Error, Equatable, CustomStringConvertible {
    /// Send Prompts to Copilot Sessions is off, so no session of the app's runs BriefBar's extension.
    case off
    /// Nothing on this Mac opens the app's sessions.
    case noApp
    /// The app has no project for the repository, as a repository: the repository's folder's name.
    case noProject(String)
    /// None of the app's sessions can start one: none runs BriefBar's extension as it is now, and none that nothing has open
    /// is there to load, with it.
    case noHost
    /// The app's database can't be read.
    case unreadable

    var description: String {
        switch self {
        case .off:
            return "To start sessions in the Copilot app, turn on \(CopilotSessionPrompts.title) in Settings › Agents."
        case .noApp:
            return CopilotTasksStore.cantOpenInApp
        case .noProject(let name):
            return "The Copilot app doesn't have \(name) as a repository. Add it there to start sessions in it, or run it with the CLI."
        case .noHost:
            return "BriefBar starts a session in the Copilot app from another of its sessions, and none can now. Restart one in the app, or run it with the CLI."
        case .unreadable:
            return "BriefBar couldn't read the Copilot app's projects, so it can't start a session there now."
        }
    }
}

/// Where a work item's new session would start in the Copilot app: the app's project for its repository, and the session
/// whose BriefBar extension starts it, which listens already, or loads as BriefBar opens it.
struct AppStartPlan: Equatable {
    var project: AppSessions.Project
    var host: String
    var hostListens: Bool
}

/// What became of a new session in the Copilot app (`CopilotTasksStore.startInApp`).
enum AppStart: Equatable {
    /// It started, with the prompt as its first message, and shows in the app: its ID.
    case started(String)
    /// Nothing started: why.
    case notStarted(String)
    /// BriefBar can't tell whether it started, or which session it is: why, and to look in the app before you send it
    /// again.
    case mayHaveStarted(String)
}

extension CopilotTasksStore {
    /// Whether a work item's new session starts in the Copilot app unless you choose otherwise: as Settings say, while Send
    /// Prompts to Copilot Sessions is on and the app is on this Mac.
    var startsInApp: Bool {
        settings.copilotNewSessionsInApp && sessionPromptsAreOn && canOpenInApp
    }

    /// Where a new session in the repository would start in the Copilot app, or why it can't, as the app's database and
    /// BriefBar's outbox say now (`AppStartPlan`): read off the main thread, and nothing while Send Work to Copilot or Send
    /// Prompts to Copilot Sessions is off, or in the demo. The session it starts from is one of the app's, never a CLI's,
    /// which has no `create_session`: one the app has open, whose extension runs and can start one, the newest in the same
    /// project first; else one that nothing has open, which loads with the extension as it is now, as opening it in the app
    /// does.
    func appStart(in repository: URL) async -> Result<AppStartPlan, AppStartProblem> {
        guard canSend, isOn, !hasStopped else { return .failure(.off) }
        guard sessionPromptsAreOn else { return .failure(.off) }
        guard canOpenInApp else { return .failure(.noApp) }
        let outbox = outbox
        let appHome = appHome
        let homes = await sessionHomes()
        typealias Found = (project: AppSessions.Project, listening: [(id: String, holder: pid_t?)], unheld: String?)
        let found = await Task.detached(priority: .userInitiated) { () -> Result<Found, AppStartProblem> in
            let project: AppSessions.Project?
            let sessions: [AppSession]
            do {
                project = try AppSessions.project(for: repository, home: appHome)
                sessions = try AppSessions.load(home: appHome)
            } catch {
                return .failure(.unreadable)
            }
            guard let project else { return .failure(.noProject(repository.lastPathComponent)) }
            // The newest first, as the app's sessions load; those in the same project before the others.
            let ranked = sessions.filter { $0.projectId == project.id } + sessions.filter { $0.projectId != project.id }
            let live = Set(outbox.listeners().filter { $0.kinds.contains(.create) && CopilotOutbox.isLive($0) }.map(\.sessionId))
            let listening = ranked.filter { live.contains($0.id) }.map { session in
                (id: session.id, holder: homes.lazy.compactMap { AppSessions.holder(of: session.id, home: $0) }.first)
            }
            let unheld = ranked.first { session in !homes.contains { AppSessions.isOpen(session.id, home: $0) } }
            return .success((project, listening, unheld?.id))
        }.value
        switch found {
        case .failure(let problem):
            return .failure(problem)
        case .success(let found):
            if let host = found.listening.first(where: { $0.holder.map(holdsInApp) == true }) {
                return .success(AppStartPlan(project: found.project, host: host.id, hostListens: true))
            }
            if let host = found.unheld {
                return .success(AppStartPlan(project: found.project, host: host, hostListens: false))
            }
            return .failure(.noHost)
        }
    }

    /// Starts a new session of the Copilot app's for the subject, with the prompt as its first message, in autopilot, as the
    /// CLI's tasks run, with the model and the effort you chose: in a worktree of its own, of the app's project for the
    /// repository, through BriefBar's extension in another of the app's sessions (`appStart(in:)`, `SessionSender.create`).
    /// Then it shows in the app, where you can follow and steer it. Only while Send Work to Copilot and Send Prompts to
    /// Copilot Sessions are on, never in the demo. The repository is the one the subject's next work goes in, as a task's
    /// is.
    func startInApp(_ subject: TaskSubject, prompt: String, options: CopilotRunOptions, repository: URL) async -> AppStart {
        guard canSend, isOn, !hasStopped else { return .notStarted(Self.cantSendNow) }
        let key = Self.startKey(subject)
        guard !startingInApp.contains(key) else { return .notStarted(Self.startingAlready) }
        startingInApp.insert(key)
        defer { startingInApp.remove(key) }
        let plan: AppStartPlan
        switch await appStart(in: repository) {
        case .success(let found): plan = found
        case .failure(let problem): return .notStarted(problem.description)
        }
        // Again, after that read: it may have been turned off meanwhile.
        guard maySendToSessions else { return .notStarted(Self.cantSendNow) }
        switch subject {
        case .workItem(let item): settings.copilotRepositories[item.reference.projectKey] = repository.path
        case .pullRequest(let pullRequest, _): settings.copilotRepositories[pullRequest.reference.repositoryKey] = repository.path
        }
        let session = NewSession(
            projectId: plan.project.id, name: NewSession.name(Self.sessionName(for: subject)), mode: .autopilot,
            model: options.model, effort: options.effort
        )
        let homes = await sessionHomes()
        let appHome = appHome
        let effects = SessionSender.Effects(
            open: { [weak self] id in
                await MainActor.run {
                    // Stopped, or turned off, while this waited for its turn: nothing opens.
                    guard !Task.isCancelled, let self, self.maySendToSessions else { return false }
                    return self.load(id)
                }
            },
            isHeld: { id in homes.contains { AppSessions.isOpen(id, home: $0) } },
            forkRecord: { id in AppSessions.forkRecord(of: id, home: appHome) },
            started: { project, since in AppSessions.started(inProject: project, since: since, home: appHome) },
            mayGoOn: { [weak self] in await MainActor.run { self?.maySendToSessions ?? false } }
        )
        let sender = SessionSender(outbox: outbox, effects: effects, timing: deliveryTimingForTests ?? SessionSender.Timing())
        // What a test notes (`ThisMac.noting`) goes with the sender into its own task, which may load the session it starts
        // from there.
        let notes = ThisMac.noting
        let host = plan.host
        let work = Task.detached(priority: .userInitiated) {
            await ThisMac.$noting.withValue(notes) { await sender.create(prompt, session, from: host) }
        }
        // Stopped, as when its window closes: a request that no extension took yet is taken back.
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        switch outcome {
        case .started(let id):
            Log.app.info("Started a session in the Copilot app")
            if maySendToSessions, !Task.isCancelled { _ = await show(id) }
            return .started(id)
        case .notStarted(.cancelled):
            return .notStarted(SendFailure.cancelled.description)
        case .notStarted(.turnedOff):
            return .notStarted(Self.cantSendNow)
        case .notStarted(let why):
            Log.app.error("Couldn't start a session in the Copilot app: \(why.kind, privacy: .public)")
            guard why.mayHaveGone else { return .notStarted(why.description) }
            return .mayHaveStarted(Self.mayHaveStarted(why))
        }
    }

    /// Why BriefBar can't tell whether a new session started in the Copilot app, and to look there first.
    static func mayHaveStarted(_ why: SendFailure) -> String {
        var reason = why.description
        if let last = reason.last, !".!?".contains(last) { reason += "." }
        return "\(reason) It may have started all the same: look in the Copilot app before you send it again."
    }

    static let startingAlready = "BriefBar is starting a session for it in the Copilot app already."

    /// Whether BriefBar starts a new session in the Copilot app for the subject now.
    func isStartingInApp(_ subject: TaskSubject) -> Bool {
        startingInApp.contains(Self.startKey(subject))
    }

    /// What a new session in the Copilot app is for, whatever case its organization is written in: one at a time, each.
    static func startKey(_ subject: TaskSubject) -> String {
        switch subject {
        case .workItem(let item): return "workItem:\(item.organization.lowercased())/\(item.id)"
        case .pullRequest(let pullRequest, _): return "pullRequest:\(pullRequest.organization.lowercased())/\(pullRequest.id)"
        }
    }

    /// A new session's name: the subject's, as a task's session is named (`CopilotCommand.sessionName`).
    static func sessionName(for subject: TaskSubject) -> String {
        switch subject {
        case .workItem(let item): return CopilotCommand.sessionName(for: item)
        case .pullRequest(let pullRequest, let action): return CopilotCommand.sessionName(for: pullRequest, action: action)
        }
    }
}
