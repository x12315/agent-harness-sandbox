import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readlink, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const root = dirname(dirname(fileURLToPath(import.meta.url)));

test("links every declared package binary into the prepared prefix", async () => {
  const prefix = await mkdtemp("/tmp/ahsb-prefix-");
  const packageDirectory = join(prefix, "lib/node_modules/demo-package");
  await mkdir(packageDirectory, { recursive: true });
  await writeFile(join(packageDirectory, "package.json"), JSON.stringify({
    name: "demo-package",
    bin: { demo: "cli.js" },
  }));
  await writeFile(join(packageDirectory, "cli.js"), "#!/usr/bin/env node\n");
  const manifest = join(prefix, "manifest.json");
  await writeFile(manifest, JSON.stringify({ dependencies: { "demo-package": "1.0.0" } }));

  await run("node", [join(root, "bin/link-npm-prefix.mjs"), prefix, manifest]);

  assert.equal(
    await readlink(join(prefix, "bin/demo")),
    "../lib/node_modules/demo-package/cli.js",
  );
});
