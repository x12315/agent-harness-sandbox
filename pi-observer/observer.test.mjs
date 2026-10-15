import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { stripTypeScriptTypes } from "node:module";
import { setImmediate } from "node:timers/promises";
import { runInNewContext } from "node:vm";
import { test } from "node:test";

const source = stripTypeScriptTypes(readFileSync(new URL("observer.ts", import.meta.url), "utf8"))
	.replace(/^import .*;\n/gm, "").replace("export default function", "function observer") + "\nobserver;";

function fixture(deferred = false, interval = "1") {
	const files = new Map(), timers = new Map(), requests = [];
	let now = Date.now(), counter = 0;
	class Clock extends Date {
		constructor(...args) { super(...(args.length ? args : [now])); }
		static now() { return now; }
	}
	const fs = { promises: {
		mkdir: async () => {},
		writeFile: async (name, value) => files.set(name, value),
		rename: async (from, to) => { files.set(to, files.get(from)); files.delete(from); },
		rm: async (name) => files.delete(name),
		readdir: async () => [...files.keys()].map((name) => path.basename(name)),
		readFile: async (name) => { if (!files.has(name)) throw Error("missing fixture file"); return files.get(name); },
	} };
	const observer = runInNewContext(source, { fs, path, Date: Clock, AbortController,
		process: { pid: 42, env: { PI_OBSERVER_INTERVAL_MINUTES: interval } },
		getAgentDir: () => "/guest/agent", uuidv7: () => `summary-${++counter}`,
		setInterval: (callback, ms) => { const timer = { callback, ms }; timers.set(timer, timer); return timer; },
		clearInterval: (timer) => timers.delete(timer),
		setTimeout: (callback, ms) => { const timer = { callback, ms }; timers.set(timer, timer); return timer; },
		clearTimeout: (timer) => timers.delete(timer),
	});
	const flush = async () => { for (let i = 0; i < 8; i++) await setImmediate(); };
	const make = (initialId) => {
		let id = initialId;
		let valid = true;
		const events = new Map(), commands = new Map();
		observer({
			on: (name, callback) => {
				assert.ok(!["context", "input", "before_agent_start", "tool_call"].includes(name), "no model-loop interception");
				events.set(name, callback);
			},
			registerCommand: (name, command) => commands.set(name, command),
		});
		const ctx = Object.freeze({ cwd: `/guest/${initialId}`, model: { id: "fixture" },
			sessionManager: { getSessionId: () => { if (!valid) throw Error("stale ctx"); return id; }, getSessionFile: () => `/guest/${id}.jsonl` },
			ui: { notify: () => {} }, modelRegistry: {
				complete: async (model, context, options) => {
					requests.push({ model, context, options });
					if (deferred) return new Promise((_resolve, reject) => options.signal.addEventListener("abort", () => reject(Error("aborted")), { once: true }));
					return { content: [{ type: "text", text: "Pi is thinking." }] };
				},
			},
		});
		return {
			invalidate: () => { valid = false; },
			start: async () => { events.get("session_start")({}, ctx); await flush(); },
			emit: async (name, event = {}) => { await events.get(name)(event, ctx); await flush(); },
			command: async (args) => { await commands.get("observer").handler(args, ctx); await flush(); },
			switch: async (next, event) => { id = next; await events.get(event)({}, ctx); await flush(); },
		};
	};
	return { files, timers, requests, make, flush,
		advance: (ms) => { now += ms; },
		tick: async (ms) => { for (const timer of [...timers.values()]) if (timer.ms === ms) timer.callback(); await flush(); },
		snapshots: () => [...files].filter(([name]) => name.endsWith(".snapshot.json")).map(([, value]) => JSON.parse(value)),
	};
}

