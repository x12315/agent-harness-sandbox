import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createProviderBroker } from "./provider-broker.mjs";

test("broker permits two fresh tool-free summaries only and never exposes credential data", async t => {
	const dir = mkdtempSync(join(tmpdir(), "observer-broker-")), evidence = join(dir, "evidence.jsonl"), calls = [];
	const model = { id: "deepseek-flash", provider: "deepseek" };
	const server = createProviderBroker({ completeSimple: async (...args) => {
		calls.push(args); return { stopReason: "stop", content: [{ type: "text", text: "两个会话正在等待模型输出。" }], usage: { input: 50, output: 12 } };
	} }, model, evidence);
	await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
	t.after(async () => { await new Promise(resolve => server.close(resolve)); rmSync(dir, { recursive: true }); });
	const url = `http://127.0.0.1:${server.address().port}/v1/chat/completions`;
	const input = { model: model.id, messages: [
		{ role: "system", content: "你只负责把旁路观察数据压缩成一句准确的状态摘要。" },
		{ role: "user", content: '<observed-data>\n{"observedSessions":2,"activeSessions":2}\n</observed-data>' },
	] };
	const post = body => fetch(url, { method: "POST", body: JSON.stringify(body) });
	for (const invalid of [{ ...input, model: "other" }, { ...input, tools: [{}] }, { ...input, messages: input.messages.slice(1) }]) {
		assert.equal((await post(invalid)).status, 400);
	}
	assert.equal(calls.length, 0);
	for (let i = 0; i < 2; i++) {
		const body = i ? { ...input, messages: [input.messages[0], { ...input.messages[1], content: [{ type: "text", text: input.messages[1].content }] }] } : input;
		const response = await post(body); assert.equal(response.status, 200); await response.text();
	}
	assert.equal((await post(input)).status, 400); assert.equal(calls.length, 2);
	assert.notEqual(calls[0][2].sessionId, calls[1][2].sessionId);
	for (const [, context, options] of calls) {
		assert.equal(context.messages.length, 1); assert.equal(context.tools, undefined);
		assert.equal(options.maxRetries, 0); assert.equal(options.maxTokens, 160); assert.equal(options.cacheRetention, "none");
	}
	assert.ok(!readFileSync(evidence, "utf8").includes("apiKey"));
	const restarted = createProviderBroker({ completeSimple: () => { throw Error("must not call after budget exhaustion"); } }, model, evidence);
	await new Promise(resolve => restarted.listen(0, "127.0.0.1", resolve));
	t.after(() => new Promise(resolve => restarted.close(resolve)));
	assert.equal((await fetch(`http://127.0.0.1:${restarted.address().port}/v1/chat/completions`, {
		method: "POST", body: JSON.stringify(input),
	})).status, 400, "restarting the broker must not reset authorization budget");
});
