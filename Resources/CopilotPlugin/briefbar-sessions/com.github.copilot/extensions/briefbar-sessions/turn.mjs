// How the turn of one message BriefBar's extension sent its session stands, from the session's events, for the
// extension to report to BriefBar when it asks (./outbox.mjs): whether the session has taken the message up, the step
// it's at, whether it waits on you, and how it ended, with what Copilot said. It reads only the Copilot SDK's
// documented session events, and never a message's own text: a `user.message`'s is never read.
//
// The turn starts with its own `user.message`, takes in the steering messages that join it, the runs autopilot goes on
// with and the runs that the background work it started wakes up, and ends at the first of: autopilot stopping it
// (`session.autopilot_stopped`); the session going idle (`session.idle`, which no run in between brings, autopilot's
// included); the next run starting, with another message (no idle comes between runs that waited in the queue); an
// error for it; or the session shutting down, as when the app closes it, since a resumed session doesn't go on with it.
// docs/how-it-works.md says so under "Its extension for the app's sessions".

/** The most a report says of what Copilot said, in characters. */
export const LONGEST_SAID = 4000;
/** The longest step, or error, a report says, on one line. */
export const LONGEST_LINE = 200;
/** How a turn stands, from sent to over. */
export const STATES = Object.freeze(["waiting", "working", "needsYou", "finished", "failed", "stopped"]);
const OVER = new Set(["finished", "failed", "stopped"]);
// The tools Copilot asks or reports with, which aren't steps of its work.
const OWN_TOOLS = new Set(["ask_user", "exit_plan_mode", "report_intent", "task_complete"]);
// What waits on you, by the event that asks, and what it asks for.
const ASKS = Object.freeze({
    "user_input.requested": "question",
    "exit_plan_mode.requested": "plan",
    "elicitation.requested": "input",
    "auto_mode_switch.requested": "input",
    "permission.requested": "permission",
});
const ANSWERED = new Set([
    "user_input.completed",
    "exit_plan_mode.completed",
    "elicitation.completed",
    "auto_mode_switch.completed",
    "permission.completed",
]);

/**
 * Follows the turn of a message sent to the session, from the events the session sends from before it's sent: until its
 * ID is known (`begin`), they wait, so that none of its own is missed. `observe` and `begin` say what changed: "none",
 * "step" when only the step it's at did, or "state" for anything else. `report` is how it stands; `isOver` once it ended,
 * after which nothing changes it.
 * @param {{ sentAt?: string }} options when it was sent, which it stands so since until the session takes it up.
 */
