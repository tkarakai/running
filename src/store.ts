// Kept processes live in a hand-editable YAML file.
import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync, readFileSync, renameSync, writeFileSync, existsSync } from "node:fs";
import { parse, stringify } from "yaml";
import { untildify, tildify, type Row } from "./procs.ts";

export interface Kept {
  name: string;
  command: string; // exactly what gets typed at the prompt
  cwd: string; // stored with ~ for readability
  env?: Record<string, string>;
  note?: string;
  ports?: number[]; // informational: what it listened on when kept
  kept: string; // ISO timestamp
}

const DIR = process.env.RUNNING_CONFIG_DIR ?? join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "running");
export const KEPT_FILE = join(DIR, "kept.yaml");

const HEADER = `# Processes kept by \`running\`. Safe to edit by hand.
# command: what gets typed at the prompt; cwd: where it's run from;
# env: variables prefixed to the command when it's started.
`;

export function loadKept(): Kept[] {
  if (!existsSync(KEPT_FILE)) return [];
  const doc = parse(readFileSync(KEPT_FILE, "utf8")) as { processes?: Kept[] } | null;
  return (doc?.processes ?? []).filter((k) => k && k.command && k.cwd);
}

export function saveKept(list: Kept[]): void {
  mkdirSync(DIR, { recursive: true });
  const clean = list.map((k) => {
    const o: Partial<Kept> = { name: k.name, command: k.command, cwd: tildify(untildify(k.cwd)) };
    if (k.env && Object.keys(k.env).length) o.env = k.env;
    if (k.note) o.note = k.note;
    if (k.ports?.length) o.ports = k.ports;
    o.kept = k.kept;
    return o as Kept;
  });
  const tmp = KEPT_FILE + ".tmp";
  writeFileSync(tmp, HEADER + stringify({ processes: clean }, { lineWidth: 0 }));
  renameSync(tmp, KEPT_FILE); // atomic: a crash never leaves a half-written file
}

const norm = (s: string) => s.trim().replace(/\s+/g, " ");

/** Does this running row correspond to a kept entry? Same command, same directory. */
export function matches(k: Kept, r: Row): boolean {
  if (untildify(k.cwd) !== r.cwd) return false;
  const c = norm(k.command);
  return c === norm(r.command) || c === norm(r.argvCommand) || c === norm(r.argv.join(" "));
}

export function findKept(list: Kept[], r: Row): Kept | undefined {
  return list.find((k) => matches(k, r));
}
