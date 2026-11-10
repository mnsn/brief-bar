// BriefBar's outbox, as the extension in one of the GitHub Copilot app's sessions reads it. BriefBar writes a request
// for a session; the extension in that session claims it, sends the session its prompt, forks the session or stops its
// turn, and writes the result; for a send BriefBar asks it to report, it then says how the message's turn goes, in a
// report it rewrites until the turn ends (./turn.mjs). It's files in a private folder on this Mac, and nothing else: no
// network, no sockets. The extension never logs, echoes or keeps a prompt: it only hands it to session.send.
// docs/how-it-works.md describes the files under "Send work to Copilot" (Sending to a session, or a fork of it), and the
// extension under "Its extension for the app's sessions".
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { beginning, followTurn, line } from "./turn.mjs";

export const VERSION = 1;
/** What the extension does when BriefBar asks. */
export const KINDS = Object.freeze(["send", "fork", "stop"]);
/** The largest request it reads. */
export const MOST_BYTES = 256 * 1024;
/** How long a request may wait to be claimed, at most. */
export const LONGEST_WAIT_MS = 120 * 1000;
/** How far ahead of this clock a request may say it was made, for clocks a moment apart. */
export const CLOCK_SLACK_MS = 5 * 1000;
/** The longest error message a result carries. */
export const LONGEST_MESSAGE = 200;
/** How often a report says the step a turn is at, at most: what it is, and how the turn stands, it says at once. */
export const STEP_EVERY_MS = 1000;
/** How long a report waits for the session's name, at most. */
export const NAME_WAIT_MS = 2000;
/** How long a report that couldn't be written waits to be written again. */
export const REWRITE_AFTER_MS = 5000;

const UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const UUID = new RegExp(`^${UUID_PATTERN}$`);
const REQUEST_NAME = new RegExp(`^(${UUID_PATTERN})\\.(${UUID_PATTERN})\\.json$`);
const CLAIMED_NAME = new RegExp(`^\\.(${UUID_PATTERN})\\.(${UUID_PATTERN})\\.claimed-(\\d+)$`);
const TEMPORARY_NAME = new RegExp(`^\\..+\\.(\\d+)\\.${UUID_PATTERN}\\.tmp$`);
const ISO_8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;
// The app's fork_session answers "Forked session into new workspace '…' (workspace_id: …, session_id: <id>). …". The
// workspace's name is the session's, which you choose, so it may hold one too: the fork's is the last.
const FORK_SESSION_ID = new RegExp(`\\bsession_id: (${UUID_PATTERN})\\b`, "gi");
// What the runtime answers for a tool the session doesn't offer, such as fork_session in a chat or in the Copilot CLI.
const MISSING_TOOL = /\bTool 'fork_session' does not exist\b/;
// JSON-RPC's code for a method the other end doesn't have, as a runtime without `tools.execute` answers.
const METHOD_NOT_FOUND = -32601;
const LONGEST_RETRY_MS = 5 * 60 * 1000;

/** Why the outbox can't be used, such as a folder that isn't private to you. */
export class OutboxError extends Error {}

/** Why a request was turned down: its result's error code and message, and its kind if it had a valid one. */
class Refusal extends Error {
    constructor(code, message, kind) {
        super(message);
        this.code = code;
        this.kind = kind;
    }
}

/** Where BriefBar keeps the outbox. */
export function defaultFolder(home = os.homedir()) {
    return path.join(home, "Library", "Application Support", "BriefBar", "Copilot", "Outbox");
}

/** Whether a process with this ID runs: one of another user's counts, since it can't be signaled. */
export function isRunning(pid) {
    try {
        process.kill(pid, 0);
        return true;
    } catch (error) {
        return error.code === "EPERM";
    }
}

/** Joins the outbox for this session, and starts acting on its requests; stops along with the extension's process. */
export function start(session, { proc = process, ...options } = {}) {
    let outbox;
    try {
        outbox = listen(session, options);
    } catch (error) {
        const why = error instanceof OutboxError ? error.message : String(error?.code ?? error?.name ?? "an error");
        proc.stderr.write(`BriefBar's outbox can't be used, so this session takes no prompts from BriefBar: ${why}\n`);
        proc.exit(0);
        return undefined;
    }
    stopWithTheSession(outbox, proc);
    return outbox;
}

/** Stops the outbox when the runtime stops the extension, or goes away without saying so, as when it crashes: then
 * its connection ends, and a process left running would keep its listening file live for nothing. */
