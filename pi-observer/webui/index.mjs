import { homedir } from "node:os";
import { join } from "node:path";
import { definePlugin } from "./sdk/index.mjs";

const POLL_INTERVAL_MS = 15_000;
const SNAPSHOT_MAX_AGE_MS = 60 * 60 * 1000;
const MAX_FILES = 128;
const MAX_FILE_BYTES = 64 * 1024;

const observerDirectory = process.env.PI_OBSERVER_DIR || join(homedir(), ".pi", "agent", "observer");

function isRecord(value) {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function recent(timestamp) {
	const time = Date.parse(timestamp || "");
	return Number.isFinite(time) && Date.now() - time <= SNAPSHOT_MAX_AGE_MS;
}

function parseSnapshot(text) {
	try {
		const value = JSON.parse(text);
		if (!isRecord(value) || typeof value.id !== "string" || typeof value.pid !== "number" || !recent(value.updatedAt)) return null;
		return value;
	} catch {
		return null;
	}
}

function parseSummary(text) {
	try {
		const value = JSON.parse(text);
		if (!isRecord(value) || typeof value.text !== "string" || !recent(value.reportedAt)) return null;
		return value;
	} catch {
		return null;
	}
}

async function collect(host) {
	const entries = await host.fs.listPath(observerDirectory);
	const files = entries.filter((entry) => entry.type === "file").slice(0, MAX_FILES);
	const snapshots = [];
	const summaries = [];

	for (const entry of files) {
		if (!entry.name.endsWith(".snapshot.json") && !entry.name.endsWith(".summary.json")) continue;
		try {
			const text = await host.fs.readTextPath(join(observerDirectory, entry.name), MAX_FILE_BYTES);
			const parsed = entry.name.endsWith(".snapshot.json") ? parseSnapshot(text) : parseSummary(text);
			if (!parsed) continue;
			if (entry.name.endsWith(".snapshot.json")) snapshots.push(parsed);
			else summaries.push(parsed);
		} catch {
			// Another Pi process can replace or remove an atomic snapshot between list and read.
		}
	}

	snapshots.sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt));
	summaries.sort((a, b) => Date.parse(b.reportedAt) - Date.parse(a.reportedAt));
	return { snapshots, summary: summaries[0] || null };
}

export default definePlugin({
	async activate(host) {
		let authorized = host.fs.authorizedDirs().includes(observerDirectory);

		const state = async () => {
			if (!authorized) {
				return {
					type: "observer-state",
					authorized: false,
					directory: observerDirectory,
					snapshots: [],
					summary: null,
					refreshedAt: new Date().toISOString(),
				};
			}
			try {
				return { type: "observer-state", authorized: true, directory: observerDirectory, ...(await collect(host)), refreshedAt: new Date().toISOString() };
			} catch (error) {
				return {
					type: "observer-state",
					authorized: true,
					directory: observerDirectory,
					snapshots: [],
					summary: null,
					error: error instanceof Error ? error.message : "Unable to read observer snapshots.",
					refreshedAt: new Date().toISOString(),
				};
			}
		};

		const publish = async (clientId) => {
			const payload = await state();
			if (clientId) host.sendTo(clientId, payload);
			else host.broadcast(payload);
		};

		const offMessage = host.onMessage(async (payload, clientId) => {
			if (!isRecord(payload) || typeof payload.type !== "string") return;
			if (payload.type === "observer-authorize") {
				authorized = await host.fs.requestAccess(observerDirectory, "Read Pi Observer snapshots for the Observer tab.");
			}
			if (payload.type === "observer-authorize" || payload.type === "observer-refresh" || payload.type === "observer-get") {
				await publish(clientId);
			}
		});
		const offAttach = host.onAttach((clientId) => void publish(clientId));
		const stopPolling = host.schedule(POLL_INTERVAL_MS, () => void publish(), { label: "Pi Observer refresh" });

		host.log("Pi Observer tab activated", observerDirectory);
		return () => {
			offMessage();
			offAttach();
			stopPolling();
		};
	},
});
