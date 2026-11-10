// BriefBar's extension for the Copilot app's sessions, as its outbox works (Resources/CopilotPlugin/briefbar-sessions):
// against made-up sessions, in a temporary folder of its own, never BriefBar's. `make plugin-test` runs it.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { after, beforeEach, describe, test } from "node:test";
import {
    CLOCK_SLACK_MS,
    LONGEST_WAIT_MS,
    MOST_BYTES,
    OutboxError,
    checkRequest,
    defaultFolder,
    forked,
    listen,
    start,
    stopWithTheSession,
} from "../../Resources/CopilotPlugin/briefbar-sessions/com.github.copilot/extensions/briefbar-sessions/outbox.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "briefbar-outbox-test-"));
after(() => {
    // Their watchers would keep this process running.
    for (const outbox of open) outbox.stop();
    fs.rmSync(root, { recursive: true, force: true });
});

const NOW = Date.parse("2026-11-02T10:00:00.000Z");
const STARTED = Date.parse("2026-11-02T09:59:58.500Z");
const PROMPT = "Fix the comments on !4102. PROMPT-MARKER-7f3e";
const iso = (time) => new Date(time).toISOString();

let folder;
let open = [];
beforeEach(() => {
    folder = path.join(fs.mkdtempSync(path.join(root, "case-")), "Outbox");
    for (const outbox of open) outbox.stop();
    open = [];
});

/** A made-up session: what it was sent and asked to run, how many times its turn was stopped, and the answers it gives,
 * its name among them. `emit` sends what listens to its events one, made at `timestamp`; `handlers` are those. */
function fakeSession(sessionId = randomUUID(), { send, execute, abort, name = () => ({ name: "Retry backoff" }) } = {}) {
    const calls = { sent: [], executed: [] };
    const stops = { count: 0 };
    const forkId = randomUUID();
    const handlers = new Set();
    const session = {
        sessionId,
        async send(options) {
            calls.sent.push(options);
            return send ? send(options) : `message-${calls.sent.length}`;
        },
        async abort() {
            stops.count += 1;
            if (abort) return abort();
        },
        on(handler) {
            handlers.add(handler);
            return () => handlers.delete(handler);
        },
        rpc: {
            tools: {
                async execute(params) {
                    calls.executed.push(params);
                    if (execute) return execute(params);
                    return {
                        resultType: "success",
                        textResultForLlm: `Forked session into new workspace 'Work fork' (workspace_id: ${randomUUID()}, session_id: ${forkId}). The user can switch to it from the sidebar.`,
                    };
                },
            },
            name: {
                get: async () => name(),
            },
        },
    };
    const emit = (type, data = {}, timestamp = iso(NOW)) => {
        const event = { id: randomUUID(), timestamp, parentId: null, type, data };
        for (const handler of [...handlers]) handler(event);
    };
    return { session, calls, forkId, stops, emit, handlers };
}

function listenTo(session, options = {}) {
    const outbox = listen(session, { folder, startedAt: STARTED, now: () => NOW, isRunning: () => true, ...options });
    open.push(outbox);
    return outbox;
}

function request(sessionId, fields = {}) {
    const kind = fields.kind ?? "send";
    return {
        version: 1,
        requestId: randomUUID(),
        sessionId,
        kind,
        ...(kind === "send" ? { prompt: PROMPT } : {}),
        createdAt: iso(NOW - 1000),
        expiresAt: iso(NOW + 60_000),
        ...fields,
    };
}

/** Writes a request as BriefBar does: a temporary file whose name starts with a dot, then renamed into place. */
function writeRequest(value, { name, mode = 0o600, text } = {}) {
    const requests = path.join(folder, "requests");
    const temporary = path.join(requests, `.${randomUUID()}.tmp`);
    fs.writeFileSync(temporary, text ?? JSON.stringify(value), { mode });
    fs.chmodSync(temporary, mode);
    const file = path.join(requests, name ?? `${value.sessionId}.${value.requestId}.json`);
    fs.renameSync(temporary, file);
    return file;
}

function readResult(requestId) {
    const file = path.join(folder, "results", `${requestId}.json`);
    if (!fs.existsSync(file)) return undefined;
    const stat = fs.lstatSync(file);
    assert.ok(stat.isFile());
    assert.equal(stat.mode & 0o777, 0o600);
    return JSON.parse(fs.readFileSync(file, "utf8"));
}

async function waitFor(check, what) {
    for (let i = 0; i < 100; i++) {
        const value = check();
        if (value !== undefined) return value;
        await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert.fail(`Timed out waiting for ${what}`);
}

/** Every file under the outbox, by its path, with what it holds. */
function everything(dir = folder) {
    const files = {};
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const file = path.join(dir, entry.name);
        if (entry.isDirectory()) Object.assign(files, everything(file));
        else if (entry.isFile()) files[file] = fs.readFileSync(file, "utf8");
    }
    return files;
}

