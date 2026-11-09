#!/usr/bin/env bun
// Build the desktop app, Running.app (Apple silicon, macOS 26+).
//
//   bun scripts/build-app.ts          dist/Running.app
//   bun scripts/build-app.ts --dmg    … plus dist/Running-X.Y.Z-arm64.dmg (what releases attach)
//   bun scripts/build-app.ts --install … then replace /Applications/Running.app and open it
//
// Inside the bundle:
//   Contents/MacOS/Running       the SwiftUI/AppKit front-end (mac/)
//   Contents/MacOS/running-core  src/serve.ts compiled with Bun embedded — the same engine as the TUI
//   Contents/Resources/AppIcon.icns, rendered by the app itself (AppArt.swift)
// Signed ad hoc (no Apple developer account): Gatekeeper asks once on first open.
import { $ } from "bun";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

process.chdir(join(import.meta.dir, ".."));
const args = process.argv.slice(2);
const wantDmg = args.includes("--dmg");
const install = args.includes("--install");

const version: string = JSON.parse(readFileSync("package.json", "utf8")).version;
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
await $`${bin}/Running --render-icon ${iconset}`;
await $`iconutil -c icns ${iconset} -o dist/AppIcon.icns`;

// 4. The bundle.
step("bundle: dist/Running.app");
const app = "dist/Running.app";
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
  <key>CFBundleName</key><string>Running</string>
  <key>CFBundleDisplayName</key><string>Running</string>
  <key>CFBundleIdentifier</key><string>io.github.tkarakai.running</string>
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
  <key>NSHumanReadableCopyright</key><string>running ${version}</string>
</dict>
</plist>
`);

// 5. Sign (ad hoc): the engine first, then the bundle around it.
step("sign: ad hoc");
await $`codesign --force --sign - ${app}/Contents/MacOS/running-core`.quiet();
await $`codesign --force --sign - --identifier io.github.tkarakai.running ${app}`.quiet();
await $`codesign --verify --strict ${app}`.quiet();
const reported = (await $`${app}/Contents/MacOS/running-core < /dev/null`.nothrow().quiet()).exitCode;
if (reported !== 0) throw new Error(`the signed engine doesn't start (exit ${reported})`);
const size = (await $`du -sh ${app}`.text()).split("\t")[0];
console.log(`built ${app} (${version}, build ${build}, ${size})`);

// 6. Disk image: the app + a link to /Applications, to drag it into.
if (wantDmg) {
  const dmg = `dist/Running-${version}-arm64.dmg`;
  const stage = "dist/dmg";
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

if (install) {
  const dest = "/Applications/Running.app";
  // Quit a running copy, then replace (not overwrite) the bundle: macOS caches code signatures.
  await $`osascript -e ${'tell application id "io.github.tkarakai.running" to quit'}`.nothrow().quiet();
  await Bun.sleep(800);
  await $`pkill -x Running`.nothrow().quiet();
  if (existsSync(dest)) rmSync(dest, { recursive: true, force: true });
  await $`ditto ${app} ${dest}`;
  await $`open ${dest}`;
  console.log(`installed ${dest}`);
}