export function followTurn({ sentAt = new Date().toISOString() } = {}) {
    let messageId = null;
    // The messages whose run this is: the one sent, and the steering ones that joined its run.
    const ours = new Set();
    const waiting = [];
    let started = false;
    let state = "waiting";
    let since = sentAt;
    let workingSince = sentAt;
    let step;
    // What waits on you now, by its request's ID, in the order asked, with when each was.
    const asking = new Map();
    // The last of its run's own messages with text; autopilot's summary of it, once it said it's done.
    let words;
    let summary;
    // An error the runtime may go on after, as when it offers to switch models.
    let failure;
    // Whether the main agent's loop last went idle because it was stopped, and why it was, when it wasn't someone's Stop.
    let abortedLast = false;
    let abortCause;
    let said;
    let cause;

    const isOver = () => OVER.has(state);

    function report() {
        const value = { state, since };
        if (state === "working" && step) value.step = step;
        if (state === "needsYou") {
            const latest = [...asking.values()].at(-1);
            if (latest) value.asks = latest.asks;
            if (latest?.said) value.said = latest.said;
        }
        if (isOver()) {
            if (said) value.said = said;
            if (cause) value.cause = cause;
        }
        return value;
    }

    function begin(id) {
        if (messageId !== null || typeof id !== "string" || id === "") return "none";
        messageId = id;
        ours.add(id);
        let change = "none";
        for (const event of waiting.splice(0)) change = larger(change, apply(event));
        return change;
    }

    function observe(event) {
        if (isOver()) return "none";
        if (messageId === null) {
            waiting.push(event);
            return "none";
        }
        return apply(event);
    }

    function apply(event) {
        if (isOver() || event === null || typeof event !== "object") return "none";
        // A subagent's: only the main agent's own events say how the turn goes, as `sendAndWait` reads them.
        if (event.agentId) return "none";
        const data = event.data !== null && typeof event.data === "object" ? event.data : {};
        const at = typeof event.timestamp === "string" ? event.timestamp : new Date().toISOString();
        switch (event.type) {
            case "user.message":
                return userMessage(data, at);
            case "assistant.message":
                return assistantMessage(data, at);
            case "tool.execution_start":
                return toolStarted(data);
            case "session.task_complete":
                if (started && data.success !== false) summary = text(data.summary) ?? summary;
                return "none";
            case "assistant.idle":
                if (started) abortedLast = data.aborted === true;
                return "none";
            case "abort":
                if (started) abortCause = data.reason === "autopilot_credit_limit" ? "creditLimit" : undefined;
                return "none";
            case "session.idle":
                if (!started) return "none";
                return data.aborted === true ? end("stopped", at, abortCause) : end(failure ? "failed" : "finished", at);
            case "session.autopilot_stopped":
                // Its own request's, or one it doesn't say, while it runs: autopilot stops one run's at a time.
                if (!started || (typeof data.requestId === "string" && data.requestId !== messageId)) return "none";
                if (data.reason === "aborted") return end("stopped", at, abortCause);
                return end(data.reason === "error" || failure ? "failed" : "finished", at);
            case "session.error":
                return errored(data, at);
            case "session.warning":
                if (data.warningType !== "policy_blocked" || !ours.has(data.originatingMessageId)) return "none";
                failure = line(data.message);
                return end("failed", at);
            case "session.shutdown":
                // The app closed the session, or its runtime stopped: a resumed session doesn't go on with the turn.
                return end("stopped", at, "closed");
            default:
                if (Object.hasOwn(ASKS, event.type)) return asked(event.type, data, at);
                if (ANSWERED.has(event.type)) return answered(data);
                return "none";
        }
    }

    function userMessage(data, at) {
        if (data.messageId === messageId) return start(at);
        if (!started || typeof data.messageId !== "string") return "none";
        // You, or another program, steered the turn: it joined it.
        if (data.delivery === "steering") {
            ours.add(data.messageId);
            return "none";
        }
        if (data.isAutopilotContinuation === true) return "none";
        // The next run started: this one is over.
        if (data.delivery === "queued" || data.delivery === "idle") {
            return abortedLast ? end("stopped", at, abortCause) : end(failure ? "failed" : "finished", at);
        }
        return "none";
    }

    function assistantMessage(data, at) {
        // A subagent's, as runtimes before `agentId` said.
        if (data.parentToolCallId) return "none";
        let change = "none";
        if (!started && data.originatingMessageId === messageId) change = start(at);
        if (started && ours.has(data.originatingMessageId)) {
            const written = text(data.content);
            if (written) {
                words = written;
                // It went on after an error it could go on from.
                failure = undefined;
            }
        }
        return change;
    }

    function start(at) {
        if (started) return "none";
        started = true;
        workingSince = at;
        return enter("working", at);
    }

    function toolStarted(data) {
        if (!started || state !== "working" || data.parentToolCallId || OWN_TOOLS.has(data.toolName)) return "none";
        const next = line(data.arguments?.description) ?? line(data.toolTitle);
        if (!next || next === step) return "none";
        step = next;
        return "step";
    }

    function errored(data, at) {
        const origin = data.originatingMessageId;
        // One for a request of its own, even before its run started; one for the session, only while it runs.
        if (origin ? !ours.has(origin) : !started) return "none";
        failure = line(data.message) ?? failure;
        // The runtime offers to switch models, and may go on.
        if (data.eligibleForAutoSwitch === true) return "none";
        return end("failed", at);
    }

    function asked(type, data, at) {
        if (!started || typeof data.requestId !== "string") return "none";
        // Settled by a hook: nothing waits on you.
        if (type === "permission.requested" && data.resolvedByHook === true) return "none";
        const asks = ASKS[type];
        const what = type === "user_input.requested" ? data.question : type === "exit_plan_mode.requested" ? data.summary : data.message;
        asking.delete(data.requestId);
        asking.set(data.requestId, { asks, said: text(what), at });
        // Once you answer, it isn't at the step it was at before it asked.
        step = undefined;
        state = "needsYou";
        since = at;
        return "state";
    }

    function answered(data) {
        if (!asking.delete(data.requestId) || state !== "needsYou") return "none";
        // Another still waits on you, which it says since it was asked: BriefBar notifies of each by that.
        const latest = [...asking.values()].at(-1);
        if (latest) {
            since = latest.at;
            return "state";
        }
        return enter("working", workingSince);
    }

    function enter(next, at) {
        if (state === next) return "none";
        state = next;
        since = at;
        return "state";
    }

    function end(how, at, why) {
        asking.clear();
        step = undefined;
        if (how === "finished") said = summary ?? words;
        if (how === "failed") said = failure;
        cause = how === "stopped" ? why : undefined;
        state = how;
        since = at;
        waiting.length = 0;
        return "state";
    }

    return {
        begin,
        observe,
        get report() {
            return report();
        },
        get isOver() {
            return isOver();
        },
        get messageId() {
            return messageId;
        },
    };
}

function larger(a, b) {
    if (a === "state" || b === "state") return "state";
    return a === "step" || b === "step" ? "step" : "none";
}

/** Text as Copilot wrote it, its lines kept, without other control characters, cut short when it's long; undefined for
 * none. */
export function text(value) {
    if (typeof value !== "string") return undefined;
    const kept = value.replace(/\r\n?/g, "\n").replace(/[^\P{Cc}\n\t]|\p{Cf}/gu, "").trim();
    if (kept === "") return undefined;
    return kept.length > LONGEST_SAID ? `${kept.slice(0, LONGEST_SAID - 1).trimEnd()}…` : kept;
}

/** A line of text, without control characters, its spaces collapsed, cut short when it's long; undefined for none. */
export function line(value) {
    if (typeof value !== "string") return undefined;
    const kept = value.replace(/[\p{Cc}\p{Cf}]+/gu, " ").replace(/\s+/g, " ").trim();
    if (kept === "") return undefined;
    return kept.length > LONGEST_LINE ? `${kept.slice(0, LONGEST_LINE - 1)}…` : kept;
}
