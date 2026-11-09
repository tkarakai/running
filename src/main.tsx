#!/usr/bin/env bun
import { render } from "ink";
import { writeSync } from "node:fs";
import { App, type ExitAction } from "./ui/App.tsx";
import { KEPT_FILE } from "./store.ts";
import { LOG_FILE, SHELL_INIT } from "./hook.ts";
import pkg from "../package.json" with { type: "json" };


const arg = process.argv[2];
if (arg === "--init" || arg === "init") {
  process.stdout.write(SHELL_INIT);
  process.exit(0);
}
if (arg === "--version" || arg === "-v") {
  console.log(pkg.version);
  process.exit(0);
}
if (arg === "--help" || arg === "-h") {
  console.log(`running ${pkg.version} — see what's running, keep what matters, start it again.

  running            open the TUI
  running init       print the zsh setup (add  eval "$(command running init)"  to ~/.zshrc)

Kept processes: ${KEPT_FILE}
Command log:    ${LOG_FILE}`);
  process.exit(0);
}
if (!process.stdout.isTTY) {
  console.error("running: needs an interactive terminal");
  process.exit(1);
}

// Alternate screen, like vim/htop: your scrollback is untouched on exit.
// Synchronous writes: leaving the alternate screen must happen before anything we print after it.
let restored = false;
const restore = () => {
  if (restored) return;
  restored = true;
  writeSync(1, "\x1b[?25h\x1b[?1049l");
};
writeSync(1, "\x1b[?1049h\x1b[H\x1b[?25l");
process.on("exit", restore);

let action: ExitAction = {};
const app = render(<App onExit={(a) => (action = a)} />, { exitOnCtrlC: false, incrementalRendering: false, maxFps: 30 });
await app.waitUntilExit();
restore();
if (action.print) {
  // writeSync: process.exit would otherwise drop buffered output.
  writeSync(1, `\n  ${action.print}\n\n  ${action.copied ? "Copied to the clipboard. " : ""}The \`running\` shell function isn't loaded in this terminal,\n  so it can't be put on your prompt: open a new terminal or run \`exec zsh\`\n  (~/.zshrc needs: eval "$(command running init)").\n\n`);
}
process.exit(0);