export function stopWithTheSession(outbox, proc = process) {
    const finish = () => {
        outbox.stop();
        proc.exit(0);
    };
    for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) proc.once(signal, finish);
    proc.stdin?.once("end", finish);
    proc.stdin?.once("close", finish);
    proc.once("exit", () => outbox.stop());
}

/**
 * Says that this session listens, in `listening/<sessionId>.json`, then acts on each request BriefBar writes for it
 * in `requests/`, as it arrives (fs.watch) and any that were already there: one at a time, oldest first. Each says
 * how it went once it's done, however long that takes: one that's still going when BriefBar stops waiting may still
 * reach the session, which BriefBar says, so it never says it failed when it can't know. A send that asks for a report
 * says how its message's turn goes in `reports/<requestId>.json`, written before its result and rewritten as the turn
 * goes, until it ends, the extension stops, or BriefBar removes it: meanwhile, it takes other requests, such as a stop.
 *
 * Options, for tests: `folder`, the outbox, and `root`, the folder it's in that's trusted as it is, below which no
 * folder is followed through a link, as BriefBar follows none (by default, your home folder, or `folder`'s own when
 * that's given); `pid`, `uid` and `startedAt` (ms), this process's; `now()`, the time in ms; and `isRunning(pid)`.
 */
export function listen(session, options = {}) {
    const sessionId = typeof session?.sessionId === "string" ? session.sessionId.toLowerCase() : "";
    if (!UUID.test(sessionId)) throw new OutboxError("This session's ID isn't a UUID.");
    const outbox = options.folder ?? defaultFolder();
    const folders = {
        root: options.root ?? (options.folder ? path.dirname(options.folder) : os.homedir()),
        outbox,
        requests: path.join(outbox, "requests"),
        results: path.join(outbox, "results"),
        listening: path.join(outbox, "listening"),
        reports: path.join(outbox, "reports"),
    };
    const pid = options.pid ?? process.pid;
    const uid = options.uid ?? process.getuid();
    const now = options.now ?? (() => Date.now());
    const running = options.isRunning ?? isRunning;
    const announcement = {
        version: VERSION,
        sessionId,
        pid,
        startedAt: new Date(options.startedAt ?? performance.timeOrigin).toISOString(),
        kinds: [...KINDS],
    };
    const announced = path.join(folders.listening, `${sessionId}.json`);

    let watcher = null;
    // The requests folder that's watched, by its device and inode, so that one put in its place is noticed.
    let watched = null;
    let retry = null;
    let retryDelay = 1000;
    // When the outbox was last set up again, by this process's clock, so that a folder that keeps going can't make it
    // set it up over and over: within a second, it waits, longer each time.
    let recoveredAt = -Infinity;
    let stopped = false;
    let scanning = null;
    let again = false;
    // The turns of the sends it reports, by their request's ID, until each ends.
    const followers = new Map();

    function setUp() {
        prepare(folders, uid);
        cleanUp();
        watcher?.close();
        watcher = fs.watch(folders.requests, () => void scan());
        watcher.on("error", () => recover());
        const stat = fs.lstatSync(folders.requests);
        watched = { dev: stat.dev, ino: stat.ino };
        writeFile(folders.listening, `${sessionId}.json`, announcement, pid);
        retryDelay = 1000;
    }

    /** Sets the outbox up again, as when its requests folder was removed: now, or later and later until it can. */
    function recover() {
        if (stopped) return;
        watcher?.close();
        watcher = null;
        watched = null;
        clearTimeout(retry);
        retry = null;
        if (performance.now() - recoveredAt >= 1000) {
            recoveredAt = performance.now();
            try {
                setUp();
                void scan();
                return;
            } catch {
                // Tried again below.
            }
        }
        retry = setTimeout(recover, retryDelay);
        retry.unref?.();
        retryDelay = Math.min(retryDelay * 2, LONGEST_RETRY_MS);
    }

    /** Removes what this session's extensions left when they ended mid-request: the requests they had claimed, which
     * hold prompts, and their temporary files. */
    function cleanUp() {
        for (const name of names(folders.requests)) {
            const match = CLAIMED_NAME.exec(name);
            if (!match || match[1] !== sessionId) continue;
            const owner = Number(match[3]);
            if (owner !== pid && !running(owner)) removeOwnFile(path.join(folders.requests, name), uid);
        }
        for (const folder of [folders.results, folders.listening, folders.reports]) {
            for (const name of names(folder)) {
                const match = TEMPORARY_NAME.exec(name);
                if (!match) continue;
                const owner = Number(match[1]);
                if (owner !== pid && !running(owner)) removeOwnFile(path.join(folder, name), uid);
            }
        }
    }

    function scan() {
        if (stopped) return Promise.resolve();
        if (scanning) {
            again = true;
            return scanning;
        }
        scanning = (async () => {
            // Only once `scanning` holds this scan, so that one its first steps ask for, as setting the outbox up again
            // does, waits for it rather than running beside it.
            await null;
            try {
                do {
                    again = false;
                    try {
                        await scanOnce();
                    } catch {
                        // A request that can't be handled is left for BriefBar, which withdraws it.
                    }
                } while (again && !stopped);
            } finally {
                scanning = null;
            }
        })();
        return scanning;
    }

    async function scanOnce() {
        if (!isIntact()) {
            recover();
            return;
        }
        let entries;
        try {
            entries = await fsp.readdir(folders.requests);
        } catch {
            recover();
            return;
        }
        const waiting = [];
        for (const name of entries) {
            const match = REQUEST_NAME.exec(name);
            if (!match || match[1] !== sessionId) continue;
            const entry = await fsp.lstat(path.join(folders.requests, name)).catch(() => null);
            if (!entry || !(entry.isFile() || entry.isSymbolicLink())) continue;
            waiting.push({ name, requestId: match[2], made: entry.mtimeMs });
        }
        waiting.sort((a, b) => a.made - b.made || (a.name < b.name ? -1 : 1));
        for (const request of waiting) {
            if (stopped) return;
            if (!isIntact()) {
                recover();
                return;
            }
            await handle(request);
        }
    }

    /** The outbox is still as it was set up: its folders, and those it's in below `root`, are real ones, none of them a
     * link, its own are private to you, and its requests folder is the one watched. Node can't anchor what it opens to a
     * folder it checked, so it's checked again before each use, as one could be swapped for a link to it meanwhile. */
    function isIntact() {
        try {
            checkPath(folders, uid);
            const stat = fs.lstatSync(folders.requests);
            return watched !== null && stat.dev === watched.dev && stat.ino === watched.ino;
        } catch {
            return false;
        }
    }

    async function handle({ name, requestId }) {
        // Claimed by renaming it, so that each request is handled once, by one extension, and BriefBar knows it can't
        // withdraw it anymore.
        const claimed = path.join(folders.requests, `.${sessionId}.${requestId}.claimed-${pid}`);
        try {
            await fsp.rename(path.join(folders.requests, name), claimed);
        } catch {
            return;
        }
        let outcome;
        try {
            const request = checkRequest(parse(await readRequest(claimed, uid)), { requestId, sessionId, now: now() });
            outcome = await carryOut(request, requestId, claimed);
        } catch (error) {
            outcome = error instanceof Refusal
                ? failed(error.code, error.message, error.kind)
                : failed("invalid", "The request couldn't be read.");
        }
        try {
            checkPath(folders, uid);
            writeFile(folders.results, `${requestId}.json`, result(outcome, requestId), pid);
        } catch {
            // BriefBar stops waiting for it, and falls back to copying the prompt.
        }
        await fsp.rm(claimed, { force: true }).catch(() => {});
    }

    async function carryOut(request, requestId, claimed) {
        if (request.kind === "stop") {
            // As the app's own Stop: the turn that runs in the session now ends, and the session goes on as it was.
            try {
                await session.abort();
            } catch {
                return failed("stop_failed", "Copilot didn't stop the session's turn.", "stop");
            }
            return { ok: true, kind: "stop" };
        }
        if (request.kind === "send") return send(request, requestId, claimed);
        let answer;
        try {
            answer = await session.rpc.tools.execute({ name: "fork_session", arguments: {} });
        } catch (error) {
            // Only a runtime without the method surely didn't fork. Another error, such as the connection closing
            // while the fork ran, can come after the fork was made.
            return error?.code === METHOD_NOT_FOUND
                ? failed("fork_unavailable", because("Copilot didn't let this session fork", error?.message), "fork")
                : failed("fork_failed", because("Copilot didn't say how the fork went", error?.message), "fork");
        }
        return forked(answer, sessionId);
    }

    function result(outcome, requestId) {
        return {
            version: VERSION,
            requestId,
            sessionId,
            ...(outcome.kind ? { kind: outcome.kind } : {}),
            ok: outcome.ok,
            ...(outcome.messageId ? { messageId: outcome.messageId } : {}),
            ...(outcome.reports ? { reports: true } : {}),
            ...(outcome.forkSessionId ? { forkSessionId: outcome.forkSessionId } : {}),
            ...(outcome.ok ? {} : { error: outcome.error }),
            finishedAt: new Date(now()).toISOString(),
        };
    }

    /** Sends the session the prompt, as your own message. Asked to report, it follows the message's turn from the
     * session's events, which it hears from before it sends it, and says it does once its first report is written.
     * @param claimed the request, as it was claimed: while it's there, BriefBar still wants its turn reported. */
    async function send(request, requestId, claimed) {
        let follower = null;
        if (request.report && typeof session.on === "function") {
            follower = {
                requestId,
                claimed,
                turn: followTurn({ sentAt: new Date(now()).toISOString() }),
                reporting: false,
                written: false,
                timer: null,
                writtenAt: -Infinity,
            };
            try {
                follower.unsubscribe = session.on((event) => heard(follower, event));
            } catch {
                follower = null;
            }
        }
        let messageId;
        try {
            messageId = await session.send({ prompt: request.prompt });
        } catch {
            if (follower) quiet(follower);
            return failed("send_failed", "Copilot didn't take the prompt.", "send");
        }
        const outcome = { ok: true, kind: "send", ...(typeof messageId === "string" ? { messageId } : {}) };
        if (follower) {
            if (typeof messageId === "string" && messageId !== "" && !stopped) {
                outcome.reports = await report(follower, messageId);
            } else {
                quiet(follower);
            }
        }
        return outcome;
    }

    /** Starts reporting a send's turn, now that its message's ID is known: true once its first report is written. */
    async function report(follower, messageId) {
        follower.messageId = messageId;
        follower.turn.begin(messageId);
        follower.name = await sessionName();
        if (stopped) {
            quiet(follower);
            return false;
        }
        followers.set(follower.requestId, follower);
        follower.reporting = true;
        if (!isWanted(follower) || !writeReport(follower)) {
            quiet(follower);
            return false;
        }
        if (follower.turn.isOver) quiet(follower);
        return true;
    }

    /** Whether BriefBar still wants a turn reported: until its first report is written, while the request it came in is
     * still there; then while that report is. BriefBar removes them once it no longer follows the turn, as when it took
     * how it ended, and every one as Azure DevOps is turned off, which forgets them (`CopilotOutbox.forget`). */
    function isWanted(follower) {
        const file = follower.written ? path.join(folders.reports, `${follower.requestId}.json`) : follower.claimed;
        try {
            return fs.lstatSync(file).isFile();
        } catch {
            return false;
        }
    }

    /** What the session said happened, for a turn it reports: how the turn stands now goes in its report at once, but
     * the step it's at at most every `STEP_EVERY_MS`. As it starts waiting on you, the session's name is read again
     * after, in case it was renamed meanwhile; an end is written at once, as the extension may be about to stop. */
    function heard(follower, event) {
        let change;
        try {
            change = follower.turn.observe(event);
        } catch {
            return;
        }
        if (change === "none" || !follower.reporting) return;
        if (change === "step") {
            const wait = follower.writtenAt + STEP_EVERY_MS - performance.now();
            if (wait > 0) {
                if (!follower.timer) {
                    follower.timer = setTimeout(() => rewrite(follower), wait);
                    follower.timer.unref?.();
                }
                return;
            }
        }
        rewrite(follower);
        if (follower.reporting && follower.turn.report.state === "needsYou") {
            const asked = follower.turn.report.since;
            void sessionName().then((name) => {
                if (!name || name === follower.name) return;
                follower.name = name;
                if (follower.turn.report.since === asked) rewrite(follower);
            });
        }
    }

    /** Writes a turn's report as it stands now: then, once it's over, stops following it. One that can't be written is
     * written again a little later, while the turn is followed. One whose report BriefBar removed, it stops following,
     * writing nothing more: the session's turn goes on. */
    function rewrite(follower) {
        if (!followers.has(follower.requestId)) return;
        clearTimeout(follower.timer);
        follower.timer = null;
        if (!isWanted(follower)) {
            quiet(follower);
            return;
        }
        if (!writeReport(follower)) {
            follower.timer = setTimeout(() => rewrite(follower), REWRITE_AFTER_MS);
            follower.timer.unref?.();
            return;
        }
        if (follower.turn.isOver) quiet(follower);
    }

    function writeReport(follower) {
        const turn = follower.turn.report;
        const value = {
            version: VERSION,
            requestId: follower.requestId,
            sessionId,
            messageId: follower.messageId,
            pid,
            startedAt: announcement.startedAt,
            ...(follower.name ? { name: follower.name } : {}),
            state: turn.state,
            since: turn.since,
            ...(turn.step ? { step: turn.step } : {}),
            ...(turn.asks ? { asks: turn.asks } : {}),
            ...(turn.said ? { said: turn.said } : {}),
            ...(turn.cause ? { cause: turn.cause } : {}),
            updatedAt: new Date(now()).toISOString(),
        };
        try {
            checkPath(folders, uid);
            writeFile(folders.reports, `${follower.requestId}.json`, value, pid);
        } catch {
            return false;
        }
        follower.written = true;
        follower.writtenAt = performance.now();
        return true;
    }

    /** Stops following a turn: what it last said stays in its report, for BriefBar. */
    function quiet(follower) {
        clearTimeout(follower.timer);
        follower.timer = null;
        follower.reporting = false;
        followers.delete(follower.requestId);
        try {
            follower.unsubscribe?.();
        } catch {
            // The session is gone already.
        }
    }

    /** The session's name, as the app shows it, for a report to say where the work is; undefined when it can't tell
     * in time. */
    async function sessionName() {
        let timer;
        try {
            const answer = await Promise.race([
                Promise.resolve().then(() => session.rpc.name.get()),
                new Promise((resolve) => {
                    timer = setTimeout(resolve, NAME_WAIT_MS);
                    timer.unref?.();
                }),
            ]);
            return line(answer?.name);
        } catch {
            return undefined;
        } finally {
            clearTimeout(timer);
        }
    }

    /** Stops listening, and says so: removes its listening file, unless another extension in the session wrote its
     * own since. The turns it reports, it stops following: what each last said stays in its report. */
    function stop() {
        if (stopped) return;
        stopped = true;
        clearTimeout(retry);
        watcher?.close();
        watcher = null;
        for (const follower of [...followers.values()]) quiet(follower);
        try {
            const stat = fs.lstatSync(announced);
            if (!stat.isFile() || stat.size > 4096) return;
            const current = JSON.parse(fs.readFileSync(announced, "utf8"));
            if (current?.pid === pid && current?.startedAt === announcement.startedAt) fs.rmSync(announced, { force: true });
        } catch {
            // It's gone already, or another's.
        }
    }

    try {
        setUp();
    } catch (error) {
        watcher?.close();
        throw error instanceof OutboxError ? error : new OutboxError(`It couldn't be set up (${error?.code ?? error?.name}).`);
    }
    void scan();
    return {
        sessionId,
        folders,
        scan,
        stop,
        get isStopped() {
            return stopped;
        },
    };
}