describe("listening", () => {
    test("says it listens once it has joined, in private folders it makes", () => {
        const { session, calls } = fakeSession();
        listenTo(session, { pid: 4242 });
        for (const name of ["", "requests", "results", "listening", "reports"]) {
            const stat = fs.lstatSync(path.join(folder, name));
            assert.ok(stat.isDirectory(), name);
            assert.equal(stat.mode & 0o777, 0o700, name);
        }
        const file = path.join(folder, "listening", `${session.sessionId}.json`);
        assert.equal(fs.lstatSync(file).mode & 0o777, 0o600);
        assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), {
            version: 1, sessionId: session.sessionId, pid: 4242, startedAt: iso(STARTED), kinds: ["send", "fork", "stop"],
        });
        // It does nothing until BriefBar asks.
        assert.deepEqual(calls, { sent: [], executed: [] });
        assert.deepEqual(fs.readdirSync(path.join(folder, "results")), []);
    });

    test("is in BriefBar's folder, in Application Support", () => {
        assert.equal(
            defaultFolder("/Users/someone"),
            "/Users/someone/Library/Application Support/BriefBar/Copilot/Outbox",
        );
    });

    test("replaces a listening file that another extension of its session left, and removes only its own", () => {
        const { session } = fakeSession();
        const file = path.join(folder, "listening", `${session.sessionId}.json`);
        const first = listenTo(session, { pid: 111 });
        const second = listenTo(session, { pid: 222 });
        assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).pid, 222);
        // The first one ends after the second started: the second still listens.
        first.stop();
        assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).pid, 222);
        second.stop();
        assert.ok(!fs.existsSync(file));
    });

    test("refuses an outbox that isn't private to you, or isn't a real folder", () => {
        const { session } = fakeSession();
        fs.mkdirSync(folder, { mode: 0o755 });
        fs.chmodSync(folder, 0o755);
        assert.throws(() => listen(session, { folder }), OutboxError);
        // Exactly 0700, as BriefBar checks it: not with the sticky bit, or one that sets a group.
        for (const mode of [0o1700, 0o2700]) {
            fs.chmodSync(folder, mode);
            assert.throws(() => listen(session, { folder }), OutboxError, mode.toString(8));
        }
        fs.chmodSync(folder, 0o700);

        const elsewhere = fs.mkdtempSync(path.join(root, "elsewhere-"));
        fs.chmodSync(elsewhere, 0o700);
        fs.symlinkSync(elsewhere, path.join(folder, "requests"));
        assert.throws(() => listen(session, { folder }), OutboxError);
        assert.deepEqual(fs.readdirSync(elsewhere), []);
        assert.ok(!fs.existsSync(path.join(folder, "listening", `${session.sessionId}.json`)));
    });

    test("follows no link below the folder it trusts, and makes the folders it's in that are missing", () => {
        const { session } = fakeSession();
        const home = path.dirname(folder);
        const outbox = path.join(home, "Library", "Application Support", "BriefBar", "Copilot", "Outbox");
        const elsewhere = fs.mkdtempSync(path.join(root, "elsewhere-"));
        fs.mkdirSync(path.join(home, "Library", "Application Support"), { recursive: true });
        fs.symlinkSync(elsewhere, path.join(home, "Library", "Application Support", "BriefBar"));
        assert.throws(() => listen(session, { folder: outbox, root: home }), OutboxError);
        assert.deepEqual(fs.readdirSync(elsewhere), []);

        fs.rmSync(path.join(home, "Library", "Application Support", "BriefBar"));
        const outboxThere = listenTo(session, { folder: outbox, root: home });
        for (const name of ["BriefBar", "BriefBar/Copilot"]) {
            assert.equal(fs.lstatSync(path.join(home, "Library", "Application Support", name)).mode & 0o7777, 0o700, name);
        }
        assert.ok(fs.existsSync(path.join(outbox, "listening", `${session.sessionId}.json`)));
        outboxThere.stop();
        assert.throws(() => listen(session, { folder: outbox, root: path.join(home, "Elsewhere") }), OutboxError);
    });

    test("listens only for a session whose ID is a UUID", () => {
        for (const sessionId of ["../../etc", "", "1234", undefined]) {
            assert.throws(() => listen({ sessionId, send() {} }, { folder }), OutboxError, String(sessionId));
        }
        assert.ok(!fs.existsSync(folder));
    });
});

describe("sending", () => {
    test("sends its own session the prompt, once, as an ordinary message", async () => {
        const { session, calls } = fakeSession();
        const outbox = listenTo(session);
        const value = request(session.sessionId);
        writeRequest(value);
        await outbox.scan();
        // As session.send's default: queued if a turn is running.
        assert.deepEqual(calls.sent, [{ prompt: PROMPT }]);
        assert.deepEqual(calls.executed, []);
        assert.deepEqual(readResult(value.requestId), {
            version: 1, requestId: value.requestId, sessionId: session.sessionId, kind: "send", ok: true,
            messageId: "message-1", finishedAt: iso(NOW),
        });
        // The request and its claim are gone, and nothing holds the prompt.
        assert.deepEqual(fs.readdirSync(path.join(folder, "requests")), []);
        await outbox.scan();
        assert.equal(calls.sent.length, 1);
        for (const [file, text] of Object.entries(everything())) assert.ok(!text.includes("PROMPT-MARKER"), file);
    });

    test("notices a request as it arrives", async () => {
        const { session, calls } = fakeSession();
        listenTo(session);
        const value = request(session.sessionId);
        writeRequest(value);
        const result = await waitFor(() => readResult(value.requestId), "the result");
        assert.equal(result.ok, true);
        assert.equal(calls.sent.length, 1);
    });

    test("handles requests that were there before it started, oldest first", async () => {
        const { session, calls } = fakeSession();
        fs.mkdirSync(path.join(folder, "requests"), { recursive: true, mode: 0o700 });
        for (const dir of [path.dirname(folder), folder, path.join(folder, "requests")]) fs.chmodSync(dir, 0o700);
        const later = request(session.sessionId, { prompt: "second" });
        const earlier = request(session.sessionId, { prompt: "first" });
        fs.utimesSync(writeRequest(later), new Date(NOW - 1000), new Date(NOW - 1000));
        fs.utimesSync(writeRequest(earlier), new Date(NOW - 5000), new Date(NOW - 5000));
        const outbox = listenTo(session);
        await outbox.scan();
        assert.deepEqual(calls.sent.map((options) => options.prompt), ["first", "second"]);
    });

    test("one request is handled by one extension, even with two in the session", async () => {
        const one = fakeSession();
        const two = fakeSession(one.session.sessionId);
        const first = listenTo(one.session, { pid: 111 });
        const second = listenTo(two.session, { pid: 222 });
        const value = request(one.session.sessionId);
        writeRequest(value);
        await Promise.all([first.scan(), second.scan()]);
        assert.equal(one.calls.sent.length + two.calls.sent.length, 1);
        assert.equal(readResult(value.requestId).ok, true);
    });

    test("leaves other sessions' requests, and anything else, where they are", async () => {
        const { session, calls } = fakeSession();
        const outbox = listenTo(session);
        const theirs = writeRequest(request(randomUUID()));
        const dotted = path.join(folder, "requests", `.${session.sessionId}.${randomUUID()}.json`);
        fs.writeFileSync(dotted, JSON.stringify(request(session.sessionId)), { mode: 0o600 });
        const odd = path.join(folder, "requests", `${session.sessionId}.not-a-request.json`);
        fs.writeFileSync(odd, "{}", { mode: 0o600 });
        fs.mkdirSync(path.join(folder, "requests", `${session.sessionId}.${randomUUID()}.json`));
        await outbox.scan();
        assert.deepEqual(calls, { sent: [], executed: [] });
        assert.ok(fs.existsSync(theirs) && fs.existsSync(dotted) && fs.existsSync(odd));
        assert.deepEqual(fs.readdirSync(path.join(folder, "results")), []);
    });

    test("says it couldn't send, without the prompt", async () => {
        const { session } = fakeSession(undefined, {
            send({ prompt }) {
                throw new Error(`Session closed while sending: ${prompt}`);
            },
        });
        const outbox = listenTo(session);
        const value = request(session.sessionId);
        writeRequest(value);
        await outbox.scan();
        const result = readResult(value.requestId);
        assert.equal(result.ok, false);
        assert.equal(result.kind, "send");
        assert.equal(result.error.code, "send_failed");
        assert.equal(result.messageId, undefined);
        for (const [file, text] of Object.entries(everything())) assert.ok(!text.includes("PROMPT-MARKER"), file);
    });

    test("says how a slow send went once it's done, and nothing before, so BriefBar never hears it failed", async () => {
        let finish;
        const { session } = fakeSession(undefined, { send: () => new Promise((resolve) => { finish = resolve; }) });
        const outbox = listenTo(session);
        const value = request(session.sessionId);
        writeRequest(value);
        const scanning = outbox.scan();
        await waitFor(() => finish, "the send");
        await new Promise((resolve) => setTimeout(resolve, 100));
        // Still going: BriefBar, once it stops waiting, says the prompt may have reached the session.
        assert.equal(readResult(value.requestId), undefined);
        finish("message-late");
        await scanning;
        assert.equal(readResult(value.requestId).messageId, "message-late");
    });

    test("finishes a request it claimed even if it expires meanwhile", async () => {
        let clock = NOW;
        const { session } = fakeSession(undefined, {
            send() {
                clock += LONGEST_WAIT_MS * 2;
                return "message-1";
            },
        });
        const outbox = listenTo(session, { now: () => clock });
        const value = request(session.sessionId);
        writeRequest(value);
        await outbox.scan();
        const result = readResult(value.requestId);
        assert.equal(result.ok, true);
        assert.equal(result.finishedAt, iso(clock));
    });
});

