// How BriefBar's extension follows the turn of a message it sent its session (Resources/CopilotPlugin/briefbar-sessions,
// turn.mjs): from the events the Copilot runtime sent when we tried each case in a session of the app (runtime 1.0.102),
// with their data cut to what it reads. `make plugin-test` runs it.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { describe, test } from "node:test";
import {
    LONGEST_LINE,
    LONGEST_SAID,
    STATES,
    followTurn,
    line,
    text,
} from "../../Resources/CopilotPlugin/briefbar-sessions/com.github.copilot/extensions/briefbar-sessions/turn.mjs";

const SENT = Date.parse("2026-11-10T06:42:33.000Z");
const PROMPT = "Fix the comments on !4102. PROMPT-MARKER-7f3e";
const at = (seconds) => new Date(SENT + seconds * 1000).toISOString();

/** An event as the session sends it, `seconds` after the message was sent. */
function event(seconds, type, data = {}, envelope = {}) {
    return { id: randomUUID(), timestamp: at(seconds), parentId: null, type, data, ...envelope };
}

/** A turn of message "m1", sent at 0 s and begun. */
function sent() {
    const turn = followTurn({ sentAt: at(0) });
    assert.equal(turn.begin("m1"), "none");
    return turn;
}

/** What the turn says changed for each event, in order. */
function observe(turn, events) {
    return events.map((each) => turn.observe(each));
}

const started = (seconds = 1, delivery = "idle") =>
    event(seconds, "user.message", { messageId: "m1", delivery, content: PROMPT, agentMode: "interactive" });
const said = (seconds, content, origin = "m1", more = {}) =>
    event(seconds, "assistant.message", { messageId: randomUUID(), originatingMessageId: origin, content, ...more });
const tool = (seconds, toolName, more = {}) =>
    event(seconds, "tool.execution_start", { toolCallId: randomUUID(), toolName, ...more });

