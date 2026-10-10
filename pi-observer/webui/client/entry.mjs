import { defineView } from "../sdk/index.mjs";

const initialState = {
	authorized: false,
	snapshots: [],
	summary: null,
	refreshedAt: null,
};

function formatTime(value) {
	if (!value) return "-";
	const time = new Date(value);
	return Number.isNaN(time.getTime()) ? "-" : time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function formatAge(value) {
	const elapsed = Date.now() - Date.parse(value || "");
	if (!Number.isFinite(elapsed) || elapsed < 0) return "just now";
	if (elapsed < 60_000) return `${Math.floor(elapsed / 1000)}s ago`;
	if (elapsed < 3_600_000) return `${Math.floor(elapsed / 60_000)}m ago`;
	return `${Math.floor(elapsed / 3_600_000)}h ago`;
}

function text(value) {
	return typeof value === "string" && value.trim() ? value.trim() : "-";
}

function element(name, className, value) {
	const node = document.createElement(name);
	if (className) node.className = className;
	if (value !== undefined) node.textContent = value;
	return node;
}

function render(root, state, send) {
	root.replaceChildren();
	const shell = element("main", "observer");
	const header = element("header", "observer-header");
	const title = element("div", "title-wrap");
	title.append(element("h1", "observer-title", "Pi Observer"));
	title.append(element("p", "updated", state.refreshedAt ? `Updated ${formatTime(state.refreshedAt)}` : "Waiting for status"));
	const refresh = element("button", "icon-button", "Refresh");
	refresh.type = "button";
	refresh.title = "Refresh observer status";
	refresh.addEventListener("click", () => send({ type: "observer-refresh" }));
	header.append(title, refresh);
	shell.append(header);

	if (!state.authorized) {
		const access = element("section", "access", "Observer needs read access to Pi's snapshot directory.");
		const grant = element("button", "primary", "Allow read access");
		grant.type = "button";
		grant.addEventListener("click", () => send({ type: "observer-authorize" }));
		access.append(grant);
		shell.append(access);
		root.append(shell);
		return;
	}

	if (state.error) shell.append(element("p", "error", state.error));
	if (state.summary && state.summary.text) {
		const summary = element("section", "summary");
		summary.append(element("div", "eyebrow", "Latest summary"));
		summary.append(element("p", "summary-text", state.summary.text));
		summary.append(element("div", "summary-time", `${formatAge(state.summary.reportedAt)} at ${formatTime(state.summary.reportedAt)}`));
		shell.append(summary);
	}

	const sessions = element("section", "sessions");
	const active = state.snapshots.filter((snapshot) => snapshot.active).length;
	sessions.append(element("div", "section-title", `${active ? `${active} active` : "No active"} session${state.snapshots.length === 1 ? "" : "s"}`));
	if (state.snapshots.length === 0) {
		sessions.append(element("p", "empty", "No current Pi observer snapshots."));
	}
	for (const snapshot of state.snapshots) {
		const card = element("article", `session ${snapshot.active ? "is-active" : ""}`);
		const top = element("div", "session-top");
		top.append(element("strong", "phase", text(snapshot.phase)));
		top.append(element("span", `status ${snapshot.active ? "active" : "idle"}`, snapshot.active ? "Active" : "Idle"));
		card.append(top);
		const details = element("dl", "details");
		const rows = [
			["Process", String(snapshot.pid ?? "-")],
			["Working directory", text(snapshot.cwd)],
			["Latest tool", text(snapshot.lastTool)],
			["Activity", formatAge(snapshot.lastActivityAt)],
		];
		for (const [label, value] of rows) {
			details.append(element("dt", "", label), element("dd", "", value));
		}
		card.append(details);
		if (snapshot.lastAssistantText) card.append(element("p", "assistant-text", snapshot.lastAssistantText));
		sessions.append(card);
	}
	shell.append(sessions);
	root.append(shell);
}

export default defineView({
	mount(container, ctx) {
		const style = document.createElement("style");
		style.textContent = `
			.observer { max-width: 980px; margin: 0 auto; padding: 24px; color: var(--text, #e7e9ed); font: 14px/1.5 system-ui, sans-serif; }
			.observer-header { display: flex; align-items: center; justify-content: space-between; gap: 16px; border-bottom: 1px solid var(--border, #363a43); padding-bottom: 16px; }
			.observer-title { margin: 0; font-size: 20px; font-weight: 650; letter-spacing: 0; }
			.updated, .summary-time, .empty { margin: 3px 0 0; color: var(--muted, #a0a6b2); font-size: 12px; }
			.icon-button, .primary { border: 1px solid var(--border, #4b5260); border-radius: 5px; padding: 7px 10px; background: var(--button, #272b33); color: inherit; cursor: pointer; font: inherit; }
			.icon-button:hover, .primary:hover { background: var(--button-hover, #363c47); }
			.primary { margin-top: 14px; background: var(--accent, #2671d9); border-color: var(--accent, #2671d9); color: #fff; }
			.access, .summary, .sessions { margin-top: 22px; }
			.access { max-width: 560px; }
			.eyebrow, .section-title { color: var(--muted, #a0a6b2); font-size: 12px; font-weight: 650; text-transform: uppercase; letter-spacing: 0; }
			.summary-text { margin: 7px 0 0; font-size: 16px; }
			.error { color: #e86d75; }
			.session { border-top: 1px solid var(--border, #363a43); padding: 14px 0; }
			.session:first-of-type { margin-top: 8px; }
			.session-top { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
			.phase { overflow-wrap: anywhere; }
			.status { flex: 0 0 auto; border-radius: 999px; padding: 2px 7px; font-size: 11px; }
			.status.active { background: #174d35; color: #a8e6c3; }
			.status.idle { background: #3a3f49; color: #d3d7de; }
			.details { display: grid; grid-template-columns: 132px minmax(0, 1fr); gap: 4px 12px; margin: 11px 0 0; }
			.details dt { color: var(--muted, #a0a6b2); }
			.details dd { margin: 0; overflow-wrap: anywhere; }
			.assistant-text { margin: 12px 0 0; color: var(--muted, #c1c6d0); overflow-wrap: anywhere; }
			@media (max-width: 600px) { .observer { padding: 16px; } .details { grid-template-columns: 1fr; gap: 1px; } .details dd { margin-bottom: 7px; } }
		`;
		container.append(style);
		let state = initialState;
		const update = (payload) => {
			if (!payload || payload.type !== "observer-state") return;
			state = payload;
			render(container, state, ctx.send);
		};
		ctx.onData(update);
		render(container, state, ctx.send);
		ctx.send({ type: "observer-get" });
		return () => style.remove();
	},
});