/** Makes the outbox's folders that are missing, private to you, each checked before the next is made in it: the folders
 * it's in below `root` must be real ones, not links, and the outbox and its own folders real ones of yours that only
 * you can use (0700), as BriefBar checks them. */
function prepare(folders, uid) {
    for (const parent of parents(folders)) {
        makeFolder(parent, uid);
        checkParent(parent);
    }
    for (const folder of ownFolders(folders)) {
        makeFolder(folder, uid);
        checkFolder(folder, uid);
    }
}

/** What `prepare` checks, without making anything. */
function checkPath(folders, uid) {
    for (const parent of parents(folders)) checkParent(parent);
    for (const folder of ownFolders(folders)) checkFolder(folder, uid);
}

/** The outbox, and its own folders. */
function ownFolders(folders) {
    return [folders.outbox, folders.requests, folders.results, folders.listening, folders.reports];
}

/** The folders the outbox is in, below `root`, from the outermost. */
function parents(folders) {
    const relative = path.relative(folders.root, path.dirname(folders.outbox));
    if (relative.startsWith("..") || path.isAbsolute(relative)) throw new OutboxError("It isn't in its folder.");
    const found = [];
    let parent = folders.root;
    for (const name of relative.split(path.sep).filter(Boolean)) {
        parent = path.join(parent, name);
        found.push(parent);
    }
    return found;
}