describe("a turn", () => {
    test("stands waiting until the session takes its message up, then works, then finishes with its last words", () => {
        const turn = followTurn({ sentAt: at(0) });
        assert.deepEqual(turn.report, { state: "waiting", since: at(0) });
        assert.equal(turn.begin("m1"), "none");
        assert.equal(turn.messageId, "m1");
        assert.deepEqual(observe(turn, [
            started(1),
            event(1, "assistant.turn_start", { turnId: "0" }),
            // A tool call: no words.
            said(2, ""),
            tool(2, "bash", { arguments: { command: "make test", description: "Run the tests" }, toolTitle: "Run make test" }),
        ]), ["state", "none", "none", "step"]);
        assert.deepEqual(turn.report, { state: "working", since: at(1), step: "Run the tests" });
        assert.deepEqual(observe(turn, [
            said(5, "Fixed the backoff.\n\nIt isn't pushed."),
            event(5, "assistant.turn_end", { turnId: "0" }),
            event(5, "assistant.idle", {}),
        ]), ["none", "none", "none"]);
        assert.equal(turn.isOver, false);
        assert.equal(turn.observe(event(6, "session.idle", { mode: "interactive" })), "state");
        assert.equal(turn.isOver, true);
        assert.deepEqual(turn.report, { state: "finished", since: at(6), said: "Fixed the backoff.\n\nIt isn't pushed." });
        // Over: nothing changes it anymore.
        assert.deepEqual(observe(turn, [said(7, "Later words"), event(8, "session.idle", {})]), ["none", "none"]);
        assert.equal(turn.report.said, "Fixed the backoff.\n\nIt isn't pushed.");
    });

    test("hears the events that came before its message's ID was known", () => {
        const turn = followTurn({ sentAt: at(0) });
        assert.deepEqual(observe(turn, [started(1), said(2, "Done."), event(3, "session.idle", {})]), ["none", "none", "none"]);
        assert.equal(turn.report.state, "waiting");
        assert.equal(turn.begin("m1"), "state");
        assert.deepEqual(turn.report, { state: "finished", since: at(3), said: "Done." });
        // Only once.
        assert.equal(turn.begin("m2"), "none");
        assert.equal(turn.messageId, "m1");
    });

    test("leaves the run it waits behind alone, and ends when the next one starts: no idle comes between them", () => {
        const turn = sent();
        assert.deepEqual(observe(turn, [
            said(1, "The run before.", "m0"),
            tool(1, "view", { toolTitle: "Read CopilotWork.swift" }),
            event(2, "assistant.idle", {}),
            event(2, "pending_messages.modified", {}),
            started(2, "queued"),
            said(3, "Mine."),
            event(4, "assistant.idle", {}),
            event(4, "user.message", { messageId: "m2", delivery: "queued" }),
        ]), ["none", "none", "none", "none", "state", "none", "none", "state"]);
        assert.deepEqual(turn.report, { state: "finished", since: at(4), said: "Mine." });
        assert.equal(turn.observe(said(5, "The next run's.", "m2")), "none");
    });

    test("takes in a message that steers it, and ends with the session idle", () => {
        const turn = sent();
        assert.deepEqual(observe(turn, [
            started(1),
            said(2, "Looking."),
            event(3, "user.message", { messageId: "s1", delivery: "steering" }),
            said(4, "Steered, and done.", "s1"),
            event(5, "session.idle", { mode: "interactive" }),
        ]), ["state", "none", "none", "none", "state"]);
        assert.deepEqual(turn.report, { state: "finished", since: at(5), said: "Steered, and done." });
    });

    test("goes on through the run that background work it started wakes, and takes none of its tool calls' words", () => {
        const turn = sent();
        observe(turn, [
            started(1),
            tool(2, "bash", { arguments: { command: "sleep 30", description: "Wait 30 seconds", mode: "async" } }),
            said(3, "It's running in the background."),
            event(3, "assistant.idle", {}),
            event(33, "system.notification", { content: "<system_notification>Shell finished</system_notification>" }),
        ]);
        assert.equal(turn.report.state, "working");
        assert.deepEqual(observe(turn, [
            // The wake-up's own call reads the shell: no message of the turn's.
            event(34, "assistant.message", { messageId: randomUUID(), content: "", toolRequests: [{ name: "read_bash" }] }),
            event(34, "assistant.message", { messageId: randomUUID(), content: "Not ours." }),
            said(35, "The sleep finished."),
            event(35, "assistant.idle", {}),
            event(35, "session.idle", { mode: "interactive" }),
        ]), ["none", "none", "none", "none", "state"]);
        assert.deepEqual(turn.report, { state: "finished", since: at(35), said: "The sleep finished." });
    });

    test("still finishes when a Stop came after its answer, as background work it started went on", () => {
        const turn = sent();
        observe(turn, [
            started(1),
            said(2, "Waiting for the shell."),
            event(3, "assistant.idle", {}),
            event(7, "abort", { reason: "user_initiated" }),
            event(7, "assistant.idle", { aborted: true }),
            event(32, "system.notification", { content: "<system_notification>Shell finished</system_notification>" }),
            said(33, "Done waiting."),
            event(34, "assistant.idle", {}),
            event(34, "session.idle", { mode: "interactive" }),
        ]);
        assert.deepEqual(turn.report, { state: "finished", since: at(34), said: "Done waiting." });
    });

    test("stops at a Stop, saying nothing of its words, and no cause: it was yours", () => {
        const turn = sent();
        observe(turn, [
            started(1),
            said(2, "Half of it."),
            event(3, "abort", { reason: "user_initiated" }),
            event(3, "assistant.idle", { aborted: true }),
        ]);
        assert.equal(turn.observe(event(3, "session.idle", { aborted: true, mode: "interactive" })), "state");
        assert.deepEqual(turn.report, { state: "stopped", since: at(3) });
    });

    test("stops at a Stop that the next run's start ends", () => {
        const turn = sent();
        observe(turn, [
            started(1),
            event(3, "abort", { reason: "user_initiated" }),
            event(3, "assistant.idle", { aborted: true }),
            event(3, "user.message", { messageId: "m2", delivery: "queued" }),
        ]);
        assert.deepEqual(turn.report, { state: "stopped", since: at(3) });
    });

    test("stops, and says why, when the session closes: a resumed session doesn't go on with it", () => {
        const working = sent();
        observe(working, [started(1), said(2, "Halfway."), event(9, "session.shutdown", { shutdownType: "routine" })]);
        assert.deepEqual(working.report, { state: "stopped", since: at(9), cause: "closed" });
        // Still in the queue too.
        const waiting = sent();
        assert.equal(waiting.observe(event(9, "session.shutdown", { shutdownType: "routine" })), "state");
        assert.deepEqual(waiting.report, { state: "stopped", since: at(9), cause: "closed" });
    });
});

