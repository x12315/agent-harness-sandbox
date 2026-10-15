import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";

const agentDir = process.env.PI_CODING_AGENT_DIR;
assert.ok(agentDir);
const observerDir = join(agentDir, "observer");
const workers = [];
const server = createServer((request, response) => {
	let body = "";
	request.on("data", (chunk) => { body += chunk; });
	request.on("end", () => {
		const input = JSON.parse(body);
		const tools = (input.tools || []).map((tool) => tool.function?.name || tool.name);
		assert.ok(!tools.includes("observer"), "Observer must leave model tools unchanged");
		const summary = body.includes("<observed-data>");
		if (summary) {
			assert.equal(input.messages.length, 2, "summary must have a fresh, independent context");
			assert.deepEqual(input.messages.map((message) => message.role), ["system", "user"]);
			assert.equal(tools.length, 0, "summary cannot execute tools");
		}
		appendFileSync(join(agentDir, "model-evidence.jsonl"), JSON.stringify({ summary, tools, roles: input.messages.map((message) => message.role) }) + "\n");
		response.writeHead(200, { "Content-Type": "text/event-stream" });
		if (summary) {
			const text = process.env.PI_OBSERVER_TEST_IN_MEMORY === "1"
				? "Independent and in-memory Pi sessions are working in the disposable guest."
				: "Two Pi agents are working in the disposable guest.";
			response.write(`data: ${JSON.stringify({ id: "observer-summary", object: "chat.completion.chunk",
				choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] })}\n\n`);
			response.end(`data: ${JSON.stringify({ id: "observer-summary", object: "chat.completion.chunk",
				choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`);
		} else {
			// Keep real Pi agents awaiting the local mock model during UI checks.
			response.write(": observer test model waiting\n\n");
		}
	});
});
server.listen(0, "127.0.0.1", () => {
	writeFileSync(join(agentDir, "models.json"), JSON.stringify({ providers: {
		"observer-mock": {
			baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
			api: "openai-completions", apiKey: "mock-key",
			models: [{ id: "observer-test", name: "Observer test", reasoning: false,
				input: ["text"], contextWindow: 32000, maxTokens: 1024,
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
		},
	} }));
	writeFileSync(join(agentDir, "settings.json"), JSON.stringify({
		defaultProvider: "observer-mock", defaultModel: "observer-test", defaultThinkingLevel: "off",
	}));
	for (const name of ["observer-work-main", "observer-work-child"]) {
		const cwd = join(agentDir, name);
		mkdirSync(cwd, { recursive: true });
		const child = spawn("pi", ["--mode", "rpc", "--no-session"], {
			cwd, env: { ...process.env, PI_OBSERVER_INTERVAL_MINUTES: name.endsWith("main") ? "0.05" : "0" }, stdio: ["pipe", "pipe", "inherit"],
		});
		workers.push(child);
		let pending = "";
		child.stdout.on("data", (data) => {
			pending += data;
			while (pending.includes("\n")) {
				const end = pending.indexOf("\n");
				const line = pending.slice(0, end);
				pending = pending.slice(end + 1);
				try {
					const event = JSON.parse(line);
					console.log(JSON.stringify({ worker: name, type: event.type, command: event.command, success: event.success }));
				} catch {}
			}
		});
		child.on("error", (error) => { console.error(error); process.exitCode = 1; });
		child.stdin.write(JSON.stringify({ id: name, type: "get_commands" }) + "\n");
		child.stdin.write(JSON.stringify({ type: "prompt", message: `Observe ${name}.` }) + "\n");
	}
});
const check = setInterval(() => {
	try {
		const snapshots = readdirSync(observerDir).filter((file) => file.endsWith(".snapshot.json"))
			.map((file) => JSON.parse(readFileSync(join(observerDir, file), "utf8")));
		if (["observer-work-main", "observer-work-child"].every((name) =>
			snapshots.some((snapshot) => snapshot.cwd.endsWith(name) && snapshot.active))) {
			writeFileSync(join(agentDir, "agents-ready"), "plain pi auto-loaded two active observers\n");
			clearInterval(check);
		}
	} catch {}
}, 100);
function cleanup() {
	clearInterval(check);
	for (const child of workers) child.stdin.end();
	server.closeAllConnections();
	server.close();
	setTimeout(() => {
		for (const child of workers) child.kill("SIGTERM");
		process.exit();
	}, 1500);
}
process.on("SIGTERM", cleanup);
process.on("SIGINT", cleanup);
