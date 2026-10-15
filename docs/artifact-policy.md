# Agent Sandbox Artifact Policy

This policy separates durable test inputs from disposable test state. Source and
policy live in Git. Images, VM bases, package caches, credentials, and test
outputs stay outside the repository.

## Classes

| Class | Purpose | Examples | Lifecycle |
| --- | --- | --- | --- |
| Base | Stable runtime needed by many tests | Linux system packages, Node, Pi, Claude Code, agent-browser, pi-web-ui, node-pty; macOS ready VM | Version-pin in source; rebuild only when its manifest changes |
| Injected | Small, case-specific source or fixture | extensions, WebUI plugins, test scripts, prompts | Copy into one disposable guest; never bake into a base |
| Cached | Package-manager-owned reusable download/build material | mkosi incremental cache, pacman package cache, npm tarball cache, ABI-keyed npm prefix | Outside Git; content is verified by the package manager and pinned manifests |
| Ephemeral | One-off data with no reuse contract | temporary probe output, ad hoc download, generated session | Download or generate during one clone only; delete with the clone |

## Admission Rules

Put a dependency in a base only when all apply:

1. More than one case needs it, or it is needed to run the harness itself.
2. Its version is pinned in source.
3. Rebuilding or installing it materially dominates a normal test run.
4. It contains no user session, credential, personal preference, or project code.

Use injected files for code under active development. An extension or UI plugin
must not become a base dependency merely because a test needs it once. Consumer-owned cases and inputs stay in the consumer repository; `bin/test.sh --project` snapshots only the selected case and its declared inputs outside both repositories. See [consumer-tests.md](consumer-tests.md).

Use package-manager caches for registry artifacts. Do not vendor `node_modules`,
pacman package files, or native build trees into Git. A cache miss may download
at build/preparation time. Tool requirement checks and normal consumer acceptance
never install or upgrade missing tools, including on NAT-enabled Tart guests.
Linux guests must never download at runtime because they have no network device.

Treat anything not pinned and not reused as ephemeral. Do not promote a
single-use download into a shared cache without adding it to this policy.

## Current Inventory

| Artifact | Class | Owner and location |
| --- | --- | --- |
| Linux `ahsb.raw`, kernel, initrd | Base | alpha `~/ahsb-build/` or an explicitly selected `OUT` |
| Linux package and build caches | Cached | alpha `~/.cache/agent-harness-sandbox/{mkosi,pacman,build/npm-prefix}` and npm's own `~/.npm/` |
| npm dependency declaration | Source | `image-deps/package.json` and `image-deps/package-lock.json` |
| Native Linux terminal runtime | Base | `mkosi.conf`: xterm + existing Xvfb/xwininfo/fonts; `mkosi.postinst` rejects xterm versions other than `411-1`; shared by terminal consumers and producer smoke |
| Native terminal smoke script | Injected | `bin/native-terminal-smoke.sh` via case `push`; not baked into the base |
| Tart GUI seed and separately prepared runtime bases | Base | private local Tart storage; original seeds preserved, cloned per case |
| Public macOS npm tarballs | Cached | dedicated `~/.cache/agent-harness-sandbox/runtime-tarballs/darwin-arm64-<lock-sha256>/`; no host-installed packages or user npm configuration |
| Pi observer extension and WebUI plugin | Injected | repository source; Linux `PUSH`, macOS `macos-push` |
| Test runs, sessions, mock logs, generated summaries | Ephemeral | per-run `OUT/runs/`; destroyed or retained only as evidence |

## Cache Contract

`bin/build-image.sh` sets the mkosi/pacman cache paths and prepares an npm-managed prefix with `npm ci` from the committed lockfile, keyed by the Node ABI and lockfile digest. mkosi copies that prefix into the image instead of installing packages in postinstall. The caches are accelerators, not
truth: deleting them must only make the next build slower. Package versions and
native-addon reproducibility remain defined by `mkosi.conf` and
`mkosi.postinst`.

The Linux cache must be built on alpha because the prepared prefix contains Linux x86_64 native addons. A Mac cache may contain generic npm tarballs, but must not supply a
macOS-built native module to the Linux image.

## Shared Runtime Preparation and Consumer Requirements

`image-deps/` is the producer-owned, fixed tool manifest. Consumer cases may
request exact versions of supported tools in `requires.json`; they do not
supply installer commands or modify the shared manifest. `guest-runtime.mjs`
checks actual CLI entrypoints in isolated configuration, records cold-start
latency, and performs a real native PTY spawn for WebUI. The check cannot invoke
npm installation or silently replace versions. Missing/incompatible runtime is
`NOT_READY` (78), before consumer commands/assertions; successful checks are not
proof of consumer behavior or GUI readiness.

`bin/prepare-tart-runtime.sh <new-name>` prepares a distinct macOS clone using
the existing pinned host-key/SSH/no-host-sharing lifecycle. On the host,
`cache-runtime-packages.mjs` uses npm's own cache APIs to copy only declared
public-registry tarballs, verify lockfile integrity, and sanitize cached HTTP
metadata (no authorization/request headers). The destination is keyed by
platform, architecture and lock digest. Only missing artifacts are fetched;
target packages are never installed/executed on the host. Registry artifacts
are generic inputs, not a Mac-built `node_modules` bundle exported to Linux.

The guest runs `npm ci --offline --ignore-scripts` from that dedicated cache,
then explicit pinned lifecycle steps for Claude and the macOS node-pty prebuild.
Missing native prebuilds fail; there is no hidden source-build/header-download
fallback. node-pty 1.1.0's published macOS spawn-helper needs an executable-bit
repair before the real PTY check. The resulting runtime receipt records
OS/architecture, Node/ABI, tools, native smoke, timestamp and lock digest.
Only successful preparation may save a new stopped base; existing names and
original bases are never overwritten. Inputs and checksums stay in the run
artifacts, not Git. Normal test calls cannot save bases.

GUI/TCC prerequisites still come from the selected GUI seed. Runtime preparation
does not grant permissions or establish GUI acceptance; validate a fresh clone.
Projects inject their extensions/plugins during initialization, not into the
shared base. This keeps common runtime upgrades independent of project edits.

## macOS Source Injection

A macOS case can add `cases/<id>/macos-push`. Each non-comment line is:

```text
repository-relative-source:/tmp/ahsb-push/destination
```

The runner rejects absolute sources, source paths outside the repository,
directories, destination paths outside `/tmp/ahsb-push/`, and paths containing
`..`. It records the SHA-256 digest of each uploaded file in the run directory.
Files are copied only to the disposable Tart clone after SSH host-key validation.