describe("waiting on you", () => {
    test("while Copilot asks a question, with the question, then works again once you answer", () => {
        const turn = sent();
        observe(turn, [started(1), tool(2, "bash", { arguments: { description: "Read the diff" } })]);
        assert.deepEqual(observe(turn, [
            tool(3, "ask_user", { arguments: { question: "Which branch?" } }),
            event(3, "user_input.requested", { requestId: "q1", question: "Which branch?", choices: ["main"], toolCallId: "t1" }, { ephemeral: true }),
        ]), ["none", "state"]);
        assert.deepEqual(turn.report, { state: "needsYou", since: at(3), asks: "question", said: "Which branch?" });
        assert.equal(turn.observe(event(40, "user_input.completed", { requestId: "q1", answer: "main" }, { ephemeral: true })), "state");
        // Working since it started, at no step until its next: the one before it asked is done.
        assert.deepEqual(turn.report, { state: "working", since: at(1) });
        assert.equal(turn.observe(tool(41, "bash", { arguments: { description: "Read the diff" } })), "step");
        assert.deepEqual(turn.report, { state: "working", since: at(1), step: "Read the diff" });
        observe(turn, [said(41, "Used main."), event(42, "session.idle", {})]);
        assert.deepEqual(turn.report, { state: "finished", since: at(42), said: "Used main." });
    });

    test("while a plan waits for you, with its summary; a Stop meanwhile stops it", () => {
        const turn = sent();
        observe(turn, [started(1)]);
        assert.equal(turn.observe(event(5, "exit_plan_mode.requested", {
            requestId: "p1", summary: "Fix the retry backoff, then test it.", planContent: "# Plan\n…", actions: ["interactive"],
        }, { ephemeral: true })), "state");
        assert.deepEqual(turn.report, { state: "needsYou", since: at(5), asks: "plan", said: "Fix the retry backoff, then test it." });
        observe(turn, [
            event(20, "abort", { reason: "user_initiated" }),
            event(20, "agent.interrupted", {}),
            event(20, "assistant.idle", { aborted: true }),
            event(20, "session.idle", { aborted: true, mode: "plan" }),
        ]);
        assert.deepEqual(turn.report, { state: "stopped", since: at(20) });
    });

    test("says the latest of what waits on you, as waiting since it was asked, until each is answered", () => {
        const turn = sent();
        observe(turn, [started(1)]);
        assert.equal(turn.observe(event(2, "permission.requested", { requestId: "r1", permissionRequest: { kind: "shell" } })), "state");
        assert.deepEqual(turn.report, { state: "needsYou", since: at(2), asks: "permission" });
        assert.equal(turn.observe(event(3, "elicitation.requested", { requestId: "e1", message: "Sign in to the server" })), "state");
        assert.deepEqual(turn.report, { state: "needsYou", since: at(3), asks: "input", said: "Sign in to the server" });
        // The latest answered, the one before says it waits again, since it was asked: BriefBar notifies of each by that.
        assert.equal(turn.observe(event(4, "elicitation.completed", { requestId: "e1" })), "state");
        assert.deepEqual(turn.report, { state: "needsYou", since: at(2), asks: "permission" });
        // An answer to what it never asked changes nothing.
        assert.equal(turn.observe(event(4, "permission.completed", { requestId: "elsewhere" })), "none");
        assert.equal(turn.observe(event(5, "permission.completed", { requestId: "r1" })), "state");
        assert.deepEqual(turn.report, { state: "working", since: at(1) });

        // One before the latest answered: the latest still says it waits, since it was asked.
        observe(turn, [
            event(6, "user_input.requested", { requestId: "q1", question: "Which branch?" }),
            event(7, "exit_plan_mode.requested", { requestId: "p1", summary: "Fix the backoff." }),
        ]);
        assert.equal(turn.observe(event(8, "user_input.completed", { requestId: "q1", answer: "main" })), "state");
        assert.deepEqual(turn.report, { state: "needsYou", since: at(7), asks: "plan", said: "Fix the backoff." });
    });

    test("not for a permission a hook settled, or for what's asked before its run started", () => {
        const turn = sent();
        assert.equal(turn.observe(event(1, "user_input.requested", { requestId: "q0", question: "The run before's" })), "none");
        observe(turn, [started(2)]);
        assert.equal(turn.observe(event(3, "permission.requested", { requestId: "r1", resolvedByHook: true })), "none");
        assert.equal(turn.observe(event(3, "auto_mode_switch.requested", { requestId: "a1" })), "state");
        assert.equal(turn.report.asks, "input");
    });

    test("ends, with nothing waiting, when the turn ends meanwhile", () => {
        const turn = sent();
        observe(turn, [started(1), event(2, "user_input.requested", { requestId: "q1", question: "Which branch?" })]);
        observe(turn, [event(9, "session.shutdown", {})]);
        assert.deepEqual(turn.report, { state: "stopped", since: at(9), cause: "closed" });
    });
});

