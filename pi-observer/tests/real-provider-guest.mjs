import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const agentDir = process.env.PI_CODING_AGENT_DIR;
assert.ok(agentDir && process.env.AHSB_RUNTIME_DIR, "run only in a prepared disposable guest");
const observerDir = join(agentDir, "observer"), workers = [], replies = [];
let forwarded = 0;
const proxy = process.platform === "linux"
	? spawn("socat", ["TCP-LISTEN:28812,fork,reuseaddr,bind=127.0.0.1", "VSOCK-CONNECT:2:28812"], { stdio: ["ignore", "ignore", "inherit"] }) : undefined;
const server = createServer(async (request, response) => {
	try {
		let body = "";
		for await (const chunk of request) body += chunk;
		const input = JSON.parse(body);
		console.log(`fixture-model-request=${body.includes("<observed-data>") ? "summary" : "agent"}`);
		assert.ok(!(input.tools || []).some(tool => (tool.function?.name || tool.name) === "observer"));
		if (!body.includes("<observed-data>")) {
			response.writeHead(200, { "Content-Type": "text/event-stream" });
			response.write(": fixture agent waiting for model output\n\n"); return;
		}
		assert.ok(forwarded++ < 2, "real provider budget exhausted");
		console.log("provider-request-forwarded");
		const result = await fetch("http://127.0.0.1:28812/v1/chat/completions", {
			method: "POST", headers: { "Content-Type": "application/json" }, body, signal: AbortSignal.timeout(42000),
		});
		console.log(`provider-response-http=${result.status}`);
		assert.equal(result.status, 200, "native broker rejected or failed the real completion");
		const sse = await result.text();
		const chunk = JSON.parse(sse.split("\n").find(line => line.startsWith("data: ")).slice(6));
		replies.push(chunk.choices[0].delta.content);
		response.writeHead(200, { "Content-Type": "text/event-stream" }); response.end(sse);
	} catch {
		console.error("provider-fixture-forward-failed");
		response.writeHead(400, { "Content-Type": "application/json" });
		response.end(JSON.stringify({ error: { message: "real-provider fixture failed" } }));
	}
});
const snapshots = () => readdirSync(observerDir).filter(name => name.endsWith(".snapshot.json")).map(name => JSON.parse(readFileSync(join(observerDir, name))));
const summaries = () => readdirSync(observerDir).filter(name => name.endsWith(".summary.json")).map(name => JSON.parse(readFileSync(join(observerDir, name))));
async function waitFor(check, seconds) {
	const end = Date.now() + seconds * 1000;
	while (Date.now() < end) {
		try { if (check()) return; } catch {}
		assert.ok(workers.every(child => child.exitCode === null));
		await delay(100);
	}
	throw Error("real-provider evidence deadline exceeded");
}
try {
	await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
	writeFileSync(join(agentDir, "models.json"), JSON.stringify({ providers: { deepseek: {
		baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "guest-fixture-only",
		models: [{ id: "deepseek-flash", name: "DeepSeek Flash summary acceptance", reasoning: false, input: ["text"],
			contextWindow: 32000, maxTokens: 160, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
	} } }));
	writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "deepseek", defaultModel: "deepseek-flash", defaultThinkingLevel: "off" }));
	for (const name of ["observer-work-main", "observer-work-child"]) {
		const cwd = join(agentDir, name); mkdirSync(cwd);
		const child = spawn("pi", ["--mode", "rpc", "--no-session"], { cwd,
			env: { ...process.env, PI_OBSERVER_INTERVAL_MINUTES: "0.2" }, stdio: ["pipe", "pipe", "inherit"] });
		child.stdout.on("data", () => {}); workers.push(child);
		child.stdin.write(JSON.stringify({ type: "prompt", message: "Wait for the fixture model response." }) + "\n");
	}
	await waitFor(() => snapshots().filter(item => item.active).length === 2, 15);
	console.log("observer-real-provider-two-agents PASS");
	const disabled = new Set();
	await waitFor(() => {
		const reports = summaries();
		for (const report of reports) {
			const worker = workers.find(child => child.pid === report.pid);
			if (worker && !disabled.has(worker.pid)) {
				disabled.add(worker.pid);
				worker.stdin.write(JSON.stringify({ type: "prompt", message: "/observer off" }) + "\n");
			}
		}
		return reports.length === 2 && replies.length === 2;
	}, 60);
	const reports = summaries();
	assert.equal(forwarded, 2);
	for (const report of reports) assert.ok(replies.includes(report.text), "fallback text is not real provider evidence");
	assert.equal(new Set(reports.map(report => report.pid)).size, 2);
	mkdirSync("/tmp/ah-artifacts", { recursive: true });
	const evidence = JSON.stringify({ provider: "deepseek", model: "deepseek-flash", forwarded,
		snapshots: snapshots(), reports, replies }, null, 2);
	writeFileSync("/tmp/ah-artifacts/real-provider.json", evidence);
	console.log(`REAL_PROVIDER_EVIDENCE=${Buffer.from(evidence).toString("base64")}`);
	console.log("observer-real-provider-independent-summaries PASS");
} finally {
	for (const child of workers) child.stdin.end();
	server.closeAllConnections(); server.close(); proxy?.kill();
	await Promise.all(workers.map(child => new Promise(resolve => {
		if (child.exitCode !== null) return resolve();
		const timer = setTimeout(() => child.kill("SIGTERM"), 3000);
		child.once("exit", () => { clearTimeout(timer); resolve(); });
	})));
}
assert.equal(readdirSync(observerDir).length, 0);
console.log("observer-real-provider-shutdown-cleanup PASS");
