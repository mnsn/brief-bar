import CopilotCore
import Foundation

/// How a prompt stands that BriefBar sent to a session it doesn't run itself, such as one of the Copilot app's, through
/// BriefBar's extension in it, or copied for you to paste there: from the session's log since the prompt was sent, and
/// whether a turn runs in it now. Only what the log says from then on counts: before, it's the session's own history.
public struct SessionTurn: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nothing in its log since it was sent: the session hasn't taken it up yet, or you haven't pasted it.
        case waiting
        /// A turn runs in it, at this step when the log says.
        case working(step: String?)
        /// It asks you something, or waits for your permission or your approval of its plan, in the app.
        case needsYou
        /// Its turn ended, saying this when it said something.
        case finished(summary: String?)
        case failed(String?)
        /// Its turn was interrupted, or cut off.
        case stopped
    }

    public var phase: Phase
    /// Since when it stands so.
    public var since: Date?

    public init(phase: Phase, since: Date?) {
        self.phase = phase
        self.since = since
    }

    /// Its turn is over: finished, failed or stopped.
    public var isOver: Bool {
        switch phase {
        case .finished, .failed, .stopped: true
        case .waiting, .working, .needsYou: false
        }
    }

    /// How a prompt sent at `sentAt` stands, as the session's log says, and the app or the CLI that has it open.
    /// - Parameters:
    ///   - isRunning: the Copilot app says a turn runs in the session now.
    ///   - isOpen: something has the session open (`AppSessions.isOpen`): a turn its log says runs isn't cut off.
    public static func of(sentAt: Date, log: SessionLogState?, isRunning: Bool, isOpen: Bool) -> SessionTurn {
        guard let log, let last = log.lastEventAt, last >= sentAt else { return SessionTurn(phase: .waiting, since: sentAt) }
        let started = log.phaseSince.map { max($0, sentAt) } ?? sentAt
        switch log.activity {
        case .needsAnswer, .needsPermission, .needsPlanApproval:
            return SessionTurn(phase: .needsYou, since: started)
        default:
            break
        }
        if isRunning || (log.phase == .running && isOpen) {
            return SessionTurn(phase: .working(step: log.phase == .running ? log.currentStep : nil), since: started)
        }
        // A phase from before it was sent is the session's history: nothing has happened since.
        guard let setAt = log.phaseSetAt, setAt >= sentAt else { return SessionTurn(phase: .waiting, since: sentAt) }
        switch log.phase {
        case .finished: return SessionTurn(phase: .finished(summary: log.summary), since: setAt)
        case .failed: return SessionTurn(phase: .failed(log.errorMessage), since: setAt)
        case .interrupted: return SessionTurn(phase: .stopped, since: setAt)
        // A turn the log says runs, though nothing runs it or has the session open, was cut off when it last wrote.
        case .running: return SessionTurn(phase: .stopped, since: last)
        case .unknown: return SessionTurn(phase: .waiting, since: sentAt)
        }
    }
}