describe("autopilot", () => {
    test("goes on through its runs, and says its summary once it's done", () => {
        const turn = sent();
        assert.deepEqual(observe(turn, [
            event(1, "user.message", { messageId: "m1", delivery: "idle", agentMode: "autopilot" }),
            said(2, "one"),
            event(2, "assistant.idle", {}),
            event(2, "user.message", { messageId: "c1", delivery: "idle", source: "autopilot", isAutopilotContinuation: true, content: "" }),
            said(7, "I'm ready."),
            event(7, "assistant.idle", {}),
            event(7, "user.message", { messageId: "c2", delivery: "idle", source: "autopilot", isAutopilotContinuation: true, content: "" }),
            said(10, "", "m1", { toolRequests: [{ name: "task_complete" }] }),
            tool(10, "task_complete", { arguments: { summary: "Replied with one." } }),
            event(10, "session.task_complete", { success: true, summary: "Replied with one." }),
            event(10, "session.autopilot_stopped", { reason: "task_complete", requestId: "m1" }),
            event(10, "assistant.idle", {}),
            event(10, "session.idle", { mode: "autopilot" }),
        ]), ["state", "none", "none", "none", "none", "none", "none", "none", "none", "none", "state", "none", "none"]);
        assert.deepEqual(turn.report, { state: "finished", since: at(10), said: "Replied with one." });
    });

    test("ends with the session idle when autopilot's stop is another request's", () => {
        const turn = sent();
        observe(turn, [started(1), said(2, "Done."), event(3, "session.autopilot_stopped", { reason: "task_complete", requestId: "m0" })]);
        assert.equal(turn.report.state, "working");
        assert.equal(turn.observe(event(4, "session.idle", { mode: "autopilot" })), "state");
        assert.deepEqual(turn.report, { state: "finished", since: at(4), said: "Done." });
    });

    test("ends when autopilot stops a request it doesn't name, only while its run goes on", () => {
        const turn = sent();
        assert.equal(turn.observe(event(1, "session.autopilot_stopped", { reason: "task_complete" })), "none");
        observe(turn, [started(2), said(3, "Done.")]);
        assert.equal(turn.observe(event(4, "session.autopilot_stopped", { reason: "task_complete" })), "state");
        assert.equal(turn.report.state, "finished");
    });

    test("stops at its credit limit, saying so, and fails at an error", () => {
        const limited = sent();
        observe(limited, [
            started(1),
            event(50, "abort", { reason: "autopilot_credit_limit" }),
            event(50, "session.autopilot_stopped", { reason: "aborted", requestId: "m1" }),
        ]);
        assert.deepEqual(limited.report, { state: "stopped", since: at(50), cause: "creditLimit" });
        const failing = sent();
        observe(failing, [started(1), event(9, "session.autopilot_stopped", { reason: "error", requestId: "m1" })]);
        assert.deepEqual(failing.report, { state: "failed", since: at(9) });
    });

    test("finishes without a summary of a task it says failed: with its last words", () => {
        const turn = sent();
        observe(turn, [
            started(1),
            said(2, "I couldn't reach the build."),
            event(3, "session.task_complete", { success: false, summary: "Gave up." }),
            event(3, "session.autopilot_stopped", { reason: "task_complete", requestId: "m1" }),
        ]);
        assert.deepEqual(turn.report, { state: "finished", since: at(3), said: "I couldn't reach the build." });
    });
});

