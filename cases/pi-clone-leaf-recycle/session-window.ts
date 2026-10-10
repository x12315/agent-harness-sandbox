import { spawn, execFile } from "node:child_process";
import { constants, accessSync, closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync, readSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, delimiter, dirname, join } from "node:path";
import { promisify } from "node:util";
import { copyToClipboard, type ExtensionAPI, type ExtensionCommandContext, SessionManager } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

const run = promisify(execFile);

function isContent(entry: { type: string }): boolean {
	return entry.type !== "model_change" && entry.type !== "thinking_level_change";
}

function cloneRecord(file: string): string {
	return join(dirname(file), ".pi-session-window-clones", `${basename(file)}.json`);
}

function markClone(manager: SessionManager): void {
	const file = manager.getSessionFile();
	if (!file || !existsSync(file)) return;
	const record = cloneRecord(file);
	mkdirSync(dirname(record), { recursive: true, mode: 0o700 });
	writeFileSync(record, JSON.stringify({ id: manager.getSessionId(), entries: manager.getEntries().filter(isContent).map((entry) => entry.id) }), { flag: "wx", mode: 0o600 });
}

function hasUnknownChildren(file: string): boolean {
	const sessionDir = dirname(file);
	const roots = new Set([join(homedir(), ".pi", "agent", "sessions")]);
	if (process.env.PI_CODING_AGENT_DIR) roots.add(join(process.env.PI_CODING_AGENT_DIR, "sessions"));
	// Profile launchers isolate settings but can retain the native session root.
	if (!roots.has(dirname(sessionDir))) return true;
	const header = Buffer.alloc(32 * 1024);
	for (const root of roots) {
		if (!existsSync(root)) continue;
		for (const dirent of readdirSync(root, { withFileTypes: true })) {
			if (!dirent.isDirectory()) continue;
			const sessionDirectory = join(root, dirent.name);
			// A recycled child still needs its original parent path for restoration.
			for (const dir of [sessionDirectory, join(sessionDirectory, ".recycled-session-window")]) {
				if (!existsSync(dir)) continue;
				for (const name of readdirSync(dir)) {
					if (!name.endsWith(".jsonl") || join(dir, name) === file) continue;
					const fd = openSync(join(dir, name), "r");
					try {
						const length = readSync(fd, header, 0, header.length, 0);
						const end = header.subarray(0, length).indexOf(10);
						if (end < 0 || JSON.parse(header.toString("utf8", 0, end)).parentSession === file) return true;
					} finally {
						closeSync(fd);
					}
				}
			}
		}
	}
	return false;
}

function shellQuote(value: string): string {
	return `'${value.replaceAll("'", "'\\''")}'`;
}

