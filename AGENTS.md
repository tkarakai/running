# running — notes for coding agents

`running` is a macOS terminal UI (Bun + TypeScript + Ink) that lists the processes a person
started across their terminals, keeps the ones worth remembering, and starts, restarts,
focuses, peeks at and stops them. See `README.md` for behavior and `CHANGELOG.md` for history.

## Workflow (required)

- **Never commit to `main` directly.** Branch (`feat/…`, `fix/…`), open a pull request, let CI
  pass, squash-merge. The PR title becomes the commit title on `main`.
- **One agent per checkout.** If `git status` shows changes you didn't make, stop and ask —
  another session may be working here.
- Add user-visible changes to `## Unreleased` in `CHANGELOG.md` in the same PR.
- Don't bump the version in feature PRs; that happens in a release PR.

## Releases

1. Release PR: bump `version` in `package.json`, rename `## Unreleased` in `CHANGELOG.md` to
   `## X.Y.Z — YYYY-MM-DD`, merge it.
2. On an up-to-date, clean `main`: `bun run release` (try `bun run release --dry-run` first).
   It checks everything, runs typecheck + tests, builds the bundle, tags `vX.Y.Z`, and
   creates the GitHub release with the CHANGELOG section as notes and the bundle
   attached.
3. `bun run install-bin` to install it locally.

## Working on the code

- macOS only: `src/native.ts` calls libSystem through `bun:ffi`. CI tests run on macOS.
- `bun run typecheck`, `bun test`, `bun run build` — a single 0.7 MB JS file `dist/running`
  (`#!/usr/bin/env bun`), what `install-bin` installs. `bun run build:standalone` —
  `dist/running-standalone` with the 85 MB Bun runtime embedded; released alongside.
  Both record the Bun version they were built with (`scripts/build.ts`).
- Verify UI changes in a real terminal: run it in a detached tmux session
  (`tmux new-session -d -s t -x 180 -y 34 "bun src/main.tsx"`), drive it with
  `tmux send-keys`, read it with `tmux capture-pane -p`. Use `RUNNING_CONFIG_DIR` and
  `RUNNING_LOG_FILE` pointing at a temp dir so tests don't touch the user's kept list or log.
- Never kill, restart or type into the user's own processes or terminals while testing —
  start your own test processes.
- `bun run install-bin` removes the old file before copying (overwriting a compiled binary in
  place got it killed by macOS — cached code signature; harmless to keep doing).

## Bun

- Use `bun <file>`, `bun test`, `bun install`, `bun run <script>`, `bunx <pkg>` — not node,
  jest/vitest, npm/yarn/pnpm or npx.
- Prefer Bun built-ins: `bun:sqlite`, `Bun.spawn`, `Bun.which`, `Bun.file`.
