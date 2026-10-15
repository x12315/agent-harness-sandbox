import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";

/** Serve at most two bounded Observer completions through an authenticated native model runtime.
 * Bind only to loopback; log summary evidence, never auth, headers, URLs or request bodies.
 */
export function createProviderBroker(runtime, model, evidenceFile) {
	let calls = existsSync(evidenceFile) ? readFileSync(evidenceFile, "utf8").trim().split("\n")
		.filter(Boolean).map(line => JSON.parse(line)).filter(event => event.stage === "started").length : 0;
	return createServer(async (request, response) => {
		let checkpoint = "route", index;
		if (request.method === "GET" && request.url === "/health") {
			response.end("ready"); return;
		}
		try {
			assert.equal(request.method, "POST"); assert.equal(request.url, "/v1/chat/completions");
			let body = "";
			for await (const chunk of request) {
				body += chunk;
				assert.ok(body.length <= 8192);
			}
			const input = JSON.parse(body);
			checkpoint = "model-and-roles";
			assert.equal(input.model, model.id);
			assert.equal(input.messages?.length, 2);
			assert.deepEqual(input.messages.map(message => message.role), ["system", "user"]);
			assert.equal(input.tools?.length || 0, 0);
			checkpoint = "system-prompt";
			assert.equal(input.messages[0].content, "你只负责把旁路观察数据压缩成一句准确的状态摘要。");
			checkpoint = "observed-facts";
			const content = input.messages[1].content;
			if (Array.isArray(content)) assert.ok(content.every(part => part.type === "text" && typeof part.text === "string"));
			const text = Array.isArray(content) ? content.map(part => part.text).join("\n") : content;
			assert.equal(typeof text, "string");
			const facts = JSON.parse(text.match(/<observed-data>\n([\s\S]+)\n<\/observed-data>/)[1]);
			appendFileSync(evidenceFile, JSON.stringify({ stage: "validated-facts", observedSessions: facts.observedSessions,
				activeSessions: facts.activeSessions, contentType: Array.isArray(content) ? "text-blocks" : "string" }) + "\n", { mode: 0o600 });
			assert.equal(facts.observedSessions, 2); assert.equal(facts.activeSessions, 2);
			assert.ok(calls < 2, "authorized request budget exhausted");
			index = ++calls;
			const sessionId = randomUUID(), started = Date.now();
			checkpoint = "provider-completion";
			appendFileSync(evidenceFile, JSON.stringify({ stage: "started", index, provider: model.provider, model: model.id,
				sessionId, roles: ["system", "user"], toolCount: 0, observedSessions: 2, activeSessions: 2 }) + "\n", { mode: 0o600 });
			const result = await runtime.completeSimple(model, {
				systemPrompt: input.messages[0].content,
				messages: [{ role: "user", content: [{ type: "text", text }], timestamp: Date.now() }],
			}, { sessionId, cacheRetention: "none", reasoning: "off", maxTokens: 160,
				maxRetries: 0, timeoutMs: 35000, signal: AbortSignal.timeout(40000) });
			assert.ok(!["error", "aborted"].includes(result.stopReason));
			const summary = result.content.filter(part => part.type === "text").map(part => part.text).join(" ").trim();
			assert.ok(summary);
			appendFileSync(evidenceFile, JSON.stringify({ stage: "completed", index, provider: model.provider, model: model.id,
				sessionId, text: summary, stopReason: result.stopReason, usage: result.usage, elapsedMs: Date.now() - started }) + "\n", { mode: 0o600 });
			response.writeHead(200, { "Content-Type": "text/event-stream" });
			response.write(`data: ${JSON.stringify({ id: sessionId, object: "chat.completion.chunk", model: model.id,
				choices: [{ index: 0, delta: { role: "assistant", content: summary }, finish_reason: null }] })}\n\n`);
			response.end(`data: ${JSON.stringify({ id: sessionId, object: "chat.completion.chunk", model: model.id,
				choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`);
		} catch {
			appendFileSync(evidenceFile, JSON.stringify({ stage: "failed", checkpoint, index }) + "\n", { mode: 0o600 });
			response.writeHead(400, { "Content-Type": "application/json" });
			response.end(JSON.stringify({ error: { message: "Observer request rejected or provider completion failed" } }));
		}
	});
}
