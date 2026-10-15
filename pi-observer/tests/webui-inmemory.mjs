import assert from "node:assert/strict";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const agentDir = process.env.PI_CODING_AGENT_DIR;
const runtime = process.env.AHSB_RUNTIME_DIR;
assert.ok(agentDir && runtime);
const modules = existsSync(join(runtime, "lib/node_modules")) ? join(runtime, "lib/node_modules") : join(runtime, "node_modules");
const server = join(modules, "pi-web-ui/dist/server");
const { ClientSession } = await import(pathToFileURL(join(server, "agent-service.js")));
const { ClientStateStore } = await import(pathToFileURL(join(server, "client-state.js")));
const parentCwd = join(agentDir, "observer-memory-parent");
const childCwd = join(agentDir, "observer-memory-child");
for (const cwd of [parentCwd, childCwd]) mkdirSync(cwd, { recursive: true });
const client = await ClientSession.create("observer-memory-test", parentCwd,
	new ClientStateStore(join(agentDir, "memory-client-state.json")), { blank: true });
let closing = false;
async function cleanup() {
	if (closing) return;
	closing = true;
	await client.dispose();
	process.exit();
}
process.on("SIGTERM", () => void cleanup());
process.on("SIGINT", () => void cleanup());

const parentId = client.activeId;
void client.session.sendUserMessage("Observe the in-memory test parent.").catch((error) => {
	if (!closing) console.error(error.message);
});
const childId = await client.spawnSubagentConversation("Observe the in-memory child.", "general", childCwd,
	undefined, null, parentId, false);
const child = client.convs.get(childId);
assert.equal(child.isSubagent, true);
assert.equal(child.parentId, parentId);
assert.equal(child.session.sessionFile, undefined, "the real WebUI child must remain in memory");
assert.ok(client.session.sessionFile, "parent is a separate persistent WebUI conversation");
for (const session of [client.session, child.session]) {
	assert.ok(!session.agent.state.tools.some((tool) => tool.name === "observer"), "Observer must not add a model tool");
}
const dir = process.env.PI_OBSERVER_DIR;
const read = (suffix) => readdirSync(dir).filter((name) => name.endsWith(suffix))
	.map((name) => JSON.parse(readFileSync(join(dir, name), "utf8")));
const deadline = Date.now() + 15000;
let snapshots;
while (Date.now() < deadline) {
	snapshots = read(".snapshot.json").filter((snapshot) => snapshot.pid === process.pid && snapshot.active);
	if ([parentCwd, childCwd].every((cwd) => snapshots.some((snapshot) => snapshot.cwd === cwd))) break;
	await delay(100);
}
assert.equal(snapshots.length, 2, "two same-process WebUI sessions must have separate active snapshots");
assert.equal(new Set(snapshots.map((snapshot) => snapshot.id)).size, 2);
const evidence = { pid: process.pid, parentId, childId, snapshotIds: snapshots.map((snapshot) => snapshot.id) };
writeFileSync(join(agentDir, "memory-ready.json"), JSON.stringify(evidence));
console.log("observer-webui-inmemory-two-sessions PASS");
const summaryDeadline = Date.now() + 15000;
while (Date.now() < summaryDeadline) {
	const summaries = read(".summary.json");
	if (evidence.snapshotIds.every((id) => summaries.some((summary) => summary.id === id && summary.text))) {
		writeFileSync(join(agentDir, "memory-summaries-ready"), "native WebUI parent and in-memory child both summarized\n");
		console.log("observer-webui-inmemory-summaries PASS");
		break;
	}
	await delay(100);
}
assert.ok(existsSync(join(agentDir, "memory-summaries-ready")), "automatic summary missing for a WebUI session");
setInterval(() => {}, 1000);
