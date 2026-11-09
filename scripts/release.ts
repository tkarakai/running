#!/usr/bin/env bun
// Create a GitHub release for the version in package.json.
//
//   bun run release            tag vX.Y.Z on main and publish the GitHub release
//   bun run release --dry-run  check and build everything, show the notes, publish nothing
//
// Preconditions (checked): on `main`, clean, up to date with origin/main; the tag doesn't
// exist yet; CHANGELOG.md has a `## X.Y.Z — …` section.
//
// Three downloads are attached (Apple silicon):
//   running-X.Y.Z-macos.tar.xz                   0.7 MB bundle, needs Bun (the version it was built with)
//   running-X.Y.Z-macos-arm64-standalone.tar.xz  Bun embedded, nothing else needed
//   Running-X.Y.Z-arm64.dmg                      the desktop app (macOS 26+), see scripts/build-app.ts
import { $ } from "bun";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dry = process.argv.includes("--dry-run");
process.chdir(join(import.meta.dir, ".."));

const fail = (msg: string): never => {
  console.error(`✗ ${msg}`);
  process.exit(1);
};
const ok = (msg: string) => console.log(`✓ ${msg}`);

const version: string = JSON.parse(readFileSync("package.json", "utf8")).version;
const tag = `v${version}`;
const repo = "tkarakai/running";

// ── git state ────────────────────────────────────────────────────────────
const branch = (await $`git rev-parse --abbrev-ref HEAD`.text()).trim();
if (branch !== "main" && !dry) fail(`on branch "${branch}" — releases are made from main`);
if ((await $`git status --porcelain`.text()).trim() && !dry) fail("working tree has uncommitted changes");
if (!dry) {
  await $`git fetch --quiet --tags origin main`;
  const [head, remote] = [(await $`git rev-parse HEAD`.text()).trim(), (await $`git rev-parse origin/main`.text()).trim()];
  if (head !== remote) fail("main differs from origin/main — pull (or merge your PR) first");
}
if ((await $`git tag --list ${tag}`.text()).trim()) fail(`tag ${tag} already exists — bump the version in a release PR`);
ok(dry ? `dry run for ${tag} (git state checks relaxed)` : `main is clean and up to date; releasing ${tag}`);