function appleScriptQuote(value: string): string {
	return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

function executableOnPath(name: string): string | undefined {
	for (const dir of (process.env.PATH ?? "").split(delimiter)) {
		if (!dir) continue;
		const path = join(dir, name);
		try {
			accessSync(path, constants.X_OK);
			return path;
		} catch { /* try the next PATH entry */ }
	}
}

async function openTerminal(launcher: string): Promise<void> {
	const command = `/bin/sh ${shellQuote(launcher)}`;
	if (process.platform === "darwin") {
		const script = process.env.TERM_PROGRAM === "iTerm.app"
			? `tell application "iTerm2" to create window with default profile command ${appleScriptQuote(command)}`
			: `tell application "Terminal" to do script ${appleScriptQuote(command)}`;
		await run("osascript", ["-e", script]);
		return;
	}
	if (process.platform !== "linux") throw new Error("Only macOS and Linux terminals are supported");
	if (!process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) throw new Error("No graphical display is available");
	const terminal = [
		["x-terminal-emulator", ["-e", "/bin/sh", launcher]],
		["gnome-terminal", ["--", "/bin/sh", launcher]],
		["xterm", ["-e", "/bin/sh", launcher]],
	] as const;
	const selected = terminal.find(([name]) => executableOnPath(name));
	if (!selected) throw new Error("No supported terminal found (x-terminal-emulator, gnome-terminal, xterm)");
	await new Promise<void>((resolve, reject) => {
		const child = spawn(selected[0], [...selected[1]], { detached: true, stdio: "ignore" });
		child.once("error", reject);
		child.once("spawn", () => { child.unref(); resolve(); });
	});
}

async function openWindow(sessionFile: string, cwd: string): Promise<void> {
	const piExecutable = executableOnPath("pi");
	if (!piExecutable) throw new Error("pi is not on PATH");
	const dir = mkdtempSync(join(tmpdir(), "pi-session-window-"));
	const launcher = join(dir, "launch.sh");
	try {
		writeFileSync(launcher, `#!/bin/sh
export PATH=${shellQuote(process.env.PATH ?? "")}
rm -f "$0"
rmdir ${shellQuote(dir)} 2>/dev/null
if ! cd ${shellQuote(cwd)}; then
  printf 'Could not open session directory.\\n'
  exec ${shellQuote(process.env.SHELL || "/bin/sh")} -l
fi
${shellQuote(piExecutable)} --session ${shellQuote(sessionFile)}
status=$?
if [ "$status" -ne 0 ]; then
  printf '\\nPi exited with status %s.\\n' "$status"
  exec ${shellQuote(process.env.SHELL || "/bin/sh")} -l
fi
`, { mode: 0o600 });
		await openTerminal(launcher);
	} catch (error) {
		rmSync(dir, { recursive: true, force: true });
		throw error;
	}
}

async function forkInWindow(ctx: ExtensionCommandContext, leafId: string, prompt?: string): Promise<void> {
	if (!ctx.isIdle()) {
		ctx.ui.notify("Wait for the current response to finish before opening a fork", "warning");
		return;
	}
	const sourceFile = ctx.sessionManager.getSessionFile();
	if (!sourceFile || !existsSync(sourceFile)) {
		ctx.ui.notify("Wait for the first assistant response so the session is saved", "warning");
		return;
	}
	try {
		const branch = SessionManager.open(sourceFile, ctx.sessionManager.getSessionDir());
		const forkedFile = branch.createBranchedSession(leafId);
		if (!forkedFile || !existsSync(forkedFile)) {
			ctx.ui.notify("This branch has no saved assistant response yet", "warning");
			return;
		}
		if (!prompt) {
			try {
				markClone(branch);
			} catch (error) {
				ctx.ui.notify(`Automatic clone cleanup unavailable: ${String(error)}`, "warning");
			}
		}
		try {
			await openWindow(forkedFile, ctx.cwd);
		} catch (error) {
			ctx.ui.notify(`New window failed: ${String(error)}\nOpen manually: pi --session ${shellQuote(forkedFile)}`, "error");
			return;
		}
		if (prompt) {
			try {
				await copyToClipboard(prompt);
				ctx.ui.notify("Fork opened; selected prompt copied to clipboard. Paste it in the new window to edit.", "info");
			} catch (error) {
				ctx.ui.notify(`Fork opened, but could not copy the selected prompt: ${String(error)}`, "warning");
			}
		} else {
			ctx.ui.notify("Clone opened in a new window; this session is unchanged.", "info");
		}
	} catch (error) {
		ctx.ui.notify(`Could not fork session: ${String(error)}`, "error");
	}
}

/** Register window-preserving alternatives to pi's built-in /clone and /fork commands. */
export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (event, ctx) => {
		if (event.reason !== "fork" || !event.previousSessionFile || !existsSync(event.previousSessionFile)) return;
		try {
			const source = SessionManager.open(event.previousSessionFile);
			if (source.getLeafId() === ctx.sessionManager.getLeafId()) markClone(ctx.sessionManager);
		} catch (error) {
			console.error(`Could not mark clone: ${String(error)}`);
		}
	});

	pi.on("session_shutdown", (event, ctx) => {
		if (process.env.PI_SESSION_WINDOW_RECYCLE === "0" || event.reason === "reload" || event.reason === "fork") return;
		const file = ctx.sessionManager.getSessionFile();
		if (!file || !existsSync(cloneRecord(file))) return;
		try {
			const record = JSON.parse(readFileSync(cloneRecord(file), "utf8"));
			if (record.id !== ctx.sessionManager.getSessionId()) return;
			const entries = ctx.sessionManager.getEntries();
			const baseline = entries.filter(isContent).map((entry) => entry.id);
			if (JSON.stringify(baseline) !== JSON.stringify(record.entries)) {
				rmSync(cloneRecord(file));
				return;
			}
			const saved = readFileSync(file, "utf8").trimEnd().split("\n").map((line) => JSON.parse(line));
			if (saved.length !== entries.length + 1 || saved[0]?.id !== record.id || saved.some((entry, index) => index > 0 && entry.id !== entries[index - 1].id)) return;
			if (hasUnknownChildren(file)) return;
			const recycledDir = join(dirname(file), ".recycled-session-window");
			mkdirSync(recycledDir, { recursive: true, mode: 0o700 });
			if (existsSync(join(recycledDir, basename(file)))) return;
			renameSync(file, join(recycledDir, basename(file)));
			rmSync(cloneRecord(file));
		} catch (error) {
			console.error(`Could not recycle clone ${file}: ${String(error)}`);
		}
	});

	pi.registerCommand("clone-window", {
		description: "Clone the current conversation into a new terminal window, preserving this session",
		handler: async (_args, ctx) => {
			if (ctx.mode !== "tui") {
				ctx.ui.notify("/clone-window requires interactive mode", "warning");
				return;
			}
			const leafId = ctx.sessionManager.getLeafId();
			if (!leafId) {
				ctx.ui.notify("Nothing to clone yet", "warning");
				return;
			}
			await forkInWindow(ctx, leafId);
		},
	});

	pi.registerCommand("fork-window", {
		description: "Fork before a previous user message in a new window, preserving this session",
		handler: async (_args, ctx) => {
			if (ctx.mode !== "tui") {
				ctx.ui.notify("/fork-window requires interactive mode", "warning");
				return;
			}
			const messages = ctx.sessionManager.getEntries().filter(
				(entry) => entry.type === "message" && entry.message.role === "user",
			);
			const choices = messages.map((entry) => {
				const content = entry.message.content;
				const text = typeof content === "string"
					? content
					: content.filter((part) => part.type === "text").map((part) => part.text).join("");
				return {
					entry,
					text,
					hasImages: typeof content !== "string" && content.some((part) => part.type === "image"),
					label: `${text.replace(/\s+/g, " ").slice(0, 80)} [${entry.id}]`,
				};
			}).filter((choice) => choice.text);
			if (!choices.length) {
				ctx.ui.notify("No user messages to fork from", "warning");
				return;
			}
			const selected = await ctx.ui.custom<string | undefined>((tui, theme, keys, done) => {
				let index = choices.length - 1;
				const visibleCount = () => Math.max(1, Math.min(9, tui.terminal.rows - 3));
				return {
					render(width: number): string[] {
						const count = visibleCount();
						const start = Math.max(0, Math.min(index - Math.floor(count / 2), choices.length - count));
						const end = Math.min(start + count, choices.length);
						const lines: string[] = [];
						if (tui.terminal.rows >= 3) lines.push(truncateToWidth(theme.bold("Fork in new window"), width));
						if (tui.terminal.rows >= 4) lines.push(truncateToWidth(theme.fg("muted", "↑↓ navigate · PgUp/PgDn page · Enter select · Esc cancel"), width));
						for (let i = start; i < end; i++) {
							const active = i === index;
							const prefix = active ? "› " : "  ";
							const text = truncateToWidth(choices[i].label, Math.max(0, width - 2));
							lines.push(truncateToWidth(active ? theme.fg("accent", `${prefix}${text}`) : `${prefix}${text}`, width));
						}
						if (tui.terminal.rows >= 2) lines.push(truncateToWidth(theme.fg("muted", `${index + 1}/${choices.length} · ${start > 0 ? "↑ more " : ""}${end < choices.length ? "↓ more" : ""}`), width));
						return lines;
					},
					invalidate(): void {},
					handleInput(data: string): void {
						const page = visibleCount();
						if (keys.matches(data, "tui.select.up")) index = Math.max(0, index - 1);
						else if (keys.matches(data, "tui.select.down")) index = Math.min(choices.length - 1, index + 1);
						else if (keys.matches(data, "tui.select.pageUp")) index = Math.max(0, index - page);
						else if (keys.matches(data, "tui.select.pageDown")) index = Math.min(choices.length - 1, index + page);
						else if (keys.matches(data, "tui.select.confirm")) return done(choices[index].entry.id);
						else if (keys.matches(data, "tui.select.cancel")) return done(undefined);
						tui.requestRender();
					},
				};
			}, { overlay: true, overlayOptions: { anchor: "center", width: "100%", maxHeight: "100%" } });
			const choice = choices.find((item) => item.entry.id === selected);
			if (!choice) return;
			if (choice.hasImages) {
				ctx.ui.notify("Cannot copy image attachments into the new window's editor", "warning");
				return;
			}
			if (!choice.entry.parentId) {
				ctx.ui.notify("Cannot open a fork before the first message in a new window", "warning");
				return;
			}
			await forkInWindow(ctx, choice.entry.parentId, choice.text);
		},
	});
}
