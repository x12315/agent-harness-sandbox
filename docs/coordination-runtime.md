# Responsive coordination runtime experiment

Draft review: https://github.com/x12315/agent-harness-sandbox/pull/1, based on `feat/multi-backend-cli`; paired Engine experiment: https://github.com/x12315/agent-harness/pull/4, based on `feat/catalog-resource-sync`.

This feature branch prepares a separate macOS runtime for the user's Pi coordination experiment. It does not upgrade an existing VM, modify the private selected profile, migrate sessions, or establish Linux compatibility. Existing consumer requirements pinned to Pi 0.87.1/Web UI 0.96.1 must continue using their older prepared base.

## Why these changes

- Installed host facilities use Pi 1.1.0 and Web UI 0.100.0. Web UI 0.96.1 does not contain the newer native delegated executor/independent reviewer GoalService required by the experiment.
- Pinning only the top-level Pi version allowed npm to choose incompatible 1.3.0 components under `^1.1.0`. Actual guest startup failed with missing `MCP_TYPESCRIPT_PREAMBLE`. The experimental lock now pins the Pi 1.1.0 component cohort via explicit overrides.
- A runtime passed preparation's real PTY probe but a fresh clone exposed `spawn-helper` mode 0600 and failed `posix_spawnp`. Preparation now runs `sync` before the runner immediately stops/saves the VM, ensuring executable metadata is persisted. The next fresh clone passed its actual PTY check and started the service.

## Scope

The application owns `tests/sandbox/macos-responsive-coordination` in the Engine feature branch. Sandbox continues to own VM lifetime, runtime preparation, exact dependency checking, source input hashes and evidence retrieval. No app-specific coordinator is added to the base.

Preparation uses the existing `bin/prepare-tart-runtime.sh` entry and a new unused base name, starting from an unmodified configured seed. Cached tarballs are integrity-checked; the offline install and native validation occur only in a private guest clone. Credentials and generated runtime evidence remain outside Git.

`node --test tests/coordination-runtime.test.mjs tests/guest-runtime.test.mjs` covers recipe consistency and fail-closed runtime checks; it does not replace fresh-clone native integration evidence.

## Evidence status

- A fresh stopped base was prepared successfully with Pi 1.1.0/Web UI 0.100.0 and a real native PTY probe.
- Subsequent fresh clones passed the application-owned `macos-responsive-coordination` case, including actual plugin receipt/classification while a native worker was held, timer checkpoints, native fail/retry/pass, whole-objective coverage repair, pause/resume and cancellation. The final stronger case launched real native bash tool processes, answered a foreground question while a tool PID was alive, and verified those PIDs stopped after pause/cancel.
- Final recorded run: `20261020T115819Z-11695`; consumer source hashes matched the final Engine feature worktree. The bounded guest-local provider handled 36 requests and recorded zero external attempts. This is real runtime/protocol/tool-process evidence, **not** real-model intent accuracy or a complete production rollout.
- The macOS path is NAT, not the Linux no-NIC airgap. No Linux build/run or cross-Mac acceptance is claimed here.