function checkParent(folder) {
    let stat;
    try {
        stat = fs.lstatSync(folder);
    } catch (error) {
        throw new OutboxError(`${path.basename(folder)} can't be read (${error.code ?? error.name}).`);
    }
    if (!stat.isDirectory()) throw new OutboxError(`${path.basename(folder)} isn't a folder.`);
}

/** Makes a folder that's missing, private to you, whatever the umask. One that's there stays as it is. */
function makeFolder(folder, uid) {
    try {
        fs.mkdirSync(folder, { mode: 0o700 });
        const made = fs.lstatSync(folder);
        if (made.isDirectory() && made.uid === uid) fs.chmodSync(folder, 0o700);
    } catch (error) {
        if (error.code !== "EEXIST") throw new OutboxError(`${path.basename(folder)} couldn't be made (${error.code ?? error.name}).`);
    }
}

function checkFolder(folder, uid) {
    let stat;
    try {
        stat = fs.lstatSync(folder);
    } catch (error) {
        throw new OutboxError(`${path.basename(folder)} can't be read (${error.code ?? error.name}).`);
    }
    if (!stat.isDirectory()) throw new OutboxError(`${path.basename(folder)} isn't a folder.`);
    if (stat.uid !== uid) throw new OutboxError(`${path.basename(folder)} isn't yours.`);
    if ((stat.mode & 0o7777) !== 0o700) throw new OutboxError(`${path.basename(folder)} isn't private to you.`);
}