test("automatic off survives agent runs; on/manual summaries stay isolated; session transitions and shutdown clean up", async () => {
	const f = fixture(), pi = f.make("original");
	await pi.start(); await pi.emit("agent_start"); await f.tick(60000);
	assert.equal(f.requests.length, 1);
	await pi.command("off"); await pi.emit("agent_settled"); await pi.emit("agent_start"); await f.tick(60000);
	assert.equal(f.requests.length, 1, "off must not silently re-enable on the next task");
	await pi.command(""); await pi.command("on"); await f.tick(60000);
	assert.equal(f.requests.length, 3);
	assert.equal(new Set(f.requests.map((request) => request.options.sessionId)).size, 3);
	for (const request of f.requests) {
		assert.equal(request.context.messages.length, 1);
		assert.equal(request.context.messages[0].role, "user");
		assert.equal(request.context.tools, undefined);
		assert.equal(request.options.cacheRetention, "none");
	}
	for (const [event, id] of [["session_switch", "new"], ["session_fork", "fork"]]) {
		await pi.switch(id, event);
		assert.deepEqual(f.snapshots().map((snapshot) => snapshot.id), [`42-${id}`]);
	}
	await pi.start(); assert.equal(f.snapshots().length, 1, "reload must not delete a same-session snapshot");
	await pi.emit("session_shutdown"); assert.equal(f.files.size, 0); assert.equal(f.timers.size, 0);
	await pi.emit("agent_settled"); await pi.emit("agent_start");
	assert.equal(f.files.size, 0, "late SDK abort events must not resurrect disposed session snapshots");
	assert.equal(f.timers.size, 0);
});

test("same-process sessions stay distinct and heartbeat preserves quiet sessions without inventing activity", async () => {
	const f = fixture(), parent = f.make("parent"), child = f.make("child");
	await parent.start(); await child.start(); await child.emit("agent_start");
	const activity = f.snapshots().find((snapshot) => snapshot.id === "42-child").lastActivityAt;
	f.advance(2 * 60 * 60 * 1000); await f.tick(15000);
	assert.equal(f.snapshots().length, 2);
	assert.equal(f.snapshots().find((snapshot) => snapshot.id === "42-child").lastActivityAt, activity);
	await parent.command("");
	const input = f.requests[0].context.messages[0].content[0].text;
	assert.ok(input.includes("42-parent") && input.includes("42-child"));
	await parent.emit("session_shutdown"); assert.equal(f.snapshots().length, 1);
	await child.emit("session_shutdown"); assert.equal(f.files.size, 0); assert.equal(f.timers.size, 0);
});

test("slow summary requests cannot overlap and stop/timeout cancel only the separate completion", async () => {
	const f = fixture(true), pi = f.make("slow");
	await pi.start(); await pi.emit("agent_start");
	await f.tick(60000); await f.tick(60000);
	assert.equal(f.requests.length, 1);
	await f.tick(45000);
	assert.equal(f.requests[0].options.signal.aborted, true);
	const summary = JSON.parse([...f.files].find(([name]) => name.endsWith(".summary.json"))[1]);
	assert.ok(summary.text.includes("42-slow"), "timeout must fall back to bounded observation facts");
	await f.tick(60000); assert.equal(f.requests.length, 2);
	await pi.emit("agent_settled");
	assert.equal(f.requests[1].options.signal.aborted, true);
	assert.equal(f.snapshots()[0].active, false);
	await pi.emit("session_shutdown"); assert.equal(f.files.size, 0); assert.equal(f.timers.size, 0);
});

test("explicit on overrides a disabled default and stale SDK contexts stop heartbeats", async () => {
	const f = fixture(false, "0"), pi = f.make("disabled");
	await pi.start(); await pi.emit("agent_start"); await f.tick(300000);
	assert.equal(f.requests.length, 0);
	await pi.command("on"); await f.tick(300000); assert.equal(f.requests.length, 1);
	await pi.emit("agent_settled"); await pi.emit("agent_start"); await f.tick(300000);
	assert.equal(f.requests.length, 2);
	pi.invalidate(); await f.tick(15000);
	assert.equal(f.files.size, 0); assert.equal(f.timers.size, 0);
});

test("bounded summary input remains valid JSON and preserves all-session counts when detail must be omitted", async () => {
	const f = fixture(), sessions = [];
	for (let i = 0; i < 10; i++) {
		const pi = f.make(`session-${i}`); sessions.push(pi);
		await pi.start(); await pi.emit("agent_start");
		await pi.emit("tool_execution_start", { toolName: "bash", args: { command: "x".repeat(10000) } });
	}
	await sessions[0].command("");
	const text = f.requests[0].context.messages[0].content[0].text;
	const json = text.match(/<observed-data>\n([\s\S]+)\n<\/observed-data>/)[1];
	assert.ok(json.length <= 2400);
	const facts = JSON.parse(json);
	assert.equal(facts.observedSessions, 10); assert.equal(facts.activeSessions, 10);
	assert.equal(facts.phases["running bash"], 10);
	assert.ok(facts.omittedSessions > 0);
	assert.equal(facts.sessions.length + facts.omittedSessions, 10);
	for (const pi of sessions) await pi.emit("session_shutdown");
});