describe("reporting", () => {
    function readReport(requestId) {
        const file = path.join(folder, "reports", `${requestId}.json`);
        if (!fs.existsSync(file)) return undefined;
        const stat = fs.lstatSync(file);
        assert.ok(stat.isFile());
        assert.equal(stat.mode & 0o777, 0o600);
        return JSON.parse(fs.readFileSync(file, "utf8"));
    }

    /** A session that takes up each message as it's sent, as an idle one does: before `send` answers. */
    function idleSession(options = {}) {
        const fake = fakeSession(undefined, {
            ...options,
            send() {
                const messageId = `message-${fake.calls.sent.length}`;
                fake.emit("user.message", { messageId, delivery: "idle", content: PROMPT }, iso(NOW + 100));
                return messageId;
            },
        });
        return fake;
    }

    async function sendReported(fake, fields = {}) {
        const outbox = listenTo(fake.session, { pid: 4242 });
        const value = request(fake.session.sessionId, { report: true, ...fields });
        writeRequest(value);
        await outbox.scan();
        return { outbox, value, result: readResult(value.requestId) };
    }

    test("says how the turn of a send it's asked to report goes, in a private file it rewrites whole until it ends", async () => {
        const fake = idleSession();
        const { value, result } = await sendReported(fake);
        const { requestId } = value;
        const sessionId = fake.session.sessionId;
        assert.deepEqual(result, {
            version: 1, requestId, sessionId, kind: "send", ok: true, messageId: "message-1", reports: true, finishedAt: iso(NOW),
        });
        assert.deepEqual(readReport(requestId), {
            version: 1, requestId, sessionId, messageId: "message-1", pid: 4242, startedAt: iso(STARTED),
            name: "Retry backoff", state: "working", since: iso(NOW + 100), updatedAt: iso(NOW),
        });

        fake.emit("assistant.message", { messageId: "a1", originatingMessageId: "message-1", content: "Fixed the backoff." });
        fake.emit("user_input.requested", { requestId: "q1", question: "Push it?" }, iso(NOW + 5000));
        assert.deepEqual(readReport(requestId), {
            version: 1, requestId, sessionId, messageId: "message-1", pid: 4242, startedAt: iso(STARTED),
            name: "Retry backoff", state: "needsYou", since: iso(NOW + 5000), asks: "question", said: "Push it?", updatedAt: iso(NOW),
        });
        fake.emit("user_input.completed", { requestId: "q1" }, iso(NOW + 8000));
        assert.equal(readReport(requestId).state, "working");
        fake.emit("session.idle", { mode: "interactive" }, iso(NOW + 9000));
        assert.deepEqual(readReport(requestId), {
            version: 1, requestId, sessionId, messageId: "message-1", pid: 4242, startedAt: iso(STARTED),
            name: "Retry backoff", state: "finished", since: iso(NOW + 9000), said: "Fixed the backoff.", updatedAt: iso(NOW),
        });
        // Over: it stops hearing the session, and leaves the report for BriefBar.
        assert.equal(fake.handlers.size, 0);
        assert.deepEqual(fs.readdirSync(path.join(folder, "reports")), [`${requestId}.json`]);
        // Nothing holds the prompt, though the session's own message has it.
        for (const [file, text] of Object.entries(everything())) assert.ok(!text.includes("PROMPT-MARKER"), file);
    });

    test("reports nothing it isn't asked to, or for a session that doesn't say its events", async () => {
        const fake = fakeSession();
        const outbox = listenTo(fake.session);
        for (const fields of [{}, { report: false }]) {
            const value = request(fake.session.sessionId, fields);
            writeRequest(value);
            await outbox.scan();
            assert.equal(readResult(value.requestId).ok, true);
            assert.equal(readResult(value.requestId).reports, undefined);
        }
        assert.equal(fake.handlers.size, 0);

        const older = fakeSession();
        delete older.session.on;
        const { result } = await sendReported(older);
        assert.equal(result.ok, true);
        assert.equal(result.reports, undefined);
        assert.deepEqual(older.calls.sent, [{ prompt: PROMPT }]);
        assert.deepEqual(fs.readdirSync(path.join(folder, "reports")), []);
    });

    test("reports a turn that ended before the send answered, and stops following it at once", async () => {
        const fake = fakeSession(undefined, {
            send() {
                fake.emit("user.message", { messageId: "message-1", delivery: "idle" }, iso(NOW + 100));
                fake.emit("assistant.message", { messageId: "a1", originatingMessageId: "message-1", content: "Done." });
                fake.emit("session.idle", { mode: "interactive" }, iso(NOW + 200));
                return "message-1";
            },
        });
        const { value, result } = await sendReported(fake);
        assert.equal(result.reports, true);
        const report = readReport(value.requestId);
        assert.equal(report.state, "finished");
        assert.equal(report.since, iso(NOW + 200));
        assert.equal(report.said, "Done.");
        assert.equal(fake.handlers.size, 0);
    });

    test("follows each send's turn on its own: one queued behind another waits, then works as the first ends", async () => {
        const fake = fakeSession();
        const outbox = listenTo(fake.session);
        const first = request(fake.session.sessionId, { report: true });
        writeRequest(first);
        await outbox.scan();
        fake.emit("user.message", { messageId: "message-1", delivery: "idle" });
        const second = request(fake.session.sessionId, { report: true });
        writeRequest(second);
        await outbox.scan();
        assert.equal(readReport(first.requestId).state, "working");
        assert.equal(readReport(second.requestId).state, "waiting");
        fake.emit("assistant.message", { messageId: "a1", originatingMessageId: "message-1", content: "First done." });
        fake.emit("assistant.idle", {});
        fake.emit("user.message", { messageId: "message-2", delivery: "queued" }, iso(NOW + 3000));
        assert.equal(readReport(first.requestId).state, "finished");
        assert.equal(readReport(first.requestId).said, "First done.");
        assert.equal(readReport(second.requestId).state, "working");
        fake.emit("assistant.message", { messageId: "a2", originatingMessageId: "message-2", content: "Second done." });
        fake.emit("session.idle", {});
        assert.equal(readReport(second.requestId).said, "Second done.");
        assert.equal(fake.handlers.size, 0);
    });

    test("says the step it's at at most once a second, and how the turn stands at once", async () => {
        const fake = idleSession();
        const { value } = await sendReported(fake);
        const step = (description) =>
            fake.emit("tool.execution_start", { toolCallId: randomUUID(), toolName: "bash", arguments: { description } });
        step("One");
        step("Two");
        // Its first report was written just now: the latest step waits for a second to pass.
        assert.equal(readReport(value.requestId).step, undefined);
        await waitFor(() => (readReport(value.requestId).step === "Two" ? true : undefined), "the latest step, a second later");
        // How the turn stands, at once.
        fake.emit("user_input.requested", { requestId: "q1", question: "Push it?" });
        assert.equal(readReport(value.requestId).state, "needsYou");
        fake.emit("user_input.completed", { requestId: "q1" });
        const working = readReport(value.requestId);
        assert.deepEqual([working.state, working.step], ["working", undefined]);
        step("Three");
        assert.equal(readReport(value.requestId).step, undefined);
        await waitFor(() => (readReport(value.requestId).step === "Three" ? true : undefined), "the step, a second later");
    });

    test("reads the session's name again as it starts waiting on you, in case you renamed it", async () => {
        let name = "Retry backoff";
        const fake = idleSession({ name: () => ({ name }) });
        const { value } = await sendReported(fake);
        assert.equal(readReport(value.requestId).name, "Retry backoff");
        name = "Retry backoff\n(renamed)";
        fake.emit("user_input.requested", { requestId: "q1", question: "Push it?" });
        await waitFor(() => (readReport(value.requestId).name === "Retry backoff (renamed)" ? true : undefined), "the new name");
        assert.equal(readReport(value.requestId).state, "needsYou");
    });

    test("says no name when the session can't tell it, in time or at all", async () => {
        for (const name of [() => { throw new Error("No such method"); }, () => ({}), () => new Promise(() => {})]) {
            const fake = idleSession({ name });
            const { value, result } = await sendReported(fake);
            assert.equal(result.reports, true);
            const report = readReport(value.requestId);
            assert.equal(report.state, "working");
            assert.ok(!Object.hasOwn(report, "name"));
        }
    });

    test("says it doesn't report a turn whose report it can't write, and follows nothing", async () => {
        const fake = idleSession();
        const outbox = listenTo(fake.session);
        const value = request(fake.session.sessionId, { report: true });
        // A folder where its report would go.
        fs.mkdirSync(path.join(folder, "reports", `${value.requestId}.json`));
        writeRequest(value);
        await outbox.scan();
        const result = readResult(value.requestId);
        assert.equal(result.ok, true);
        assert.equal(result.reports, undefined);
        assert.equal(fake.handlers.size, 0);
        assert.deepEqual(fs.readdirSync(path.join(folder, "reports")), [`${value.requestId}.json`]);
    });

    test("follows nothing for a send that failed", async () => {
        const fake = fakeSession(undefined, {
            send() {
                throw new Error("Session closed");
            },
        });
        const { result } = await sendReported(fake);
        assert.equal(result.ok, false);
        assert.equal(result.reports, undefined);
        assert.equal(fake.handlers.size, 0);
        assert.deepEqual(fs.readdirSync(path.join(folder, "reports")), []);
    });

    test("says at once that the session closed, as the extension stops with it", async () => {
        const fake = idleSession();
        const { value } = await sendReported(fake);
        fake.emit("session.shutdown", { shutdownType: "routine" }, iso(NOW + 4000));
        const report = readReport(value.requestId);
        assert.equal(report.state, "stopped");
        assert.equal(report.cause, "closed");
        assert.equal(report.since, iso(NOW + 4000));
        assert.equal(fake.handlers.size, 0);
    });

    test("stops following as it stops listening, leaving what each report last said", async () => {
        const fake = idleSession();
        const { outbox, value } = await sendReported(fake);
        outbox.stop();
        assert.equal(fake.handlers.size, 0);
        fake.emit("session.idle", {});
        assert.equal(readReport(value.requestId).state, "working");
    });

    test("stops following a turn whose report BriefBar removed, as turning Azure DevOps off does, and writes it no more", async () => {
        const fake = idleSession();
        const { value } = await sendReported(fake);
        const reports = path.join(folder, "reports");
        fs.rmSync(path.join(reports, `${value.requestId}.json`));
        fake.emit("user_input.requested", { requestId: "q1", question: "Push it?" }, iso(NOW + 5000));
        assert.deepEqual(fs.readdirSync(reports), []);
        assert.equal(fake.handlers.size, 0);
        fake.emit("assistant.message", { messageId: "a1", originatingMessageId: "message-1", content: "Fixed the backoff." });
        fake.emit("session.idle", {}, iso(NOW + 9000));
        assert.deepEqual(fs.readdirSync(reports), []);
        // The session's turn goes on: only its report stops.
        assert.equal(fake.stops.count, 0);
    });

    test("starts no report for a send whose request BriefBar removed as it went, as turning Azure DevOps off does", async () => {
        let answer;
        const fake = fakeSession(undefined, { send: () => new Promise((resolve) => { answer = resolve; }) });
        const outbox = listenTo(fake.session);
        const value = request(fake.session.sessionId, { report: true });
        writeRequest(value);
        const scanning = outbox.scan();
        await waitFor(() => answer, "the send");
        // BriefBar forgets its requests, the ones claimed too.
        const requests = path.join(folder, "requests");
        for (const name of fs.readdirSync(requests)) fs.rmSync(path.join(requests, name));
        answer("message-1");
        await scanning;
        const result = readResult(value.requestId);
        assert.equal(result.ok, true);
        assert.equal(result.reports, undefined);
        assert.equal(fake.handlers.size, 0);
        assert.deepEqual(fs.readdirSync(path.join(folder, "reports")), []);
        // It went all the same.
        assert.deepEqual(fake.calls.sent, [{ prompt: PROMPT }]);
    });
});

