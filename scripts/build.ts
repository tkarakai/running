#!/usr/bin/env bun
// Build `running`.
//
//   bun scripts/build.ts               dist/running            0.7 MB bundle, run by your Bun
//   bun scripts/build.ts --standalone  dist/running-standalone 85 MB, Bun runtime embedded
//
// Both record the Bun version they were built with (`running --help` shows it): the bundle
// relies on the installed Bun, and is only tested with this version.
import { $ } from "bun";
import { join } from "node:path";

const standalone = process.argv.includes("--standalone");
process.chdir(join(import.meta.dir, ".."));

const define = `__BUILT_WITH_BUN__=${JSON.stringify(Bun.version)}`;
if (standalone) {
  await $`bun build src/main.tsx --compile --minify --define ${define} --outfile dist/running-standalone`.quiet();
  console.log(`built dist/running-standalone (Bun ${Bun.version} embedded)`);
} else {
  await $`bun build src/main.tsx --target=bun --minify --define ${define} --outfile dist/running`.quiet();
  await $`chmod +x dist/running`;
  console.log(`built dist/running (bundle; expects Bun ${Bun.version})`);
}