describe("failing", () => {
    test("at an error for its message, even before its run started, saying the error", () => {
        const turn = sent();
        assert.equal(turn.observe(event(1, "session.error", {
            errorType: "rate_limit", message: "Rate limited:\nretry in 60 s", originatingMessageId: "m1",
        })), "state");
        assert.deepEqual(turn.report, { state: "failed", since: at(1), said: "Rate limited: retry in 60 s" });
    });

    test("not at another message's error, or the session's before its run started", () => {
        const turn = sent();
        assert.deepEqual(observe(turn, [
            event(1, "session.error", { message: "Theirs", originatingMessageId: "m0" }),
            event(1, "session.error", { message: "The session's" }),
            started(2),
            event(3, "session.error", { message: "Theirs again", originatingMessageId: "m0" }),
        ]), ["none", "none", "state", "none"]);
        assert.equal(turn.observe(event(4, "session.error", { message: "The session's, while it runs" })), "state");
        assert.deepEqual(turn.report, { state: "failed", since: at(4), said: "The session's, while it runs" });
    });

    test("goes on after an error Copilot may switch models for, and fails only if it ends there", () => {
        const recovered = sent();
        const offered = { message: "The model isn't available.", originatingMessageId: "m1", eligibleForAutoSwitch: true };
        assert.deepEqual(observe(recovered, [started(1), event(2, "session.error", offered)]), ["state", "none"]);
        assert.equal(recovered.report.state, "working");
        observe(recovered, [said(3, "Switched, and fixed it."), event(4, "session.idle", {})]);
        assert.deepEqual(recovered.report, { state: "finished", since: at(4), said: "Switched, and fixed it." });

        const declined = sent();
        observe(declined, [started(1), event(2, "session.error", offered), event(9, "session.idle", {})]);
        assert.deepEqual(declined.report, { state: "failed", since: at(9), said: "The model isn't available." });
        // The next run's start ends it so too.
        const queued = sent();
        observe(queued, [started(1), event(2, "session.error", offered), event(9, "user.message", { messageId: "m2", delivery: "queued" })]);
        assert.equal(queued.report.state, "failed");
    });

    test("when a policy blocks its message", () => {
        const turn = sent();
        assert.deepEqual(observe(turn, [
            started(1),
            event(2, "session.warning", { warningType: "interrupted_tools", message: "Tools were interrupted." }),
            event(2, "session.warning", { warningType: "policy_blocked", message: "Blocked", originatingMessageId: "m0" }),
            event(3, "session.warning", { warningType: "policy_blocked", message: "Blocked by your organization.", originatingMessageId: "m1" }),
        ]), ["state", "none", "none", "state"]);
        assert.deepEqual(turn.report, { state: "failed", since: at(3), said: "Blocked by your organization." });
    });
});