describe("turning requests down", () => {
    const cases = [
        ["one that isn't private to you", (sessionId) => ({ value: request(sessionId), mode: 0o644 }), "invalid"],
        ["one that isn't JSON", (sessionId) => ({ value: request(sessionId), text: "{ not json" }), "invalid"],
        ["one that isn't UTF-8", (sessionId) => ({ value: request(sessionId), text: Buffer.from([0x7b, 0xff, 0xfe, 0x7d]) }), "invalid"],
        ["one that's a list", (sessionId) => ({ value: request(sessionId), text: "[]" }), "invalid"],
        ["another version", (sessionId) => ({ value: request(sessionId, { version: 2 }) }), "invalid"],
        ["one whose ID isn't its name's", (sessionId) => ({ value: request(sessionId), name: `${sessionId}.${randomUUID()}.json` }), "invalid"],
        ["one for another session, named for this one", () => ({ value: request(randomUUID()) }), "invalid"],
        ["another kind", (sessionId) => ({ value: request(sessionId, { kind: "delete" }) }), "invalid"],
        ["a send without a prompt", (sessionId) => ({ value: request(sessionId, { prompt: undefined }) }), "invalid"],
        ["a send with an empty prompt", (sessionId) => ({ value: request(sessionId, { prompt: "  \n" }) }), "invalid"],
        ["a fork with a prompt", (sessionId) => ({ value: request(sessionId, { kind: "fork", prompt: PROMPT }) }), "invalid"],
        ["a stop with a prompt", (sessionId) => ({ value: request(sessionId, { kind: "stop", prompt: PROMPT }) }), "invalid"],
        ["one whose times aren't ISO 8601", (sessionId) => ({ value: request(sessionId, { createdAt: "Mon, 02 Nov 2026 10:00:00 GMT" }) }), "invalid"],
        ["one that would wait longer than 120 s", (sessionId) => ({ value: request(sessionId, { createdAt: iso(NOW), expiresAt: iso(NOW + LONGEST_WAIT_MS + 1) }) }), "invalid"],
        ["one that expires before it's made", (sessionId) => ({ value: request(sessionId, { createdAt: iso(NOW), expiresAt: iso(NOW - 1) }) }), "invalid"],
        ["one dated in the future", (sessionId) => ({ value: request(sessionId, { createdAt: iso(NOW + CLOCK_SLACK_MS + 1000), expiresAt: iso(NOW + 60_000) }) }), "invalid"],
        ["one that expired", (sessionId) => ({ value: request(sessionId, { createdAt: iso(NOW - 60_000), expiresAt: iso(NOW) }) }), "expired"],
    ];
    for (const [what, make, code] of cases) {
        test(`turns down ${what}`, async () => {
            const { session, calls } = fakeSession();
            const outbox = listenTo(session);
            const { value, name, ...options } = make(session.sessionId);
            // Named for this session, as BriefBar names them, unless the case names it otherwise.
            const file = name ?? `${session.sessionId}.${value.requestId}.json`;
            writeRequest(value, { name: file, ...options });
            await outbox.scan();
            assert.deepEqual(calls, { sent: [], executed: [] });
            // Its result is under the request ID in its name, which BriefBar waits for.
            const result = readResult(file.split(".")[1]);
            assert.equal(result.ok, false);
            assert.equal(result.error.code, code);
            assert.ok(!result.error.message.includes("PROMPT-MARKER"));
            assert.equal(result.sessionId, session.sessionId);
            assert.deepEqual(fs.readdirSync(path.join(folder, "requests")), []);
        });
    }

    test("says which kind a turned-down request was, when it was a valid one", async () => {
        const { session } = fakeSession();
        const outbox = listenTo(session);
        const fork = request(session.sessionId, { kind: "fork", version: 2 });
        const unknown = request(session.sessionId, { kind: "delete" });
        writeRequest(fork);
        writeRequest(unknown);
        await outbox.scan();
        assert.equal(readResult(fork.requestId).kind, "fork");
        assert.equal(readResult(unknown.requestId).kind, undefined);
    });

    test("reads a request of 256 KiB, and turns down a larger one", async () => {
        const { session, calls } = fakeSession();
        const outbox = listenTo(session);
        const sized = (bytes) => {
            const value = request(session.sessionId, { prompt: "" });
            const empty = Buffer.byteLength(JSON.stringify(value));
            return { ...value, prompt: "x".repeat(bytes - empty) };
        };
        const largest = sized(MOST_BYTES);
        const larger = sized(MOST_BYTES + 1);
        assert.equal(Buffer.byteLength(JSON.stringify(largest)), MOST_BYTES);
        writeRequest(largest);
        writeRequest(larger);
        await outbox.scan();
        assert.equal(readResult(largest.requestId).ok, true);
        assert.equal(readResult(larger.requestId).error.code, "invalid");
        assert.equal(calls.sent.length, 1);
    });

    test("turns down a link, and leaves what it points to alone", async () => {
        const { session, calls } = fakeSession();
        const outbox = listenTo(session);
        const value = request(session.sessionId);
        const target = path.join(path.dirname(folder), "target.json");
        fs.writeFileSync(target, JSON.stringify(value), { mode: 0o600 });
        fs.symlinkSync(target, path.join(folder, "requests", `${session.sessionId}.${value.requestId}.json`));
        await outbox.scan();
        assert.deepEqual(calls.sent, []);
        assert.equal(readResult(value.requestId).error.code, "invalid");
        assert.equal(fs.readFileSync(target, "utf8"), JSON.stringify(value));
        assert.deepEqual(fs.readdirSync(path.join(folder, "requests")), []);
    });

    test("leaves a request BriefBar withdrew", async () => {
        const { session, calls } = fakeSession();
        const outbox = listenTo(session);
        const file = writeRequest(request(session.sessionId));
        fs.rmSync(file);
        await outbox.scan();
        assert.deepEqual(calls.sent, []);
        assert.deepEqual(fs.readdirSync(path.join(folder, "results")), []);
    });

    test("checks each field as the contract says", () => {
        const sessionId = randomUUID();
        const value = request(sessionId);
        const sent = { kind: "send", prompt: PROMPT, report: false };
        assert.deepEqual(checkRequest(value, { requestId: value.requestId, sessionId, now: NOW }), sent);
        const reported = request(sessionId, { report: true });
        assert.deepEqual(checkRequest(reported, { requestId: reported.requestId, sessionId, now: NOW }), { ...sent, report: true });
        const unreported = request(sessionId, { report: false });
        assert.deepEqual(checkRequest(unreported, { requestId: unreported.requestId, sessionId, now: NOW }), sent);
        for (const report of ["yes", 1, null]) {
            const odd = request(sessionId, { report });
            assert.throws(() => checkRequest(odd, { requestId: odd.requestId, sessionId, now: NOW }), { code: "invalid" }, String(report));
        }
        const fork = request(sessionId, { kind: "fork" });
        assert.deepEqual(checkRequest(fork, { requestId: fork.requestId, sessionId, now: NOW }), { kind: "fork" });
        const stop = request(sessionId, { kind: "stop" });
        assert.deepEqual(checkRequest(stop, { requestId: stop.requestId, sessionId, now: NOW }), { kind: "stop" });
        // Only a send has a turn to report.
        for (const kind of ["fork", "stop"]) {
            const odd = request(sessionId, { kind, report: true });
            assert.throws(() => checkRequest(odd, { requestId: odd.requestId, sessionId, now: NOW }), { code: "invalid", kind });
        }
        // Swift's ISO 8601 dates, with and without fractions of a second, in UTC or with an offset.
        for (const createdAt of ["2026-11-02T09:59:59Z", "2026-11-02T09:59:59.123Z", "2026-11-02T11:59:59+02:00"]) {
            const dated = request(sessionId, { createdAt });
            assert.equal(checkRequest(dated, { requestId: dated.requestId, sessionId, now: NOW }).kind, "send", createdAt);
        }
        // Just within a minute and a hair under two of waiting, and just expired.
        const longest = request(sessionId, { createdAt: iso(NOW - 1000), expiresAt: iso(NOW - 1000 + LONGEST_WAIT_MS) });
        assert.equal(checkRequest(longest, { requestId: longest.requestId, sessionId, now: NOW }).kind, "send");
        assert.throws(() => checkRequest(value, { requestId: value.requestId, sessionId, now: Date.parse(value.expiresAt) }), { code: "expired" });
    });
});

