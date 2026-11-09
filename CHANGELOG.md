# Changelog

All notable changes to `running`. Versions follow [semver](https://semver.org);
the version is in `package.json` and shown in the TUI header and by `running --version`.

## 0.4.0 — 2026-11-08

### Changed
- **Jobs are trees.** A job's processes are listed under it as indented rows (`→` show,
  `←` hide / back to the job) with their own ports, uptime, memory and working directory
  (relative to the job's). Each can be opened (`o`), peeked at (`p` — its own log file) and
  stopped (`x`, just that process and what's below it); keep and restart stay job-level.
- `o` on a job with several web pages now expands it and puts the cursor on the first page,
  instead of opening a numbered chooser (removed).
- **Grouped by directory** within each app section: a full-width header per starting
  directory with its git branch (`⎇`), jobs indented below. The per-row directory column is
  gone, leaving the command more room.
- Details pane summarizes a job's web pages instead of listing every URL.

## 0.3.0 — 2026-11-08

### Added
- **Restart** (`R`): stop a job and run its command again — typed into the same tmux pane or
  Orca terminal when its shell is still there, otherwise in a new tmux window or at your
  prompt. Works for kept entries, typed commands, package scripts and agents.
- **AI agents** (codex, claude, pi): rows show the conversation title, working/idle state and
  time since last activity; details show model, tokens, cost (pi), git branch and session.
  Read from the harnesses' own local files.
- Agent **conversation view**: `p` then `←→` reads the recent conversation and tool calls.
- Keeping an agent saves a clean **resume command** (`codex resume <id>`, `claude --resume <id>`,
  `pi --session <id>`); restarting an agent resumes the same conversation.
- Version shown in the header; `running --version`; this changelog; unit tests (`bun test`).

### Fixed
- A job whose launcher exited could be named after an unrelated command typed in another
  terminal (`claude` instead of `bun dev`). Package-script jobs are now identified from the
  `npm_lifecycle_event`/`npm_execpath` variables their processes carry, and a shell-history
  guess is only used when it names a program that is actually among the processes.
- Port probes no longer leave idle keep-alive connections open to local servers.

## 0.2.0 — 2026-11-08

### Added
- Jobs grouped by **process group**: a command that exited but left processes running
  (`bun dev` → detached dev servers) is one row, `⤷ N left running`.
- zsh **command log** (`preexec` hook, installed by `running init`): the exact typed command,
  directory and terminal identity — used to name and locate processes.
- Web page detection on listening ports (`↗`), `o` to open (chooser for several).
- `f` focus the process's terminal (tmux, Orca, Terminal.app, iTerm2, WezTerm, kitty).
- `p` peek at recent output (terminal scrollback or the log files a process writes to).
- `c` copy `cd dir && command`; `?` help.
- Active tab highlighted; app & system rows dimmed in the "all" view.

### Fixed
- Scripts (`bash ./dev-start.sh`) were treated as interactive shells.
- User-installed language runtimes (Python.framework) were treated as system binaries.
- tmux pane lookup broken by tmux ≥3.5 rewriting tabs in format output.
- Typed-command matching uses microsecond process start times.

## 0.1.0 — 2026-11-08

First version: process list grouped by where it runs (terminal / tmux / detached / apps),
keep processes to `~/.config/running/kept.yaml` with optional environment variables, kill,
start a kept process at your prompt or in a new tmux window.