// ── changelog section ────────────────────────────────────────────────────
const changelog = readFileSync("CHANGELOG.md", "utf8");
const start = changelog.search(new RegExp(`^## ${version.replace(/\./g, "\\.")}\\b.*$`, "m"));
if (start < 0) fail(`CHANGELOG.md has no "## ${version} — …" section`);
const afterHeading = changelog.indexOf("\n", start) + 1;
const next = changelog.slice(afterHeading).search(/^## /m);
const changes = changelog.slice(afterHeading, next < 0 ? undefined : afterHeading + next).trim();
if (!changes) fail(`the ${version} section in CHANGELOG.md is empty`);
ok(`changelog: ${changes.split("\n").length} lines`);

// ── checks + builds ──────────────────────────────────────────────────────
if ((await $`uname -m`.text()).trim() !== "arm64") fail("build on Apple silicon (the standalone binary is arm64)");
await $`bun run typecheck`.quiet().catch(() => fail("typecheck failed (run `bun run typecheck`)"));
ok("typecheck");
await $`bun test`.quiet().catch(() => fail("tests failed (run `bun test`)"));
await $`swift test --package-path mac`.quiet().catch(() => fail("app tests failed (run `bun run test:app`)"));
ok("tests (engine + app)");
await $`bun run build`.quiet().catch(() => fail("bundle build failed (run `bun run build`)"));
await $`bun run build:standalone`.quiet().catch(() => fail("standalone build failed (run `bun run build:standalone`)"));
for (const bin of ["dist/running", "dist/running-standalone"]) {
  const v = (await $`./${bin} --version`.text()).trim().split("\n")[0];
  if (v !== version) fail(`${bin} reports ${v}, expected ${version}`);
}
ok(`built both; each reports ${version}`);
await $`bun scripts/build-app.ts --dmg`.quiet().catch(() => fail("app build failed (run `bun run build:app --dmg`)"));
const appAsset = `dist/Running-${version}-arm64.dmg`;
const plistVersion = (await $`/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/app.noindex/Running.app/Contents/Info.plist`.text()).trim();
if (plistVersion !== version) fail(`Running.app reports ${plistVersion}, expected ${version}`);
ok(`built ${appAsset}`);

// Each archive contains a single executable named `running`.
const stage = mkdtempSync(join(tmpdir(), "running-release-"));
const bundleAsset = `dist/running-${version}-macos.tar.xz`;
const standaloneAsset = `dist/running-${version}-macos-arm64-standalone.tar.xz`;
await $`cp dist/running ${stage}/running && tar -cJf ${bundleAsset} -C ${stage} running`;
await $`cp dist/running-standalone ${stage}/running && tar -cJf ${standaloneAsset} -C ${stage} running`;
const mb = async (f: string) => (Number((await $`stat -f %z ${f}`.text()).trim()) / 1048576).toFixed(1);
ok(`archives: ${bundleAsset} (${await mb(bundleAsset)} MB), ${standaloneAsset} (${await mb(standaloneAsset)} MB), ${appAsset} (${await mb(appAsset)} MB)`);

// ── release notes ────────────────────────────────────────────────────────
const notes = `${changes}

## Downloads

**\`Running-${version}-arm64.dmg\`** — the desktop app: a menu bar app with a full window, the
same engine as the terminal UI. Apple silicon, macOS 26 (Tahoe) or later. Open the disk image
and drag **Running** to Applications.

> **First launch:** the app isn't signed by an Apple developer account, so macOS blocks the
> first open of a downloaded copy. Either right-click Running in Applications → **Open** →
> **Open**, or clear the flag once: \`xattr -dr com.apple.quarantine /Applications/Running.app\`
> (downloading with \`gh release download ${tag} --repo ${repo}\` avoids it too).

The terminal UI comes as a single executable, \`running\`, in two flavors. Put it on your PATH
(e.g. \`~/.local/bin\`), then add \`eval "$(command running init)"\` to \`~/.zshrc\`.

**\`running-${version}-macos.tar.xz\`** — small (0.7 MB), needs [Bun](https://bun.sh).
Built and tested with **Bun ${Bun.version}**; that's the version it expects to find. Older or
newer Bun versions usually work but aren't guaranteed — if it misbehaves, use the standalone
build. \`running --help\` shows both versions.

**\`running-${version}-macos-arm64-standalone.tar.xz\`** — self-contained (Bun ${Bun.version}
embedded), Apple silicon only. Nothing else to install.

> **Gatekeeper:** the standalone binary isn't signed by an Apple developer account. Downloaded
> with a browser, macOS blocks it ("can't be opened … unidentified developer"). Either download
> with \`gh release download ${tag} --repo ${repo}\`, or clear the flag once:
> \`xattr -d com.apple.quarantine running\`.
`;

if (dry) {
  console.log(`\n(dry run) would tag ${tag}, push it, create a draft release, upload all three`);
  console.log(`downloads (with retries), then publish.\n\n--- notes ---\n${notes}`);
  process.exit(0);
}

// ── tag, draft, upload (with retries), publish ───────────────────────────
await $`git tag -a ${tag} -m ${"running " + version}`;
await $`git push origin ${tag}`;
ok(`pushed tag ${tag}`);
const notesFile = join(stage, "notes.md");
writeFileSync(notesFile, notes);
// A draft first: a failed upload can be retried without losing the release.
await $`gh release create ${tag} --repo ${repo} --verify-tag --draft --title ${"running " + version} --notes-file ${notesFile}`.quiet();
ok("draft release created");
for (const asset of [appAsset, bundleAsset, standaloneAsset]) {
  for (let attempt = 1; ; attempt++) {
    const res = await $`gh release upload ${tag} --repo ${repo} --clobber ${asset}`.nothrow().quiet();
    if (res.exitCode === 0) { ok(`uploaded ${asset}`); break; }
    if (attempt === 3) fail(`upload of ${asset} failed 3 times — the draft release is kept; retry: gh release upload ${tag} --repo ${repo} --clobber ${asset}`);
    console.log(`  upload attempt ${attempt} failed, retrying…`);
    await Bun.sleep(3000 * attempt);
  }
}
await $`gh release edit ${tag} --repo ${repo} --draft=false --latest`.quiet();
ok(`published ${tag}`);
console.log((await $`gh release view ${tag} --repo ${repo} --json url --jq .url`.text()).trim());