function names(folder) {
    try {
        return fs.readdirSync(folder);
    } catch {
        return [];
    }
}

function removeOwnFile(file, uid) {
    try {
        const stat = fs.lstatSync(file);
        if ((stat.isFile() || stat.isSymbolicLink()) && stat.uid === uid) fs.rmSync(file, { force: true });
    } catch {
        // Gone already.
    }
}

/** Writes one of the outbox's files whole, private to you: a temporary file first, whose name starts with a dot so
 * that it's never read as a request or a result, which then takes the file's place. */
function writeFile(folder, name, value, pid) {
    const temporary = path.join(folder, `.${name}.${pid}.${randomUUID()}.tmp`);
    const { O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW } = fs.constants;
    const fd = fs.openSync(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600);
    try {
        fs.fchmodSync(fd, 0o600);
        fs.writeFileSync(fd, `${JSON.stringify(value)}\n`);
    } finally {
        fs.closeSync(fd);
    }
    try {
        fs.renameSync(temporary, path.join(folder, name));
    } catch (error) {
        fs.rmSync(temporary, { force: true });
        throw error;
    }
}

const utf8 = new TextDecoder("utf-8", { fatal: true });

/** A claimed request's text, once it passes the file checks: a regular file of yours, private to you, of 256 KiB or
 * less. It's read without following a link, and must still be the file that was checked. */