describe("stopping", () => {
    test("stops its own session's turn, as the app's Stop does, and sends and forks nothing", async () => {
        const { session, calls, stops } = fakeSession();
        const outbox = listenTo(session);
        const value = request(session.sessionId, { kind: "stop" });
        writeRequest(value);
        await outbox.scan();
        assert.equal(stops.count, 1);
        assert.deepEqual(calls, { sent: [], executed: [] });
        assert.deepEqual(readResult(value.requestId), {
            version: 1, requestId: value.requestId, sessionId: session.sessionId, kind: "stop", ok: true, finishedAt: iso(NOW),
        });
    });

    test("says it couldn't stop the turn, in its own words", async () => {
        const { session, stops } = fakeSession(undefined, { abort: () => Promise.reject(new Error("Not connected")) });
        const outbox = listenTo(session);
        const value = request(session.sessionId, { kind: "stop" });
        writeRequest(value);
        await outbox.scan();
        assert.equal(stops.count, 1);
        const result = readResult(value.requestId);
        assert.equal(result.ok, false);
        assert.equal(result.kind, "stop");
        assert.deepEqual(result.error, { code: "stop_failed", message: "Copilot didn't stop the session's turn." });
    });
});

describe("forking", () => {
    test("forks its own session with the app's fork, and says which session is the fork", async () => {
        const { session, calls, forkId } = fakeSession();
        const outbox = listenTo(session);
        const value = request(session.sessionId, { kind: "fork" });
        writeRequest(value);
        await outbox.scan();
        assert.deepEqual(calls.executed, [{ name: "fork_session", arguments: {} }]);
        // It sends nothing: BriefBar sends the prompt to the fork, through the fork's own extension.
        assert.deepEqual(calls.sent, []);
        assert.deepEqual(readResult(value.requestId), {
            version: 1, requestId: value.requestId, sessionId: session.sessionId, kind: "fork", ok: true,
            forkSessionId: forkId, finishedAt: iso(NOW),
        });
    });

    test("reads what the app's fork answered", () => {
        const sessionId = randomUUID();
        const fork = "A658C14C-BCA0-4F25-996E-2F9F95A4955E";
        // As GitHub Copilot 1.1.34 answers.
        const answer = {
            textResultForLlm: `Forked session into new workspace 'Work fork' (workspace_id: f35b5da0-6892-42f8-a53a-530369e1322a, session_id: ${fork}). The user can switch to it from the sidebar. Link to it with ghapp://sessions/f35b5da0-6892-42f8-a53a-530369e1322a.`,
            resultType: "success",
            sessionLog: "Forked session.",
            toolTelemetry: {},
        };
        assert.deepEqual(forked(answer, sessionId), { ok: true, kind: "fork", forkSessionId: fork.toLowerCase() });
        assert.deepEqual(forked(answer.textResultForLlm, sessionId), { ok: true, kind: "fork", forkSessionId: fork.toLowerCase() });
        // The fork's name is the session's, which you choose, and comes before its ID.
        for (const named of [randomUUID(), sessionId]) {
            const text = answer.textResultForLlm.replace("'Work fork'", `'Ask about session_id: ${named} fork'`);
            assert.deepEqual(forked({ ...answer, textResultForLlm: text }, sessionId), {
                ok: true, kind: "fork", forkSessionId: fork.toLowerCase(),
            });
        }

        const code = (value) => forked(value, sessionId).error?.code;
        assert.equal(code({ resultType: "success", textResultForLlm: "Forked." }), "fork_failed");
        assert.equal(code({ resultType: "success", textResultForLlm: `session_id: ${sessionId}` }), "fork_failed");
        assert.equal(code({ resultType: "failure", error: "The worktree couldn't be made." }), "fork_failed");
        assert.equal(code({ resultType: "timeout", error: "Timed out." }), "fork_failed");
        assert.equal(code(null), "fork_failed");
        // As the runtime answers in a session without the app's tools, such as a chat or the Copilot CLI's.
        assert.equal(code({
            textResultForLlm: "Tool 'fork_session' does not exist. Available tools that can be called are .",
            resultType: "failure",
            error: "Tool 'fork_session' does not exist.",
        }), "fork_unavailable");
        assert.equal(code({ resultType: "rejected", textResultForLlm: "Rejected." }), "fork_unavailable");
        assert.equal(code({ resultType: "denied", textResultForLlm: "Denied." }), "fork_unavailable");
        assert.equal(
            forked({ resultType: "failure", error: `It\u001b[31m failed\n${"x".repeat(500)}` }, sessionId).error.message.length,
            200,
        );
    });

    test("says when the session can't run the app's fork", async () => {
        const { session } = fakeSession(undefined, {
            execute() {
                throw Object.assign(new Error("Unhandled method session.tools.execute"), { code: -32601 });
            },
        });
        const outbox = listenTo(session);
        const value = request(session.sessionId, { kind: "fork" });
        writeRequest(value);
        await outbox.scan();
        const result = readResult(value.requestId);
        assert.equal(result.error.code, "fork_unavailable");
        assert.match(result.error.message, /Unhandled method/);
        assert.equal(result.forkSessionId, undefined);
    });

    test("says a fork may have been made when the call fails any other way", async () => {
        for (const error of [
            Object.assign(new Error("Pending response rejected since connection got disposed"), { code: -32097 }),
            Object.assign(new Error("Request session.tools.execute failed."), { code: -32603 }),
            new Error("The connection closed."),
            "Thrown as text.",
        ]) {
            const { session } = fakeSession(undefined, {
                execute() {
                    throw error;
                },
            });
            const outbox = listenTo(session);
            const value = request(session.sessionId, { kind: "fork" });
            writeRequest(value);
            await outbox.scan();
            const result = readResult(value.requestId);
            assert.equal(result.ok, false);
            assert.equal(result.kind, "fork");
            assert.equal(result.error.code, "fork_failed", String(error?.message ?? error));
            assert.equal(result.forkSessionId, undefined);
            outbox.stop();
        }
    });

    test("says how a slow fork went once it's done, and nothing before", async () => {
        let finish;
        const forkId = randomUUID();
        const { session } = fakeSession(undefined, { execute: () => new Promise((resolve) => { finish = resolve; }) });
        const outbox = listenTo(session);
        const value = request(session.sessionId, { kind: "fork" });
        writeRequest(value);
        const scanning = outbox.scan();
        await waitFor(() => finish, "the fork");
        await new Promise((resolve) => setTimeout(resolve, 100));
        assert.equal(readResult(value.requestId), undefined);
        finish({ resultType: "success", textResultForLlm: `Forked session (workspace_id: ${randomUUID()}, session_id: ${forkId}).` });
        await scanning;
        assert.equal(readResult(value.requestId).forkSessionId, forkId);
    });
});

