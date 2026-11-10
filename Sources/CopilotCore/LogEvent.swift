import Foundation

/// The subset of a Copilot session `events.jsonl` line that matters for status tracking.
public struct LogEvent: Sendable, Equatable {
    public var timestamp: Date?
    public var kind: Kind

    public init(timestamp: Date?, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case userMessage
        case turnStart(isSubagent: Bool)
        case turnEnd(isSubagent: Bool)
        case assistantMessage(isSubagent: Bool, hasToolRequests: Bool)
        case toolStart(ToolStart)
        case toolComplete(callId: String)
        /// A shell command BriefBar's check of a Push & Reply task's pushes stopped (`PushStop`): its call, which it ends,
        /// and why.
        case pushStopped(callId: String, reason: String)
        case permissionRequested(PermissionRequest)
        case permissionCompleted(requestId: String)
        /// `hook.start` with `hookType == "agentStop"`: the agent finished its interaction.
        case agentStop(isSubagent: Bool)
        case abort(reason: String?)
        case sessionError(errorType: String?, message: String?)
        case sessionStart
        /// A resume that abandoned what the previous CLI process left pending. A resume that keeps
        /// that work waiting, or joins a turn another client is running, is `.other`.
        case sessionResume
        case sessionShutdown
        case taskComplete(summary: String?, success: Bool?)
        case other
    }

    public struct ToolStart: Sendable, Equatable {
        public var callId: String
        public var name: String
        public var isSubagent: Bool
        public var title: String?
        /// Free-text description argument some tools take (e.g. `bash`).
        public var description: String?
        /// `ask_user` question and choices.
        public var question: String?
        public var choices: [String]
        /// `exit_plan_mode` summary.
        public var planSummary: String?
        /// `relay_session_input`: the session whose question it asks you, by its session or workspace ID.
        public var relayedSession: String?
        /// `relay_session_input`: what it says before the question, which it doesn't repeat.
        public var relayContext: String?

        public init(
            callId: String, name: String, isSubagent: Bool = false, title: String? = nil,
            description: String? = nil, question: String? = nil, choices: [String] = [],
            planSummary: String? = nil, relayedSession: String? = nil, relayContext: String? = nil
        ) {
            self.callId = callId
            self.name = name
            self.isSubagent = isSubagent
            self.title = title
            self.description = description
            self.question = question
            self.choices = choices
            self.planSummary = planSummary
            self.relayedSession = relayedSession
            self.relayContext = relayContext
        }
    }

    public struct PermissionRequest: Sendable, Equatable {
        public var requestId: String
        public var kind: String?
        public var detail: String?

        public init(requestId: String, kind: String? = nil, detail: String? = nil) {
            self.requestId = requestId
            self.kind = kind
            self.detail = detail
        }
    }
}

/// A push that BriefBar's check stopped as Copilot made it, in one of BriefBar's Push & Reply tasks: the CLI denied the
/// shell command, as its `preToolUse` hook said, with BriefBar's reason, which its log keeps after "Denied by preToolUse
/// hook: " (CopilotTasks' `PushGuard`). Why, and when.
public struct PushStop: Sendable, Equatable {
    /// What the reason for a stop starts with, where the log finds it.
    public static let marker = "BriefBar stopped this push: "
    /// What it ends with, which tells Copilot what to do then: the task has failed, whatever it does next.
    public static let ending = " Don't push again, in any way: stop, and say why in your summary."

    /// Why, without the marker or the ending.
    public var reason: String
    public var at: Date?

    public init(reason: String, at: Date?) {
        self.reason = reason
        self.at = at
    }

    /// The reason a denied call's message gives after the marker, without the ending; nil when it has no marker.
    public static func reason(in message: String) -> String? {
        guard let start = message.range(of: marker) else { return nil }
        var reason = message[start.upperBound...]
        if let end = reason.range(of: ending.trimmingCharacters(in: .whitespaces), options: .backwards) {
            reason = reason[..<end.lowerBound]
        }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension LogEvent.Kind {
    /// Events from which a session's state can be rebuilt without older history.
    var isAnchor: Bool {
        switch self {
        case .userMessage, .sessionStart: return true
        default: return false
        }
    }
}
