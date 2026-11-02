// BriefBar's extension for the Copilot app's sessions, as the Copilot runtime starts it: with a stand-in for
// @github/copilot-sdk, whose joinSession the runtime provides. `make plugin-test` runs it, with Node's
// --experimental-vm-modules.
import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import { SourceTextModule, SyntheticModule, createContext } from "node:vm";

const folder = new URL("../../Resources/CopilotPlugin/briefbar-sessions/com.github.copilot/extensions/briefbar-sessions/", import.meta.url);
const read = (name) => fs.readFileSync(new URL(name, folder), "utf8");

/** Runs extension.mjs with a joinSession and an outbox that only record what they're given. */
async function runExtension() {
    const calls = { joined: [], started: [] };
    const session = { sessionId: "8e9a5f4e-2b1c-4d3a-9f8e-7c6b5a4d3e2f" };
    const context = createContext({});
    const sdk = new SyntheticModule(["joinSession"], function () {
        this.setExport("joinSession", async (...config) => {
            calls.joined.push(config);
            return session;
        });
    }, { context });
    const outbox = new SyntheticModule(["start"], function () {
        this.setExport("start", (joined) => {
            calls.started.push(joined);
            return { stop() {} };
        });
    }, { context });
    const module = new SourceTextModule(read("extension.mjs"), { context });
    await module.link((specifier) => {
        if (specifier === "@github/copilot-sdk/extension") return sdk;
        if (specifier === "./outbox.mjs") return outbox;
        throw new Error(`Unexpected import: ${specifier}`);
    });
    await module.evaluate();
    return { calls, session };
}

test("joins its session with nothing of its own, and listens there", async () => {
    const { calls, session } = await runExtension();
    // No tools, hooks, commands, canvases or anything else for the agent: joinSession's defaults.
    assert.deepEqual(calls.joined, [[]]);
    assert.deepEqual(calls.started, [session]);
});

test("uses only this Mac's files: no network, and no other programs", () => {
    const extension = read("extension.mjs");
    const outbox = read("outbox.mjs");
    const imports = (source) => [...source.matchAll(/^import\s.*?from\s+"([^"]+)";/gms)].map((match) => match[1]);
    assert.deepEqual(imports(extension), ["@github/copilot-sdk/extension", "./outbox.mjs"]);
    assert.deepEqual(imports(outbox), ["node:fs", "node:fs/promises", "node:os", "node:path", "node:crypto"]);
    for (const source of [extension, outbox]) {
        assert.doesNotMatch(source, /\bimport\s*\(|\brequire\s*\(|\bfetch\s*\(|WebSocket|child_process|node:net|node:http/);
    }
    // And no logging, which could carry a prompt: only the one line saying the outbox can't be used.
    assert.doesNotMatch(outbox, /console\.|session\.log\(/);
    assert.equal(outbox.match(/stderr\.write\(/g)?.length, 1);
});

test("is the extension its plugin declares", () => {
    const manifest = JSON.parse(fs.readFileSync(new URL("../../../plugin.json", folder), "utf8"));
    assert.equal(manifest.name, "briefbar-sessions");
    assert.deepEqual(manifest.extensions, { "com.github.copilot": {} });
    assert.deepEqual(fs.readdirSync(folder).sort(), ["extension.mjs", "outbox.mjs"]);
});