async function readRequest(file, uid) {
    const stat = await fsp.lstat(file).catch(() => null);
    if (!stat) throw new Refusal("invalid", "The request is gone.");
    if (!stat.isFile()) throw new Refusal("invalid", "The request isn't a regular file.");
    if (stat.uid !== uid) throw new Refusal("invalid", "The request isn't yours.");
    if ((stat.mode & 0o7777) !== 0o600) throw new Refusal("invalid", "The request isn't private to you.");
    if (stat.size > MOST_BYTES) throw new Refusal("invalid", "The request is larger than 256 KiB.");
    let handle;
    try {
        handle = await fsp.open(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    } catch {
        throw new Refusal("invalid", "The request couldn't be opened.");
    }
    try {
        const opened = await handle.stat();
        if (opened.dev !== stat.dev || opened.ino !== stat.ino) throw new Refusal("invalid", "The request changed as it was read.");
        const buffer = Buffer.alloc(MOST_BYTES + 1);
        let length = 0;
        while (length < buffer.length) {
            const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
            if (bytesRead === 0) break;
            length += bytesRead;
        }
        if (length > MOST_BYTES) throw new Refusal("invalid", "The request is larger than 256 KiB.");
        try {
            return utf8.decode(buffer.subarray(0, length));
        } catch {
            throw new Refusal("invalid", "The request isn't UTF-8.");
        }
    } finally {
        await handle.close();
    }
}

function parse(text) {
    try {
        return JSON.parse(text);
    } catch {
        throw new Refusal("invalid", "The request isn't JSON.");
    }
}

/** The request, if every field is valid, it's for this session and it hasn't expired. */
export function checkRequest(value, { requestId, sessionId, now }) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        throw new Refusal("invalid", "The request isn't a JSON object.");
    }
    const kind = KINDS.includes(value.kind) ? value.kind : undefined;
    if (value.version !== VERSION) throw new Refusal("invalid", `Its version isn't ${VERSION}.`, kind);
    if (value.requestId !== requestId) throw new Refusal("invalid", "Its requestId isn't the one in its name.", kind);
    if (value.sessionId !== sessionId) throw new Refusal("invalid", "It's for another session.", kind);
    if (!kind) throw new Refusal("invalid", "Its kind isn't send, fork or stop.");
    if (kind === "send") {
        if (typeof value.prompt !== "string" || value.prompt.trim() === "") {
            throw new Refusal("invalid", "A send needs a prompt.", kind);
        }
        if (Object.hasOwn(value, "report") && typeof value.report !== "boolean") {
            throw new Refusal("invalid", "Its report isn't true or false.", kind);
        }
    } else if (Object.hasOwn(value, "prompt")) {
        throw new Refusal("invalid", `A ${kind} takes no prompt.`, kind);
    } else if (Object.hasOwn(value, "report")) {
        throw new Refusal("invalid", `A ${kind} has no report.`, kind);
    }
    const createdAt = instant(value.createdAt);
    const expiresAt = instant(value.expiresAt);
    if (createdAt === undefined || expiresAt === undefined) {
        throw new Refusal("invalid", "Its createdAt and expiresAt aren't ISO 8601 times.", kind);
    }
    if (expiresAt <= createdAt) throw new Refusal("invalid", "It expires before it was made.", kind);
    if (expiresAt - createdAt > LONGEST_WAIT_MS) throw new Refusal("invalid", "It would wait longer than 120 s.", kind);
    if (createdAt > now + CLOCK_SLACK_MS) throw new Refusal("invalid", "It's dated in the future.", kind);
    if (now >= expiresAt) throw new Refusal("expired", "It expired before it was claimed.", kind);
    return kind === "send" ? { kind, prompt: value.prompt, report: value.report === true } : { kind };
}

