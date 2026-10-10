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
at build time; Linux guests must never download at runtime because they have no
network device.

Treat anything not pinned and not reused as ephemeral. Do not promote a
single-use download into a shared cache without adding it to this policy.

## Current Inventory

| Artifact | Class | Owner and location |
| --- | --- | --- |
| Linux `ahsb.raw`, kernel, initrd | Base | alpha `~/ahsb-build/` or an explicitly selected `OUT` |
| Linux package and build caches | Cached | alpha `~/.cache/agent-harness-sandbox/{mkosi,pacman,build/npm-prefix}` and npm's own `~/.npm/` |
| npm dependency declaration | Source | `image-deps/package.json` and `image-deps/package-lock.json` |
| Tart `pi-iterm-macos26-ready` | Base | local Tart storage; cloned per macOS case |
| Pi observer extension and WebUI plugin | Injected | repository source; Linux `PUSH`, macOS `macos-push` |
| Test runs, sessions, mock logs, generated summaries | Ephemeral | per-run `OUT/runs/`; destroyed or retained only as evidence |

## Cache Contract

`bin/build-image.sh` sets the mkosi/pacman cache paths and prepares an npm-managed prefix with `npm ci` from the committed lockfile, keyed by the Node ABI and lockfile digest. mkosi copies that prefix into the image instead of installing packages in postinstall. The caches are accelerators, not
truth: deleting them must only make the next build slower. Package versions and
native-addon reproducibility remain defined by `mkosi.conf` and
`mkosi.postinst`.

The Linux cache must be built on alpha because the prepared prefix contains Linux x86_64 native addons. A Mac cache may contain generic npm tarballs, but must not supply a
macOS-built native module to the Linux image.

## macOS Source Injection

A macOS case can add `cases/<id>/macos-push`. Each non-comment line is:

```text
repository-relative-source:/tmp/ahsb-push/destination
```

The runner rejects absolute sources, source paths outside the repository,
directories, destination paths outside `/tmp/ahsb-push/`, and paths containing
`..`. It records the SHA-256 digest of each uploaded file in the run directory.
Files are copied only to the disposable Tart clone after SSH host-key validation.