describe("its steps and words", () => {
    test("a step is a tool's description, or else its title, on one line; never Copilot's own asking and reporting", () => {
        const turn = sent();
        observe(turn, [started(1)]);
        assert.equal(turn.observe(tool(2, "bash", { arguments: { description: "Run\n  the   tests" } })), "step");
        assert.equal(turn.report.step, "Run the tests");
        assert.equal(turn.observe(tool(3, "bash", { arguments: { description: "Run the tests" } })), "none");
        assert.equal(turn.observe(tool(4, "view", { arguments: { path: "/tmp/x" }, toolTitle: "Read x" })), "step");
        assert.equal(turn.report.step, "Read x");
        for (const name of ["report_intent", "ask_user", "exit_plan_mode", "task_complete"]) {
            assert.equal(turn.observe(tool(5, name, { arguments: { description: "Own" }, toolTitle: "Own" })), "none", name);
        }
        assert.equal(turn.observe(tool(6, "grep", { arguments: { pattern: "x" } })), "none");
        assert.equal(turn.observe(tool(7, "bash", { arguments: { description: "x".repeat(LONGEST_LINE + 50) } })), "step");
        assert.equal(turn.report.step.length, LONGEST_LINE);
        assert.ok(turn.report.step.endsWith("…"));
    });

    test("a subagent's events say nothing of the turn", () => {
        const turn = sent();
        observe(turn, [started(1), said(2, "Mine.")]);
        assert.deepEqual(observe(turn, [
            said(3, "A subagent's.", "m1", { parentToolCallId: "t1" }),
            event(3, "assistant.message", { messageId: randomUUID(), originatingMessageId: "m1", content: "Also a subagent's." }, { agentId: "a1" }),
            tool(3, "bash", { arguments: { description: "A subagent's step" }, parentToolCallId: "t1" }),
            event(3, "tool.execution_start", { toolName: "bash", arguments: { description: "Its step" } }, { agentId: "a1" }),
            event(3, "session.idle", {}, { agentId: "a1" }),
        ]), ["none", "none", "none", "none", "none"]);
        assert.deepEqual(turn.report, { state: "working", since: at(1) });
        observe(turn, [event(4, "session.idle", {})]);
        assert.equal(turn.report.said, "Mine.");
    });

    test("never says the message it was sent", () => {
        const turn = sent();
        const events = [
            started(1),
            event(1, "user.message", { messageId: "s1", delivery: "steering", content: PROMPT }),
            event(2, "user_input.requested", { requestId: "q1", question: "Which branch?" }),
        ];
        for (const each of events) {
            turn.observe(each);
            assert.ok(!JSON.stringify(turn.report).includes("PROMPT-MARKER"));
        }
    });

    test("words keep their lines, lose other control characters, and are cut short when long", () => {
        assert.equal(text("Fixed it.\r\n\r\n- One\x07\u200b\n- Two\t3 "), "Fixed it.\n\n- One\n- Two\t3");
        assert.equal(text(" \n "), undefined);
        assert.equal(text(42), undefined);
        const long = text("y".repeat(LONGEST_SAID + 1));
        assert.equal(long.length, LONGEST_SAID);
        assert.ok(long.endsWith("…"));
        assert.equal(text("y".repeat(LONGEST_SAID)).length, LONGEST_SAID);
        assert.equal(line("A\nB\u0000  C"), "A B C");
        assert.equal(line("\u202e"), undefined);
        assert.equal(line(undefined), undefined);
    });

    test("takes nothing that isn't an event, and says every state it can be in", () => {
        const turn = sent();
        assert.deepEqual(observe(turn, [null, "user.message", 4, { type: "user.message" }, { type: "user.message", data: null }]),
            ["none", "none", "none", "none", "none"]);
        assert.equal(turn.begin(""), "none");
        assert.equal(followTurn().begin(42), "none");
        assert.deepEqual(STATES, ["waiting", "working", "needsYou", "finished", "failed", "stopped"]);
    });
});