function instant(text) {
    if (typeof text !== "string" || !ISO_8601.test(text)) return undefined;
    const time = Date.parse(text);
    return Number.isFinite(time) ? time : undefined;
}

/** What the app's fork_session answered: the fork's session ID, or why there's none. */
export function forked(answer, sessionId) {
    const result = typeof answer === "string" ? { resultType: "success", textResultForLlm: answer } : answer;
    if (result === null || typeof result !== "object") return failed("fork_failed", "The fork gave no answer.", "fork");
    const texts = [result.textResultForLlm, result.sessionLog].filter((text) => typeof text === "string");
    const error = typeof result.error === "string" ? result.error : undefined;
    switch (result.resultType) {
        case "success": {
            const id = texts.map((text) => [...text.matchAll(FORK_SESSION_ID)].at(-1)?.[1]).find(Boolean)?.toLowerCase();
            if (!id || id === sessionId) return failed("fork_failed", "The fork gave no session ID.", "fork");
            return { ok: true, kind: "fork", forkSessionId: id };
        }
        case "rejected":
        case "denied":
            return failed("fork_unavailable", because("Copilot refused the fork", error), "fork");
        default:
            if ([error, ...texts].some((text) => text && MISSING_TOOL.test(text))) {
                return failed("fork_unavailable", "This session doesn't offer fork_session.", "fork");
            }
            return failed("fork_failed", because("The fork failed", error), "fork");
    }
}

function failed(code, message, kind) {
    return { ok: false, ...(kind ? { kind } : {}), error: { code, message: short(message) } };
}

/** A sentence, with what went wrong after it when there's something to say. Never a prompt: only a fork's errors,
 * which hold none, and the runtime's own, come here. */
function because(lead, detail) {
    const said = typeof detail === "string" ? short(detail) : "";
    return said ? `${lead}: ${said}` : `${lead}.`;
}

/** A line of text, without control characters, its spaces collapsed, cut short when it's long. */
function short(text) {
    const line = String(text).replace(/[\p{Cc}\p{Cf}]+/gu, " ").replace(/\s+/g, " ").trim();
    return line.length > LONGEST_MESSAGE ? `${beginning(line, LONGEST_MESSAGE - 1)}…` : line;
}
