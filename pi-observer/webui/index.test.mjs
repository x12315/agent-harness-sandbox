import assert from "node:assert/strict";
import { describe, it } from "node:test";
import plugin from "./index.mjs";
import { createMockHost } from "./sdk/index.mjs";

const snapshot = {
	id: "123-session",
	pid: 123,
	cwd: "/work/project",
	updatedAt: new Date().toISOString(),
	lastActivityAt: new Date().toISOString(),
	active: true,
	phase: "running bash",
	recentEvents: [],
};

const summary = {
	id: "123-session",
	pid: 123,
	reportedAt: new Date().toISOString(),
	text: "Pi is running a shell command.",
};

describe("Pi Observer WebUI plugin", () => {
	it("does not read snapshots before the user grants directory access", async () => {
		const host = createMockHost({
			fs: {
				listPath: async () => {
					throw new Error("must not read before authorization");
				},
			},
		});
		const cleanup = await plugin.activate(host);
		await host.mock.emitAsync("onMessage", { type: "observer-get" }, "client-1");
		const sent = host.mock.calls("sendTo").at(-1)?.args[1];
		assert.equal(sent.authorized, false);
		assert.equal(host.mock.calls("fs.listPath").length, 0);
		cleanup();
	});

	it("does not read after denied access, including scheduled refresh", async () => {
		const host = createMockHost({ fs: { requestAccess: async () => false } });
		const cleanup = await plugin.activate(host);
		await host.mock.emitAsync("onMessage", { type: "observer-authorize" }, "client-1");
		await host.mock.fireSchedules();
		await new Promise(setImmediate);
		assert.equal(host.mock.calls("fs.listPath").length, 0);
		assert.equal(host.mock.calls("fs.readTextPath").length, 0);
		assert.equal(host.mock.calls("broadcast").at(-1).args[0].authorized, false);
		cleanup();
		assert.equal(host.mock.schedules.length, 0);
	});

	it("scheduled refresh publishes new state and releases subscriptions on cleanup", async () => {
		let current = snapshot;
		const host = createMockHost({ fs: {
			requestAccess: async () => true,
			listPath: async () => [{ name: "123-session.snapshot.json", type: "file" }],
			readTextPath: async () => JSON.stringify(current),
		} });
		const cleanup = await plugin.activate(host);
		await host.mock.emitAsync("onMessage", { type: "observer-authorize" }, "client-1");
		current = { ...snapshot, cwd: "/new-work", phase: "idle", active: false };
		await host.mock.fireSchedules();
		await new Promise(setImmediate);
		assert.deepEqual(host.mock.calls("broadcast").at(-1).args[0].snapshots, [current]);
		assert.equal(host.mock.calls("registerAgentTool").length, 0);
		assert.equal(host.mock.calls("prompt").length, 0);
		assert.equal(host.mock.calls("bash").length, 0);
		assert.equal(host.mock.calls("llm.complete").length, 0);
		cleanup();
		assert.equal(host.mock.schedules.length, 0);
	});

	it("reads only snapshot and summary files after explicit authorization", async () => {
		const calls = [];
		const host = createMockHost({
			fs: {
				requestAccess: async () => true,
				listPath: async () => [
					{ name: "123-session.snapshot.json", type: "file" },
					{ name: "123-session.summary.json", type: "file" },
					{ name: "456-session.snapshot.json", type: "file" },
					{ name: "ignore.txt", type: "file" },
				],
				readTextPath: async (file) => {
					calls.push(file);
					if (file.endsWith("456-session.snapshot.json")) return JSON.stringify({ ...snapshot, id: "456-session", pid: 456 });
					return file.endsWith("snapshot.json") ? JSON.stringify(snapshot) : JSON.stringify(summary);
				},
			},
		});
		const cleanup = await plugin.activate(host);
		await host.mock.emitAsync("onMessage", { type: "observer-authorize" }, "client-1");
		const sent = host.mock.calls("sendTo").at(-1)?.args[1];
		assert.equal(sent.authorized, true);
		assert.deepEqual(sent.snapshots.map((value) => value.pid), [123, 456]);
		assert.equal(sent.summary.text, summary.text);
		assert.equal(calls.length, 3);
		assert.ok(calls.every((file) => file.endsWith(".snapshot.json") || file.endsWith(".summary.json")));
		cleanup();
	});
});