describe("cleaning up and recovering", () => {
    test("removes what an extension of its session left when it ended mid-request", () => {
        const { session } = fakeSession();
        fs.mkdirSync(path.join(folder, "requests"), { recursive: true, mode: 0o700 });
        fs.mkdirSync(path.join(folder, "results"), { mode: 0o700 });
        for (const dir of [path.dirname(folder), folder]) fs.chmodSync(dir, 0o700);
        const claimed = (sessionId, pid) => {
            const file = path.join(folder, "requests", `.${sessionId}.${randomUUID()}.claimed-${pid}`);
            fs.writeFileSync(file, JSON.stringify(request(sessionId)), { mode: 0o600 });
            return file;
        };
        const deadOne = claimed(session.sessionId, 101);
        const liveOne = claimed(session.sessionId, 102);
        const anotherSessions = claimed(randomUUID(), 101);
        const temporary = path.join(folder, "results", `.${randomUUID()}.json.101.${randomUUID()}.tmp`);
        fs.writeFileSync(temporary, "{}", { mode: 0o600 });
        fs.mkdirSync(path.join(folder, "reports"), { mode: 0o700 });
        const reportLeft = path.join(folder, "reports", `.${randomUUID()}.json.101.${randomUUID()}.tmp`);
        const reportBeingWritten = path.join(folder, "reports", `.${randomUUID()}.json.102.${randomUUID()}.tmp`);
        for (const file of [reportLeft, reportBeingWritten]) fs.writeFileSync(file, "{}", { mode: 0o600 });
        listenTo(session, { isRunning: (pid) => pid === 102 });
        assert.ok(!fs.existsSync(deadOne), "its own, from a process that's gone");
        assert.ok(!fs.existsSync(temporary));
        assert.ok(!fs.existsSync(reportLeft));
        assert.ok(fs.existsSync(reportBeingWritten), "a report another process still writes");
        assert.ok(fs.existsSync(liveOne), "one that's still being handled");
        assert.ok(fs.existsSync(anotherSessions), "another session's");
    });

    test("sets the outbox up again when its requests folder goes, and still takes requests", async () => {
        const { session, calls } = fakeSession();
        const outbox = listenTo(session);
        fs.rmSync(path.join(folder, "requests"), { recursive: true });
        fs.rmSync(path.join(folder, "listening"), { recursive: true });
        await outbox.scan();
        assert.equal(fs.lstatSync(path.join(folder, "requests")).mode & 0o777, 0o700);
        assert.ok(fs.existsSync(path.join(folder, "listening", `${session.sessionId}.json`)));
        const value = request(session.sessionId);
        writeRequest(value);
        await outbox.scan();
        assert.equal(readResult(value.requestId).ok, true);
        assert.equal(calls.sent.length, 1);
    });

    test("still handles one request at a time when a scan starts by setting the outbox up again", async () => {
        const answers = [];
        const { session, calls } = fakeSession(undefined, { send: () => new Promise((resolve) => answers.push(resolve)) });
        const outbox = listenTo(session);
        await outbox.scan();
        // Made again, so the next scan finds a requests folder that isn't the one it watches, and sets it up first.
        fs.rmSync(path.join(folder, "requests"), { recursive: true });
        fs.mkdirSync(path.join(folder, "requests"), { mode: 0o700 });
        const values = [request(session.sessionId), request(session.sessionId)];
        for (const value of values) writeRequest(value);
        void outbox.scan();
        const first = await waitFor(() => answers[0], "the first send");
        // A scan asked for while it sends, as a change in the folder asks, waits for the send.
        void outbox.scan();
        await new Promise((resolve) => setTimeout(resolve, 100));
        assert.equal(calls.sent.length, 1);
        first("message-1");
        const second = await waitFor(() => answers[1], "the second send");
        assert.equal(calls.sent.length, 2);
        second("message-2");
        for (const value of values) assert.equal((await waitFor(() => readResult(value.requestId), "a result")).ok, true);
    });
});

