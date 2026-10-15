import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import view from "./entry.mjs";

class Element {
	children = [];
	style = {};
	textContent = "";
	listeners = {};
	constructor(tag) { this.tag = tag; }
	append(...nodes) { for (const node of nodes) { node.parent = this; this.children.push(node); } }
	replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
	addEventListener(name, callback) { this.listeners[name] = callback; }
	remove() { this.parent.children = this.parent.children.filter((node) => node !== this); }
	get text() { return this.textContent + this.children.map((child) => child.text).join(" "); }
}

test("top-level Observer view uses a self-contained client and renders multiple processes after authorization", () => {
	const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url)));
	assert.equal(manifest.ui["topbar.primary"][0].view, "plugin:pi-observer");
	assert.deepEqual(manifest.permissions, ["fs:read", "ui"]);
	const previous = globalThis.document;
	globalThis.document = { createElement: (tag) => new Element(tag) };
	try {
		const container = new Element("div");
		let update;
		let unsubscribed = false;
		const sent = [];
		const cleanup = view.mount(container, {
			send: (payload) => sent.push(payload),
			onData: (handler) => { update = handler; return () => { unsubscribed = true; }; },
		});
		assert.ok(container.text.includes("Allow read access"));
		assert.deepEqual(sent, [{ type: "observer-get" }]);
		update({ type: "observer-state", authorized: true, snapshots: [
			{ pid: 10, cwd: "/main", active: true, phase: "thinking" },
			{ pid: 20, cwd: "/child", active: true, phase: "running read", lastTool: "read" },
		], summary: { text: "Two agents are working." } });
		assert.ok(container.text.includes("2 observed sessions · 2 processes · 2 active"));
		for (const value of ["10", "20", "/main", "/child", "Two agents are working."]) assert.ok(container.text.includes(value));
		assert.equal(container.children[0].tag, "style");
		update({ type: "observer-state", authorized: true, snapshots: [
			{ id: "parent", pid: 10, cwd: "/memory-parent", active: true, phase: "thinking" },
			{ id: "child", pid: 10, cwd: "/memory-child", active: true, phase: "thinking" },
		] });
		assert.ok(container.text.includes("2 observed sessions · 1 process · 2 active"));
		for (const value of ["parent", "child", "/memory-parent", "/memory-child"]) assert.ok(container.text.includes(value));
		cleanup();
		assert.equal(unsubscribed, true);
		assert.equal(container.children.length, 0);
	} finally { globalThis.document = previous; }
});
