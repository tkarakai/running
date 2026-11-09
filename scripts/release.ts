#!/usr/bin/env bun
// Create a GitHub release for the version in package.json.
//
//   bun run release            tag vX.Y.Z on main and publish the GitHub release
//   bun run release --dry-run  check everything and show what would happen
//
// Preconditions (checked): on `main`, clean, up to date with origin/main; the tag doesn't
// exist yet; CHANGELOG.md has a `## X.Y.Z — …` section (its body becomes the release notes).
import { $ } from "bun";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dry = process.argv.includes("--dry-run");
const root = join(import.meta.dir, "..");
process.chdir(root);

const fail = (msg: string): never => {
  console.error(`✗ ${msg}`);
  process.exit(1);
};
const ok = (msg: string) => console.log(`✓ ${msg}`);

const version: string = JSON.parse(readFileSync("package.json", "utf8")).version;
const tag = `v${version}`;

// ── git state ────────────────────────────────────────────────────────────
const branch = (await $`git rev-parse --abbrev-ref HEAD`.text()).trim();
if (branch !== "main") fail(`on branch "${branch}" — releases are made from main`);
if ((await $`git status --porcelain`.text()).trim()) fail("working tree has uncommitted changes");
await $`git fetch --quiet --tags origin main`;
const [head, remote] = [(await $`git rev-parse HEAD`.text()).trim(), (await $`git rev-parse origin/main`.text()).trim()];
if (head !== remote) fail("main differs from origin/main — pull (or merge your PR) first");
if ((await $`git tag --list ${tag}`.text()).trim()) fail(`tag ${tag} already exists — bump the version in a release PR`);
ok(`main is clean and up to date; releasing ${tag}`);

// ── release notes from CHANGELOG ─────────────────────────────────────────
const changelog = readFileSync("CHANGELOG.md", "utf8");
const start = changelog.search(new RegExp(`^## ${version.replace(/\./g, "\\.")}\\b.*$`, "m"));
if (start < 0) fail(`CHANGELOG.md has no "## ${version} — …" section`);
const afterHeading = changelog.indexOf("\n", start) + 1;
const next = changelog.slice(afterHeading).search(/^## /m);
const notes = changelog.slice(afterHeading, next < 0 ? undefined : afterHeading + next).trim();
if (!notes) fail(`the ${version} section in CHANGELOG.md is empty`);
ok(`release notes: ${notes.split("\n").length} lines from CHANGELOG.md`);

// ── checks + build ───────────────────────────────────────────────────────
await $`bun run typecheck`.quiet().catch(() => fail("typecheck failed (run `bun run typecheck`)"));
ok("typecheck");
await $`bun test`.quiet().catch(() => fail("tests failed (run `bun test`)"));
ok("tests");
await $`bun run build`.quiet().catch(() => fail("build failed (run `bun run build`)"));
const built = (await $`./dist/running --version`.text()).trim();
if (built !== version) fail(`built binary reports ${built}, expected ${version}`);
const arch = (await $`uname -m`.text()).trim() === "arm64" ? "arm64" : "x64";
const asset = `dist/running-${version}-darwin-${arch}`;
await $`cp dist/running ${asset}`;
ok(`built ${asset}`);

if (dry) {
  console.log(`\n(dry run) would tag ${tag} at ${head.slice(0, 7)}, push it, and run:`);
  console.log(`  gh release create ${tag} --verify-tag --title "running ${version}" --notes-file <CHANGELOG section> ${asset}`);
  console.log(`\n--- notes ---\n${notes}\n`);
  process.exit(0);
}

// ── tag + release ────────────────────────────────────────────────────────
await $`git tag -a ${tag} -m ${"running " + version}`;
await $`git push origin ${tag}`;
ok(`pushed tag ${tag}`);
const notesFile = join(mkdtempSync(join(tmpdir(), "running-release-")), "notes.md");
writeFileSync(notesFile, notes + "\n");
await $`gh release create ${tag} --verify-tag --title ${"running " + version} --notes-file ${notesFile} ${asset}`;
ok(`released ${tag}`);
console.log((await $`gh release view ${tag} --json url --jq .url`.text()).trim());