describe("its outbox's path", () => {
    test("stops using the outbox when a folder it's in becomes a link, even one to where it was", async () => {
        const { session, calls } = fakeSession();
        const home = path.dirname(folder);
        const outbox = path.join(home, "Library", "BriefBar", "Outbox");
        const listening = listenTo(session, { folder: outbox, root: home });
        const moved = path.join(home, "Moved");
        fs.renameSync(path.join(home, "Library", "BriefBar"), moved);
        fs.symlinkSync(moved, path.join(home, "Library", "BriefBar"));
        const value = request(session.sessionId);
        const file = path.join(moved, "Outbox", "requests", `${session.sessionId}.${value.requestId}.json`);
        fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
        await listening.scan();
        assert.deepEqual(calls, { sent: [], executed: [] });
        assert.ok(fs.existsSync(file));
        assert.deepEqual(fs.readdirSync(path.join(moved, "Outbox", "results")), []);
    });
});

describe("its process", () => {
    function fakeProcess() {
        const proc = new EventEmitter();
        proc.stdin = new EventEmitter();
        proc.exits = [];
        proc.exit = (code) => proc.exits.push(code);
        proc.written = [];
        proc.stderr = { write: (text) => proc.written.push(text) };
        return proc;
    }

    for (const [what, end] of [
        ["when the runtime stops it", (proc) => proc.emit("SIGTERM")],
        ["when its runtime is gone without a word", (proc) => proc.stdin.emit("end")],
    ]) {
        test(`stops and says so ${what}`, () => {
            const { session } = fakeSession();
            const proc = fakeProcess();
            const outbox = listenTo(session);
            stopWithTheSession(outbox, proc);
            end(proc);
            assert.ok(outbox.isStopped);
            assert.deepEqual(proc.exits, [0]);
            assert.deepEqual(fs.readdirSync(path.join(folder, "listening")), []);
        });
    }

    test("starts listening, and stops with the session", () => {
        const { session } = fakeSession();
        const proc = fakeProcess();
        const outbox = start(session, { proc, folder, isRunning: () => true });
        open.push(outbox);
        assert.ok(fs.existsSync(path.join(folder, "listening", `${session.sessionId}.json`)));
        proc.emit("SIGHUP");
        assert.deepEqual(proc.exits, [0]);
        assert.ok(outbox.isStopped);
    });

    test("ends, saying why in a line, when the outbox can't be used", () => {
        const { session } = fakeSession();
        const proc = fakeProcess();
        fs.mkdirSync(folder, { recursive: true, mode: 0o755 });
        fs.chmodSync(folder, 0o755);
        assert.equal(start(session, { proc, folder }), undefined);
        assert.deepEqual(proc.exits, [0]);
        assert.equal(proc.written.length, 1);
        assert.match(proc.written[0], /^BriefBar's outbox can't be used, .*: Outbox isn't private to you\.\n$/);
        assert.ok(!proc.written[0].includes(session.sessionId));
    });
});
