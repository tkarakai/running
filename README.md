# running

See what's running across all your terminals, keep the ones worth remembering,
and start them again later exactly as you ran them.

```
 running  Processes 7   Kept 1

 Orca · 5 ──────────────────────────────────────────────────────────────────
▌   codex resume 01a1…                       :50373   ~/dev/projects/app    1h00   803M
    pi                                                ~/dev/projects/api      55m   173M
 tmux main:1.0 · 1 ──────────────────────────────────────────────────────────
  ● llama  ./llama-server -m q4.gguf -c 32768 :8080   ~/models/llama.cpp    2d3h   38.2G
 Detached · no terminal · 1 ─────────────────────────────────────────────────
    no-mistakes daemon run --root …                   ~/.no-mistakes        1h15    52M
```

## Install

```sh
bun install
bun run install-bin                                   # bundles dist/running (0.7 MB, runs with bun) -> ~/.local/bin/running
echo 'eval "$(command running init)"' >> ~/.zshrc     # shell integration, see below
```

### Shell integration

`running init` prints a little zsh code (`src/init.zsh`); `eval "$(command running init)"` in
`~/.zshrc` runs it in every new shell (`command` skips the shell function of the same name,
so the program is called). It defines:

- the **`running` shell function** — wraps the program so that "start" can `cd` your shell
  and put a command on your prompt (a separate program can't change its parent shell);
- the **command log** hook — records what you type, so jobs can be named and located.

Shells started before the line was added don't have it: open a new terminal or `exec zsh`.

## What gets listed

Out of the hundreds of processes on a Mac, only the ones you most likely started:

| kind   | rule |
|--------|------|
| job    | a process group whose leader exited but whose members live on — `bun dev` spawning detached servers shows as **one** row, `bun dev ⤷ 12 left running` |
| term   | direct child of an interactive shell (Terminal, tmux, VS Code, Orca, …) — not of a script like `bash ./dev.sh` |
| server | listens on a TCP port; folded up through wrappers (`npm run dev` → `node vite` is one row) |
| daemon | detached (`nohup`, `&` + closed terminal, brew services), user-owned, not an app/system binary |
| app    | servers belonging to GUI apps or macOS — hidden until you press `a`, then shown dimmed |

Rows are grouped by **where** they run (terminal app, tmux pane, detached), then by the
**directory** each job was started in (with its git branch). Each row is a whole job — a
process tree / process group; `→` shows its processes as an indented tree, each with its own
ports, uptime and memory. Killing a job stops all of it; `x` on one of its processes stops
just that one.

## The command log

`running init` also installs a zsh `preexec` hook that appends one line per command to
`~/.local/state/running/commands.log`: time, tty, shell pid, directory, terminal identity
(Orca terminal handle, tmux pane, TERM_PROGRAM…) and the command **as typed**. It is used
only to:

- name jobs whose launcher already exited (`bun dev`, `./start.sh`) — matched by terminal and
  microsecond start time;
- show what you typed (`zz`, `FOO=1 cmd`, pipes) instead of the kernel's argv;
- find the terminal tab a process lives in (focus / peek).

Without a log entry (shells started before the hook), the name is guessed from
`~/.zsh_history` and shown in *italics*. Commands starting with a space are not logged.
The log is pruned to 30 days once it passes 5 MB.

## Keys

**Any job or process:** `→`/`←` show / hide a job's processes · `o` open its web page (ports marked `↗` serve HTML; a job with several shows them) · `f` focus its
terminal (tmux, Orca, Terminal.app, iTerm2, WezTerm, kitty; others: bring the app forward) ·
`p` peek at recent output (terminal scrollback or the log files it writes to; `←→` between them) ·
`c` copy `cd dir && command` · `R` restart · `x` stop (SIGTERM + SIGCONT, so paused
processes stop too; again after 3s → kill -9) · `X` kill -9 now. A process that survives
kill -9 gets an explanation: a **zombie** (already dead, waiting for its parent) or stuck in
the kernel (**D-wait**). Rows also flag `paused` (Ctrl-Z) processes.

**Processes:** `space` keep · `s` sort, then `t` started · `m` memory · `c` CPU · `n` name · `r` reverse ·
`a` show app & system servers · `/` filter · `tab` Kept · `?` help. Sorting applies at every
level: apps and directories by their totals, jobs, and processes within a job; it's remembered
in `~/.config/running/settings.json`.

**Kept:** `⏎` start at your prompt · `R` restart if running · `t` start in a new tmux window · `e` edit · `d` forget

Starting from the prompt: the TUI exits, your shell `cd`s to the saved directory
and the command appears on your prompt, ready to edit or run — as if you typed it.
That needs the `running` shell function (`eval "$(command running init)"` in `~/.zshrc`,
loaded in shells started after adding it). Without it — an older shell, or `bun dev` in this
repo — `running` types `cd … && command` into the same terminal when it's Orca or tmux, and
otherwise copies it to the clipboard and prints it.
In tmux: a new window opens in the directory and the command is typed into it
(outside tmux, a detached session called `running` is used).

## Restart

`R` stops the whole job (SIGTERM, then SIGKILL after 5 s) and runs its command again:
typed into the **same terminal** when its shell is still there (tmux pane, Orca terminal),
otherwise in a new tmux window or at your prompt. The command comes from, in order: a kept
entry, an agent's resume command, the command log, the package-script variables, shell
history (marked "not verified"), or the process's own arguments.

## AI agents

For `codex`, `claude` and `pi` rows, `running` reads the harness's local session files:

| harness | live process → session | what we show |
|---------|------------------------|--------------|
| codex   | `resume <id>` in argv, else the newest thread for that directory in `~/.codex/state_5.sqlite` | title, model, tokens, branch, last activity |
| claude  | `~/.claude/sessions/<pid>.json` (written by Claude Code itself) | name, busy/idle, model, tokens |
| pi      | newest `~/.pi/agent/sessions/--<cwd>--/*.jsonl` created after the process started | first prompt, model, tokens, cost |

`p` → `←→` shows the recent conversation; keeping an agent saves its resume command;
`R` resumes the same conversation.

## Development & releases

Repository: [github.com/tkarakai/running](https://github.com/tkarakai/running) (private).
Changes go through pull requests (squash-merged, CI must pass); see [`AGENTS.md`](AGENTS.md).

Versions follow semver and are released with GitHub releases:

1. Release PR: bump `version` in `package.json` and turn `## Unreleased` in
   [`CHANGELOG.md`](CHANGELOG.md) into `## X.Y.Z — YYYY-MM-DD`; merge it.
2. On an up-to-date `main`: `bun run release --dry-run`, then `bun run release` — tags
   `vX.Y.Z` and publishes the GitHub release (CHANGELOG section as notes, the bundled program
   attached).
3. `bun run install-bin` to install it.

## Data

`~/.config/running/kept.yaml` — plain YAML, safe to edit by hand:

```yaml
processes:
  - name: llama
    command: ./llama-server -m q4.gguf -c 32768
    cwd: ~/models/llama.cpp
    env:
      CUDA_VISIBLE_DEVICES: "0"
    note: best settings so far
    ports: [8080]
    kept: 2026-11-08T20:30:00.000Z
```

When you keep a process, its environment is compared with the shell that launched
it; variables that differ (like a `FOO=1 cmd` prefix) are offered with checkboxes.
Secret-looking ones (`*_KEY`, `*_TOKEN`, …) are masked and unchecked by default.

## How it works

- `src/native.ts` — macOS kernel calls via `bun:ffi`: exact argv + environment
  (`KERN_PROCARGS2`), executable path, working directory and µs start time (`libproc`).
- `src/procs.ts` — `ps` + `lsof` snapshot, classification, grouping by process group (~60 ms).
- `src/init.zsh` + `src/hook.ts` — the shell function, the command log, history fallback.
- `src/actions.ts` — HTTP probe, focus, peek.
- `src/agents.ts` — codex / claude / pi session lookup and conversation view.
- `src/restart.ts` — restart planning and execution.
- `src/store.ts` — kept.yaml; `src/launch.ts` — prompt / tmux start.
- `src/ui/` — Ink (React for the terminal).
