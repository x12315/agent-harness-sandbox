#!/usr/bin/env node
import { mkdir, readFile, symlink, unlink } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";

const [prefix, manifestPath] = process.argv.slice(2);
if (!prefix || !manifestPath) {
  throw new Error("usage: link-npm-prefix.mjs <prefix> <package.json>");
}

const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const binDirectory = resolve(prefix, "bin");
await mkdir(binDirectory, { recursive: true });

for (const packageName of Object.keys(manifest.dependencies ?? {})) {
  const packageDirectory = resolve(prefix, "lib/node_modules", ...packageName.split("/"));
  const packageManifest = JSON.parse(
    await readFile(resolve(packageDirectory, "package.json"), "utf8"),
  );
  const bins = typeof packageManifest.bin === "string"
    ? { [packageName.split("/").at(-1)]: packageManifest.bin }
    : packageManifest.bin ?? {};

  for (const [name, target] of Object.entries(bins)) {
    const destination = resolve(binDirectory, name);
    await unlink(destination).catch(() => {});
    await symlink(relative(dirname(destination), resolve(packageDirectory, target)), destination);
  }
}
