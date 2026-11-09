// Starting a kept process. Two ways, both "as if you typed it":
//  - prompt: the TUI exits, the `running` shell function cd's to the directory
//    and puts the command on your prompt (zsh `print -z`), ready to edit/Enter.
//  - tmux:   a new tmux window opens in the directory and the command is typed
//    into it, so it lands in that shell's history and survives the TUI.
import { shellQuote, untildify } from "./procs.ts";
import type { Kept } from "./store.ts";
import { writeFileSync } from "node:fs";

/** The full line to type: env prefix + command. */
export function commandLine(k: Kept): string {
  const env = Object.entries(k.env ?? {}).map(([key, v]) => `${key}=${shellQuote(v)}`);
  return [...env, k.command].join(" ");
}

export const ACTION_FILE = process.env.RUNNING_ACTION_FILE;

/** Hand a directory + command line to the wrapping shell function. False if not wrapped. */
export function promptLine(dir: string, line: string): boolean {
  if (!ACTION_FILE) return false;
  writeFileSync(ACTION_FILE, `${dir}\n${line}\n`);
  return true;
}

export const toPrompt = (k: Kept) => promptLine(untildify(k.cwd), commandLine(k));

function tmux(args: string[]): { ok: boolean; out: string } {
  const p = Bun.spawnSync(["tmux", ...args], { stdout: "pipe", stderr: "pipe" });
  return { ok: p.exitCode === 0, out: (p.exitCode === 0 ? p.stdout : p.stderr).toString().trim() };
}

const SESSION = "running";

/** Open a tmux window in the kept dir and type the command. Returns a status message. */
export function toTmux(k: Kept): { ok: boolean; message: string } {
  if (!Bun.which("tmux")) return { ok: false, message: "tmux is not installed" };
  const cwd = untildify(k.cwd);
  const name = k.name.replace(/[.:]/g, "-").slice(0, 30);
  const inside = !!process.env.TMUX;
  let pane: { ok: boolean; out: string };
  if (inside) {
    pane = tmux(["new-window", "-d", "-P", "-F", "#{pane_id}", "-c", cwd, "-n", name]);
  } else if (tmux(["has-session", "-t", SESSION]).ok) {
    pane = tmux(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", `${SESSION}:`, "-c", cwd, "-n", name]);
  } else {
    pane = tmux(["new-session", "-d", "-P", "-F", "#{pane_id}", "-s", SESSION, "-c", cwd, "-n", name]);
  }
  if (!pane.ok) return { ok: false, message: `tmux: ${pane.out}` };
  const sent = tmux(["send-keys", "-t", pane.out, "-l", commandLine(k)]);
  if (!sent.ok) return { ok: false, message: `tmux: ${sent.out}` };
  tmux(["send-keys", "-t", pane.out, "Enter"]);
  return {
    ok: true,
    message: inside
      ? `started in tmux window "${name}"`
      : `started in tmux session "${SESSION}", window "${name}" — attach: tmux attach -t ${SESSION}`,
  };
}
