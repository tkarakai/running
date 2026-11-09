#!/usr/bin/env bun
// Build the desktop app (Apple silicon, macOS 26+), in one of two variants:
//
//   official  Running.app, io.github.tkarakai.running — what releases attach; updates itself
//             from GitHub releases, so it's only installed from there.
//   dev       Running Dev.app, io.github.tkarakai.running.dev — built from this checkout, amber
//             icon, ⌘ added to its global shortcuts. Runs next to the official one.
//
//   bun scripts/build-app.ts                dist/app.noindex/Running.app (official)
//   bun scripts/build-app.ts --dmg          … plus dist/Running-X.Y.Z-arm64.dmg (what releases attach)
//   bun scripts/build-app.ts --dev --install  build Running Dev.app, replace /Applications/Running Dev.app, open it
//                                             (`bun run install-app`)
//
// Inside the bundle:
//   Contents/MacOS/Running       the SwiftUI/AppKit front-end (mac/)
//   Contents/MacOS/running-core  src/serve.ts compiled with Bun embedded — the same engine as the TUI
//   Contents/Resources/AppIcon.icns, rendered by the app itself (AppArt.swift)
// Signed ad hoc (no Apple developer account): Gatekeeper asks once on first open.
import { $ } from "bun";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

process.chdir(join(import.meta.dir, ".."));
const args = process.argv.slice(2);
const wantDmg = args.includes("--dmg");
const install = args.includes("--install");
const dev = args.includes("--dev");
if (install && !dev && !args.includes("--official")) {
  throw new Error("the official app is installed from GitHub releases (it updates itself) — `bun run install-app` installs the dev variant; pass --official to install a local official build anyway");
}
if (wantDmg && dev) throw new Error("disk images are for releases — build them without --dev");

const pkgVersion: string = process.env.RUNNING_TEST_VERSION ?? JSON.parse(readFileSync("package.json", "utf8")).version;
const version = dev ? `${pkgVersion}-dev` : pkgVersion;
const name = dev ? "Running Dev" : "Running";
// RUNNING_TEST_BUNDLE_ID / RUNNING_TEST_VERSION: rehearse an update without touching the real apps.
const bundleId = process.env.RUNNING_TEST_BUNDLE_ID ?? (dev ? "io.github.tkarakai.running.dev" : "io.github.tkarakai.running");
const dirty = (await $`git status --porcelain`.nothrow().text()).trim() !== "";
const commit = dev ? (await $`git rev-parse --short HEAD`.nothrow().text()).trim() + (dirty ? "+" : "") : "";
const build = (await $`git rev-list --count HEAD`.nothrow().text()).trim() || "1";
const step = (s: string) => console.log(`• ${s}`);

if ((await $`uname -m`.text()).trim() !== "arm64") throw new Error("build on Apple silicon");

// 1. The engine.
step("engine: bun build --compile src/serve.ts");
const define = `__BUILT_WITH_BUN__=${JSON.stringify(Bun.version)}`;
await $`bun build src/serve.ts --compile --minify --define ${define} --outfile dist/running-core`.quiet();

// 2. The app.
step("app: swift build -c release");
await $`swift build --package-path mac -c release --arch arm64`.quiet();
const bin = (await $`swift build --package-path mac -c release --arch arm64 --show-bin-path`.text()).trim();

// 3. The icon.
step("icon: render + iconutil");
const iconset = "dist/AppIcon.iconset";
rmSync(iconset, { recursive: true, force: true });
await $`${bin}/Running --render-icon ${iconset} ${dev ? "--dev" : ""}`;
await $`iconutil -c icns ${iconset} -o dist/AppIcon.icns`;

// 4. The bundle.
const app = `dist/app.noindex/${name}.app`;
step(`bundle: ${app}`);
rmSync(app, { recursive: true, force: true });
for (const d of ["MacOS", "Resources"]) mkdirSync(`${app}/Contents/${d}`, { recursive: true });
await $`cp ${bin}/Running ${app}/Contents/MacOS/Running`;
await $`cp dist/running-core ${app}/Contents/MacOS/running-core`;
await $`cp dist/AppIcon.icns ${app}/Contents/Resources/AppIcon.icns`;
writeFileSync(`${app}/Contents/PkgInfo`, "APPL????");
writeFileSync(`${app}/Contents/Info.plist`, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>${bundleId}</string>
  <key>RunningVariant</key><string>${dev ? "dev" : "official"}</string>
  <key>RunningCommit</key><string>${commit}</string>
  <key>CFBundleExecutable</key><string>Running</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppleEventsUsageDescription</key><string>Running switches to the terminal tab a process runs in, and opens new terminal windows to start your kept processes.</string>
  <key>NSHumanReadableCopyright</key><string>running ${version}${commit ? ` (${commit})` : ""}</string>
</dict>
</plist>
`);

// 5. Sign (ad hoc): the engine first, then the bundle around it.
step("sign: ad hoc");
await $`codesign --force --sign - ${app}/Contents/MacOS/running-core`.quiet();
await $`codesign --force --sign - --identifier ${bundleId} ${app}`.quiet();
await $`codesign --verify --strict ${app}`.quiet();
const reported = (await $`${app}/Contents/MacOS/running-core < /dev/null`.nothrow().quiet()).exitCode;
if (reported !== 0) throw new Error(`the signed engine doesn't start (exit ${reported})`);
const size = (await $`du -sh ${app}`.text()).split("\t")[0];
console.log(`built ${app} (${version}${commit ? ` ${commit}` : ""}, build ${build}, ${size})`);

// 6. Disk image: the app + a link to /Applications, to drag it into.
if (wantDmg) {
  const dmg = `dist/Running-${version}-arm64.dmg`;
  const stage = "dist/app.noindex/dmg";
  rmSync(stage, { recursive: true, force: true });
  rmSync(dmg, { force: true });
  mkdirSync(stage);
  await $`ditto ${app} ${stage}/Running.app`;
  await $`ln -s /Applications ${stage}/Applications`;
  await $`hdiutil create -volname ${"Running " + version} -srcfolder ${stage} -fs APFS -format ULMO -ov ${dmg}`.quiet();
  rmSync(stage, { recursive: true, force: true });
  const mb = (Number((await $`stat -f %z ${dmg}`.text()).trim()) / 1048576).toFixed(1);
  console.log(`built ${dmg} (${mb} MB)`);
}

// The build copy isn't an app to launch: keep it out of Spotlight and Launchpad (the
// `.noindex` folder does that) and out of Launch Services, so only /Applications shows up.
const lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
await $`${lsregister} -u ${resolve(app)}`.nothrow().quiet();

if (install) {
  const dest = `/Applications/${name}.app`;
  // Replace — not overwrite — the bundle: macOS caches code signatures. A copy that's still
  // running is quit by the new one as it starts (one instance per variant; the other variant
  // keeps running).
  if (existsSync(dest)) rmSync(dest, { recursive: true, force: true });
  await $`ditto ${app} ${dest}`;
  await $`open -n ${dest}`;
  console.log(`installed ${dest}`);
}
