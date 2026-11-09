import { Box, Text, useApp, useInput, useStdout } from "ink";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { basename } from "node:path";
import { collect, killRow, tildify, base, type Row } from "../procs.ts";
import { findKept, loadKept, matches, saveKept, type Kept } from "../store.ts";
import { envChoices, prefixVars } from "../env.ts";
import { commandLine, promptLine, toPrompt, toTmux } from "../launch.ts";
import { focus, openUrl, peek, probe, type Peek, type Probe } from "../actions.ts";
import { pruneLog } from "../hook.ts";
import { agentInfo, fmtTokens, transcriptTail, type AgentInfo } from "../agents.ts";
import { planRestart, runRestart } from "../restart.ts";
import pkg from "../../package.json" with { type: "json" };
import { Form, type FormValues } from "./Form.tsx";
import { ago, c, fit, fmtMem, fmtUptime } from "./theme.ts";

type Mode = "procs" | "kept";
type Item =
  | { type: "header"; label: string; tag?: string; count: number; muted: boolean }
  | { type: "row"; row: Row; depth: number }
  | { type: "kept"; kept: Kept; index: number; live?: Row };

type Confirm = { text: string; onYes: () => void };
type Overlay =
  | { type: "keep"; row: Row }
  | { type: "edit"; index: number }
  | { type: "peek"; pid: number; source?: string }
  | { type: "urls"; pid: number }
  | { type: "help" };

export interface ExitAction {
  print?: string; // shown after the TUI closes (fallback when not run via the shell function)
}

const KIND_RANK = { term: 0, server: 1, daemon: 2, app: 3 } as const;
const REFRESH_MS = 2000;
const STUCK_AFTER_MS = 3000;
const DETAILS_H = 7;

type Probes = Map<string, Probe | null | "pending">; // key: `${row.pid}:${port}`
const probeKey = (r: Row, port: number) => `${r.pid}:${port}`;

/** A row's web pages (HTML over HTTP), best first. */
function webPages(r: Row, probes: Probes): Probe[] {
  return r.ports
    .map((p) => probes.get(probeKey(r, p)))
    .filter((p): p is Probe => !!p && p !== "pending" && p.web);
}

export function App(props: { onExit: (a: ExitAction) => void }) {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [size, setSize] = useState({ w: stdout.columns, h: stdout.rows });
  useEffect(() => {
    const on = () => setSize({ w: stdout.columns, h: stdout.rows });
    stdout.on("resize", on);
    return () => void stdout.off("resize", on);
  }, [stdout]);

  const [mode, setMode] = useState<Mode>("procs");
  const [rows, setRows] = useState<Row[] | null>(null);
  const [kept, setKept] = useState<Kept[]>(() => loadKept());
  const [probes, setProbes] = useState<Probes>(new Map());
  const [showAll, setShowAll] = useState(false);
  const [filter, setFilter] = useState("");
  const [filtering, setFiltering] = useState(false);
  const [confirm, setConfirm] = useState<Confirm | null>(null);
  const [overlay, setOverlay] = useState<Overlay | null>(null);
  const [peekData, setPeekData] = useState<Peek | null>(null);
  const [status, setStatus] = useState<{ text: string; tone: "ok" | "warn" | "err" } | null>(null);
  const [stopping, setStopping] = useState<Map<number, { at: number; force: boolean }>>(new Map());
  const [sel, setSel] = useState<{ procs: number | null; kept: number }>({ procs: null, kept: 0 });
  const lastPos = useRef({ procs: 0, kept: 0 });
  const [top, setTop] = useState(0);

  // ── data ───────────────────────────────────────────────────────────────
  useEffect(() => pruneLog(), []);
  const busy = useRef(false);
  const refresh = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    try {
      const next = await collect({ selfPid: process.pid });
      setRows(next);
      setKept(loadKept()); // pick up hand edits to kept.yaml
      setStopping((s) => {
        const n = new Map(s);
        for (const pid of n.keys()) if (!next.some((r) => r.pid === pid)) n.delete(pid);
        return n;
      });
    } catch (e) {
      setStatus({ text: `refresh failed: ${(e as Error).message}`, tone: "err" });
    } finally {
      busy.current = false;
    }
  }, []);
  useEffect(() => {
    refresh();
    const t = setInterval(refresh, REFRESH_MS);
    return () => clearInterval(t);
  }, [refresh]);

  // Probe each new listening port once: is it a web page?
  useEffect(() => {
    if (!rows) return;
    const todo = rows.flatMap((r) => r.listen.filter((l) => !probes.has(probeKey(r, l.port))).map((l) => ({ r, l })));
    if (!todo.length) return;
    setProbes((m) => {
      const n = new Map(m);
      for (const { r, l } of todo) n.set(probeKey(r, l.port), "pending");
      return n;
    });
    for (const { r, l } of todo)
      probe(l).then((res) => setProbes((m) => new Map(m).set(probeKey(r, l.port), res)));
  }, [rows]);

  const flash = (text: string, tone: "ok" | "warn" | "err" = "ok") => setStatus({ text, tone });
  useEffect(() => {
    if (!status) return;
    const t = setTimeout(() => setStatus(null), 5000);
    return () => clearTimeout(t);
  }, [status]);

  const persist = (list: Kept[]) => {
    saveKept(list);
    setKept(list);
  };

  // ── derived lists ──────────────────────────────────────────────────────
  const q = filter.toLowerCase();
  const keptOf = useCallback((r: Row) => findKept(kept, r), [kept]);
  const liveOf = useCallback((k: Kept) => rows?.find((r) => matches(k, r)), [rows]);
  const rowByPid = (pid: number) => rows?.find((r) => r.pid === pid);

  const items: Item[] = useMemo(() => {
    if (mode === "kept") {
      return kept
        .map((k, index) => ({ type: "kept" as const, kept: k, index, live: liveOf(k) }))
        .filter(({ kept: k }) => !q || `${k.name} ${k.command} ${k.cwd} ${k.note ?? ""} ${(k.ports ?? []).join(" ")}`.toLowerCase().includes(q));
    }
    if (!rows) return [];
    const visible = rows.filter((r) => {
      if (!showAll && r.kind === "app") return false;
      if (!q) return true;
      const k = keptOf(r);
      return `${r.command} ${r.cwd} ${r.where} ${r.ports.join(" ")} ${k?.name ?? ""}`.toLowerCase().includes(q);
    });
    const sections = new Map<string, Row[]>();
    for (const r of visible) sections.set(r.where, [...(sections.get(r.where) ?? []), r]);
    const rank = (rs: Row[]) => Math.min(...rs.map((r) => KIND_RANK[r.kind]));
    const ordered = [...sections.entries()].sort(([a, ra], [b, rb]) => rank(ra) - rank(rb) || a.localeCompare(b));

    const out: Item[] = [];
    for (const [where, rs] of ordered) {
      const isApp = rs.every((r) => r.kind === "app");
      out.push({
        type: "header",
        label: where === "detached" ? "Detached" : where,
        tag: where === "detached" ? "no terminal" : isApp ? "app" : undefined,
        count: rs.length,
        muted: isApp,
      });
      const pids = new Set(rs.map((r) => r.pid));
      const byOldest = (a: Row, b: Row) => b.etimeSec - a.etimeSec;
      const place = (r: Row, depth: number) => {
        out.push({ type: "row", row: r, depth });
        rs.filter((x) => x.parentRow === r.pid).sort(byOldest).forEach((x) => place(x, depth + 1));
      };
      rs.filter((r) => r.parentRow === undefined || !pids.has(r.parentRow)).sort(byOldest).forEach((r) => place(r, 0));
    }
    return out;
  }, [mode, rows, kept, showAll, q, keptOf, liveOf]);

  const selectable = useMemo(() => items.flatMap((it, i) => (it.type === "header" ? [] : [i])), [items]);

  // Keep the selection on the same process across refreshes.
  let pos =
    mode === "procs"
      ? selectable.findIndex((i) => (items[i] as { row: Row }).row.pid === sel.procs)
      : selectable.findIndex((i) => (items[i] as { index: number }).index === sel.kept);
  if (pos < 0) pos = Math.min(lastPos.current[mode], Math.max(0, selectable.length - 1));
  lastPos.current[mode] = pos;
  const cursorItem = selectable.length ? items[selectable[pos]!] : undefined;
  const curRow = cursorItem?.type === "row" ? cursorItem.row : cursorItem?.type === "kept" ? cursorItem.live : undefined;
  const curKept = cursorItem?.type === "kept" ? cursorItem.kept : curRow ? keptOf(curRow) : undefined;

  const select = (p: number) => {
    const clamped = Math.max(0, Math.min(selectable.length - 1, p));
    const it = items[selectable[clamped]!];
    if (!it) return;
    lastPos.current[mode] = clamped;
    if (it.type === "row") setSel((s) => ({ ...s, procs: it.row.pid }));
    if (it.type === "kept") setSel((s) => ({ ...s, kept: it.index }));
  };

  // ── layout ─────────────────────────────────────────────────────────────
  const W = Math.max(60, size.w);
  const H = Math.max(18, size.h - 1); // one spare line: Ink clears the screen when output fills it
  const listH = H - 1 /*header*/ - 1 /*gap*/ - DETAILS_H - 1 /*footer*/;
  const bodyH = listH + DETAILS_H;

  // Scroll so the cursor (and its section header) stay visible.
  const cursorIdx = selectable[pos] ?? 0;
  let viewTop = top;
  if (cursorIdx < viewTop) viewTop = cursorIdx > 0 && items[cursorIdx - 1]?.type === "header" ? cursorIdx - 1 : cursorIdx;
  if (cursorIdx >= viewTop + listH) viewTop = cursorIdx - listH + 1;
  viewTop = Math.max(0, Math.min(viewTop, Math.max(0, items.length - listH)));
  if (viewTop !== top) queueMicrotask(() => setTop(viewTop));

  // ── peek: live-refresh while open ──────────────────────────────────────
  const peekOverlay = overlay?.type === "peek" ? overlay : null;
  useEffect(() => {
    if (!peekOverlay) return setPeekData(null);
    const load = () => {
      const r = rowByPid(peekOverlay.pid);
      if (!r) return;
      const src = peekOverlay.source;
      const data = peek(r, Math.max(200, bodyH), src === TRANSCRIPT ? undefined : src);
      const a = agentInfo(r);
      if (a?.transcript) data.sources = [TRANSCRIPT, ...data.sources];
      if (src === TRANSCRIPT && a) setPeekData({ ...data, title: `${a.harness} conversation — ${a.transcript}`, lines: transcriptTail(a, bodyH) });
      else setPeekData(data);
    };
    load();
    const t = setInterval(load, 2500);
    return () => clearInterval(t);
  }, [peekOverlay?.pid, peekOverlay?.source]);

  // ── actions ────────────────────────────────────────────────────────────
  const askKill = (r: Row) => {
    const st = stopping.get(r.pid);
    const force = !!st && Date.now() - st.at > STUCK_AFTER_MS;
    const label = r.command.length > 40 ? r.command.slice(0, 39) + "…" : r.command;
    setConfirm({
      text: `${force ? "Force-kill (SIGKILL)" : "Stop"} ${label} — ${r.pids.length > 1 ? `${r.pids.length} processes` : `pid ${r.pid}`}?`,
      onYes: () => {
        const n = killRow(r, force ? "SIGKILL" : "SIGTERM");
        setStopping((s) => new Map(s).set(r.pid, { at: Date.now(), force }));
        flash(n ? `sent ${force ? "SIGKILL" : "SIGTERM"}` : "already gone", "warn");
        setTimeout(refresh, 400);
      },
    });
  };

  /** Put a line on the user's prompt (via the shell function), or print + copy it as a fallback. */
  const handToShell = (dir: string, line: string) => {
    if (promptLine(dir, line)) return exit();
    const full = dir ? `cd ${tildify(dir)} && ${line}` : line;
    Bun.spawnSync(["pbcopy"], { stdin: Buffer.from(full) });
    props.onExit({ print: full });
    exit();
  };

  const startKept = (k: Kept, how: "prompt" | "tmux") => {
    const go = () => {
      if (how === "tmux") {
        const res = toTmux(k);
        flash(res.message, res.ok ? "ok" : "err");
        setTimeout(refresh, 1000);
        return;
      }
      if (toPrompt(k)) return exit();
      handToShell(k.cwd, commandLine(k));
    };
    const live = liveOf(k);
    if (live) setConfirm({ text: `"${k.name}" is already running (${live.where}). Start another?`, onYes: go });
    else go();
  };

  const openWeb = (r: Row) => {
    const pages = webPages(r, probes);
    const pending = r.ports.some((p) => probes.get(probeKey(r, p)) === "pending");
    if (pages.length === 1) { openUrl(pages[0]!.url); return flash(`opened ${pages[0]!.url}`); }
    if (pages.length > 1) return setOverlay({ type: "urls", pid: r.pid });
    if (!r.ports.length) return flash("not listening on any port", "warn");
    flash(pending ? "still checking its ports…" : "its ports don't serve web pages (API or other protocol)", "warn");
  };

  const doFocus = (r: Row) => {
    const res = focus(r);
    if (res.prompt) return handToShell("", res.prompt);
    flash(res.message, res.ok ? "ok" : "warn");
  };

  const restart = (r: Row, k?: Kept) => {
    const res = planRestart(r, k);
    if (!res.ok) return flash(res.reason, "warn");
    const p = res.plan;
    const short = p.line.length > 60 ? p.line.slice(0, 59) + "…" : p.line;
    setConfirm({
      text: `Restart: stop ${r.pids.length > 1 ? `${r.pids.length} processes` : "it"}, then run \`${short}\` in ${p.whereLabel} (${p.why})${p.exact ? "" : " — not verified"}?`,
      onYes: () => {
        setStopping((s) => new Map(s).set(r.pid, { at: Date.now(), force: false }));
        const name = k?.name ?? agentInfo(r)?.harness ?? base(p.line.split(/\s+/)[0] ?? "restart");
        runRestart(r, p, name, (msg) => flash(msg, "warn")).then((out) => {
          if (out.prompt) return handToShell(out.prompt.cwd, out.prompt.line);
          flash(out.message, out.ok ? "ok" : "err");
          setTimeout(refresh, 800);
        });
      },
    });
  };

  const copy = (r: Row) => {
    const line = `cd ${shellPath(r.cwd)} && ${r.command}`;
    Bun.spawnSync(["pbcopy"], { stdin: Buffer.from(line) });
    flash(`copied: ${line}`);
  };

  useInput(
    (input, key) => {
      if (confirm) {
        if (input === "y" || input === "Y") confirm.onYes();
        setConfirm(null);
        return;
      }
      if (filtering) {
        if (key.escape) { setFilter(""); setFiltering(false); return; }
        if (key.return) { setFiltering(false); return; }
        if (key.backspace || key.delete) { setFilter((f) => f.slice(0, -1)); return; }
        if (!key.upArrow && !key.downArrow && input && !key.ctrl && !key.meta) { setFilter((f) => f + input.replace(/[\x00-\x1f]/g, "")); return; }
      }
      if (input === "q" || (key.ctrl && input === "c")) return exit();
      if (input === "?") return setOverlay({ type: "help" });
      if (key.escape && filter) return setFilter("");
      if (key.tab || input === "\t") { setMode((m) => (m === "procs" ? "kept" : "procs")); setTop(0); setFilter(""); return; }
      if (key.upArrow || input === "k") return select(pos - 1);
      if (key.downArrow || input === "j") return select(pos + 1);
      if (key.pageUp) return select(pos - listH);
      if (key.pageDown) return select(pos + listH);
      if (key.home || input === "g") return select(0);
      if (key.end || input === "G") return select(selectable.length - 1);
      if (input === "/") { setFiltering(true); return; }
      if (input === "r") { refresh(); return flash("refreshed"); }

      // Actions on a live process work in both tabs.
      if (curRow) {
        if (input === "o") return openWeb(curRow);
        if (input === "f") return doFocus(curRow);
        if (input === "p") return setOverlay({ type: "peek", pid: curRow.pid });
        if (input === "c") return copy(curRow);
        if (input === "x") return askKill(curRow);
        if (input === "R") return restart(curRow, curKept);
      }

      if (mode === "procs") {
        if (input === "a") { setShowAll((s) => !s); return flash(showAll ? "hiding app & system servers" : "showing app & system servers too"); }
        if (curRow && input === " ") {
          const k = keptOf(curRow);
          if (k) return flash(`already kept as "${k.name}" — edit it in the Kept tab`, "warn");
          return setOverlay({ type: "keep", row: curRow });
        }
      } else {
        const it = cursorItem?.type === "kept" ? cursorItem : undefined;
        if (!it) return;
        if (key.return) return startKept(it.kept, "prompt");
        if (input === "t") return startKept(it.kept, "tmux");
        if (input === "e") return setOverlay({ type: "edit", index: it.index });
        if (input === "R") return startKept(it.kept, "prompt");
        if (input === "x" || input === "o" || input === "f" || input === "p") return flash("not running", "warn");
        if (input === "d")
          return setConfirm({
            text: `Forget "${it.kept.name}"? (the process itself is not touched)`,
            onYes: () => { persist(kept.filter((_, i) => i !== it.index)); flash(`forgot "${it.kept.name}"`, "warn"); },
          });
      }
    },
    { isActive: !overlay },
  );

  // Keys for the simple overlays (help, peek, url chooser). Forms handle their own.
  useInput(
    (input, key) => {
      if (!overlay) return;
      if (key.escape || input === "q" || (overlay.type === "help" && input === "?")) return setOverlay(null);
      if (overlay.type === "peek") {
        const srcs = peekData?.sources ?? [];
        if ((key.leftArrow || key.rightArrow) && srcs.length) {
          const cur = overlay.source ? srcs.indexOf(overlay.source) : -1;
          const next = key.rightArrow ? cur + 1 : cur - 1;
          // index -1 = the terminal view (if any), then the agent conversation, then each log file
          setOverlay({ type: "peek", pid: overlay.pid, source: next < 0 || next >= srcs.length ? undefined : srcs[next] });
        }
        if (input === "f") { const r = rowByPid(overlay.pid); if (r) { setOverlay(null); doFocus(r); } }
      }
      if (overlay.type === "urls") {
        const r = rowByPid(overlay.pid);
        const pages = r ? webPages(r, probes) : [];
        const n = Number(input);
        if (n >= 1 && n <= pages.length) { openUrl(pages[n - 1]!.url); setOverlay(null); flash(`opened ${pages[n - 1]!.url}`); }
        if (input === "a") { pages.forEach((p) => openUrl(p.url)); setOverlay(null); flash(`opened ${pages.length} pages`); }
      }
    },
    { isActive: !!overlay && overlay.type !== "keep" && overlay.type !== "edit" },
  );

  // ── forms ──────────────────────────────────────────────────────────────
  const formFor = (o: Extract<Overlay, { type: "keep" | "edit" }>) => {
    const toEnv = (v: FormValues) => Object.fromEntries(v.env.filter((e) => e.selected).map((e) => [e.key, e.value]));
    if (o.type === "keep") {
      const r = o.row;
      const agent = agentInfo(r);
      const words = r.command.split(/\s+/).filter((w) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(w));
      const prog = base(words[0] ?? "");
      const sub = /^(npm|pnpm|yarn|bun|just|make)$/.test(prog) ? words.filter((a) => a !== "run")[1] : undefined;
      return {
        title: r.leaderGone
          ? `Keep "${r.command}" — the command that started ${r.pids.length === 1 ? "this process" : `these ${r.pids.length} processes`}`
          : "Keep this process",
        initial: {
          // An agent: keep the conversation (a clean resume command), named after its title.
          name: agent?.title ? `${agent.harness}: ${agent.title.slice(0, 40)}` : `${basename(r.cwd) || prog} ${sub ?? prog}`.trim(),
          command: agent?.resume ?? r.command,
          cwd: tildify(r.cwd),
          note: "",
          env: agent ? [] : envChoices(r.env, r.baseEnv, process.env, prefixVars(r.command)),
        },
        save: (v: FormValues) => {
          persist([...kept, { name: v.name || prog, command: v.command, cwd: v.cwd, env: toEnv(v), note: v.note, ports: r.ports, kept: new Date().toISOString() }]);
          flash(`kept "${v.name}" ✓`);
        },
      };
    }
    const k = kept[o.index]!;
    return {
      title: `Edit "${k.name}"`,
      initial: {
        name: k.name, command: k.command, cwd: k.cwd, note: k.note ?? "",
        env: Object.entries(k.env ?? {}).map(([key, value]) => ({ key, value, secret: false, selected: true })),
      },
      save: (v: FormValues) => {
        persist(kept.map((x, i) => (i === o.index ? { ...x, name: v.name, command: v.command, cwd: v.cwd, note: v.note, env: toEnv(v) } : x)));
        flash(`saved "${v.name}" ✓`);
      },
    };
  };

  // ── render ─────────────────────────────────────────────────────────────
  const procCount = rows ? rows.filter((r) => showAll || r.kind !== "app").length : 0;
  const header = (
    <Box width={W}>
      <Text color={c.accent} bold> running </Text>
      <Text color={c.faint}>│ </Text>
      <Tab active={mode === "procs"} label="Processes" count={procCount} />
      <Text> </Text>
      <Tab active={mode === "kept"} label="Kept" count={kept.length} />
      <Box flexGrow={1} />
      {filtering || filter ? (
        <Text>
          <Text color={c.accent}>/ </Text>
          <Text color={c.fg}>{filter}</Text>
          {filtering && <Text inverse> </Text>}
        </Text>
      ) : mode === "procs" && showAll ? (
        <Text color={c.muted}>showing app & system servers </Text>
      ) : (
        <Text color={c.faint}>{rows ? `v${pkg.version}  ? help ` : "scanning… "}</Text>
      )}
    </Box>
  );

  let body: React.ReactNode;
  if (overlay?.type === "keep" || overlay?.type === "edit") {
    const f = formFor(overlay);
    body = (
      <Form
        key={overlay.type === "keep" ? `k${overlay.row.pid}` : `e${overlay.index}`}
        title={f.title}
        initial={f.initial}
        width={W}
        height={bodyH}
        onCancel={() => setOverlay(null)}
        onSubmit={(v) => { f.save(v); setOverlay(null); }}
      />
    );
  } else if (overlay?.type === "peek") {
    body = <PeekView width={W} height={bodyH} row={rowByPid(overlay.pid)} data={peekData} source={overlay.source} />;
  } else if (overlay?.type === "urls") {
    const r = rowByPid(overlay.pid);
    body = <UrlsView width={W} height={bodyH} pages={r ? webPages(r, probes) : []} command={r?.command ?? ""} />;
  } else if (overlay?.type === "help") {
    body = <HelpView width={W} height={bodyH} />;
  } else {
    const slice = items.slice(viewTop, viewTop + listH);
    body = (
      <>
        <Box flexDirection="column" height={listH}>
          {slice.length === 0 && <Empty mode={mode} loading={!rows} filtered={!!filter} />}
          {slice.map((it, i) => {
            const idx = viewTop + i;
            const selected = idx === cursorIdx;
            if (it.type === "header") return <SectionHeader key={`h${idx}`} {...it} width={W} />;
            if (it.type === "row")
              return <ProcLine key={it.row.pid} row={it.row} depth={it.depth} kept={keptOf(it.row)} selected={selected} width={W} stop={stopping.get(it.row.pid)} probes={probes} />;
            return <KeptLine key={`k${it.index}`} kept={it.kept} live={it.live} selected={selected} width={W} probes={probes} />;
          })}
        </Box>
        <Details width={W} height={DETAILS_H} mode={mode} row={curRow} kept={curKept} probes={probes} />
      </>
    );
  }

  return (
    <Box flexDirection="column" width={W} height={H}>
      {header}
      <Text> </Text>
      {body}
      <Footer width={W} mode={mode} overlay={overlay?.type} confirm={confirm} status={status} filtering={filtering} row={curRow} probes={probes} />
    </Box>
  );
}

const TRANSCRIPT = "@transcript";

function agentBadge(a: AgentInfo): string {
  if (a.status === "new") return a.title ? "· new ·" : "· new";
  if (a.status === "working") return "· ⟳ working ·";
  const idle = a.lastActive ? fmtUptime(Math.max(0, Math.round(Date.now() / 1000 - a.lastActive))) : "";
  return idle ? `· idle ${idle} ·` : "·";
}

function AgentLine({ a }: { a: AgentInfo }) {
  const idle = a.lastActive ? `${fmtUptime(Math.max(0, Math.round(Date.now() / 1000 - a.lastActive)))} ago` : "";
  return (
    <Text wrap="truncate-end">
      <Text color={c.magenta}>{a.harness}</Text>
      {a.status === "new" ? (
        <Text color={c.dim}>  no conversation yet</Text>
      ) : (
        <>
          <Text color={a.status === "working" ? c.yellow : c.dim}>  {a.status === "working" ? "⟳ working" : `idle · last activity ${idle}`}</Text>
          {a.model && <><Dot />{L("model", a.model)}</>}
          {a.tokens !== undefined && <><Dot />{L("tokens", fmtTokens(a.tokens))}</>}
          {a.costUsd !== undefined && <><Dot />{L("cost", `$${a.costUsd.toFixed(2)}`)}</>}
          {a.branch && <><Dot />{L("branch", a.branch)}</>}
          {a.sessionId && <><Dot />{L("session", a.sessionId.slice(0, 8))}</>}
        </>
      )}
    </Text>
  );
}

const shellPath = (p: string) => (/^[\w./~+-]+$/.test(tildify(p)) ? tildify(p) : `'${p.replace(/'/g, `'\\''`)}'`);

// ── pieces ───────────────────────────────────────────────────────────────

function Tab({ active, label, count }: { active: boolean; label: string; count: number }) {
  return active ? (
    <Text backgroundColor={c.accent} color={c.accentFg} bold> {label} {count} </Text>
  ) : (
    <Text color={c.dim}> {label} <Text color={c.faint}>{count}</Text> </Text>
  );
}

function SectionHeader({ label, tag, count, width, muted }: { label: string; tag?: string; count: number; width: number; muted: boolean }) {
  const head = ` ${label} `;
  const meta = `${tag ? `· ${tag} ` : ""}· ${count} `;
  const rule = "─".repeat(Math.max(0, width - head.length - meta.length - 3));
  return (
    <Text>
      <Text color={muted ? c.muted : c.magenta} bold>{head}</Text>
      <Text color={c.dim}>{meta}</Text>
      <Text color={c.faint}>{rule}</Text>
    </Text>
  );
}

function columns(width: number) {
  const ports = 16, up = 6, mem = 6;
  const cwd = Math.max(14, Math.min(44, Math.round(width * 0.24)));
  const cmd = width - 4 - ports - cwd - up - mem - 4 - 1;
  return { ports, up, mem, cwd, cmd };
}

/** Ports, web pages first-class: `↗:3000 :3001 +3`. */
function PortsCell({ row, probes, width, muted }: { row: Row; probes: Probes; width: number; muted?: boolean }) {
  const toks = row.ports.map((p) => {
    const pr = probes.get(probeKey(row, p));
    const web = !!pr && pr !== "pending" && pr.web;
    return { text: `${web ? "↗" : ":"}${p}`, web };
  });
  // web ports first: they're the ones you'd open
  toks.sort((a, b) => Number(b.web) - Number(a.web));
  const out: typeof toks = [];
  let used = 0;
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i]!;
    const rest = toks.length - i - 1;
    const need = t.text.length + (out.length ? 1 : 0) + (rest ? ` +${rest}`.length : 0);
    if (used + need > width) break;
    out.push(t);
    used += t.text.length + (out.length > 1 ? 1 : 0);
  }
  const more = toks.length - out.length;
  const tail = more ? ` +${more}` : "";
  return (
    <Text>
      {out.map((t, i) => (
        <Text key={i} color={muted ? c.muted : t.web ? c.cyan : c.dimCyan} bold={t.web && !muted}>{(i ? " " : "") + t.text}</Text>
      ))}
      <Text color={c.dim}>{tail}</Text>
      <Text>{" ".repeat(Math.max(0, width - used - tail.length))}</Text>
    </Text>
  );
}

function ProcLine(props: { row: Row; depth: number; kept?: Kept; selected: boolean; width: number; stop?: { at: number; force: boolean }; probes: Probes }) {
  const { row: r, kept, selected } = props;
  const muted = r.kind === "app"; // only visible in the "all" view
  const col = columns(props.width);
  const bg = selected ? c.selBg : undefined;
  const indent = props.depth ? "  ".repeat(props.depth - 1) + "└ " : "";
  const agent = agentInfo(r);
  const [prog = "", ...restArgs] = r.command === r.argvCommand ? r.displayArgv : r.command.split(/\s+/);
  // Agents: what the conversation is about beats a wall of flags.
  const rest = agent ? [agentBadge(agent), agent.title ?? ""] : restArgs;
  const progName = prog.includes("/") && !prog.startsWith(".") ? basename(prog) : prog;
  const name = kept ? `${kept.name}  ` : "";
  const note = r.leaderGone ? `  ⤷ ${r.pids.length} left running` : "";
  const room = col.cmd - indent.length;
  const progShown = fit(name + progName, room).trimEnd();
  const argsRoom = Math.max(0, room - progShown.length);
  const argsText = fit(" " + rest.join(" "), Math.max(0, argsRoom - note.length)).trimEnd();
  const pad = " ".repeat(Math.max(0, argsRoom - argsText.length - note.length));
  const noteShown = note.slice(0, Math.max(0, argsRoom - argsText.length));
  const stuck = props.stop && Date.now() - props.stop.at > STUCK_AFTER_MS;
  const fg = muted ? c.muted : c.fg;

  return (
    <Text backgroundColor={bg} wrap="truncate">
      <Text color={c.accent}>{selected ? "▌" : " "}</Text>
      <Text color={c.green}>{kept ? " ● " : "   "}</Text>
      <Text color={c.faint}>{indent}</Text>
      {kept ? (
        <Text>
          <Text color={c.green} bold>{progShown.slice(0, Math.min(name.length, progShown.length))}</Text>
          <Text color={fg} bold>{progShown.slice(name.length)}</Text>
        </Text>
      ) : (
        <Text color={fg} bold={!muted} italic={r.source === "history"}>{progShown}</Text>
      )}
      <Text color={muted ? c.faint : selected ? c.fg : c.dim} italic={r.source === "history"}>{argsText}</Text>
      <Text color={c.yellow}>{noteShown}</Text>
      <Text>{pad} </Text>
      <PortsCell row={r} probes={props.probes} width={col.ports} muted={muted} />
      <Text> </Text>
      <Text color={muted ? c.faint : c.dim}>{fit(tildify(r.cwd), col.cwd, "left")}</Text>
      <Text> </Text>
      {props.stop ? (
        <Text color={stuck ? c.red : c.yellow}>{(stuck ? "stuck" : "stop…").padStart(col.up)}</Text>
      ) : (
        <Text color={muted ? c.faint : c.dim}>{fmtUptime(r.etimeSec).padStart(col.up)}</Text>
      )}
      <Text> </Text>
      <Text color={r.rssKb > 1024 * 1024 && !muted ? c.yellow : muted ? c.faint : c.dim}>{fmtMem(r.rssKb).padStart(col.mem)}</Text>
      <Text> </Text>
    </Text>
  );
}

function KeptLine(props: { kept: Kept; live?: Row; selected: boolean; width: number; probes: Probes }) {
  const { kept: k, live, selected } = props;
  const col = columns(props.width);
  const nameW = Math.min(24, Math.max(10, Math.round(col.cmd * 0.3)));
  return (
    <Text backgroundColor={selected ? c.selBg : undefined} wrap="truncate">
      <Text color={c.accent}>{selected ? "▌" : " "}</Text>
      <Text color={live ? c.green : c.faint}>{live ? " ● " : " ○ "}</Text>
      <Text color={live ? c.green : c.fg} bold>{fit(k.name, nameW)}</Text>
      <Text> </Text>
      <Text color={selected ? c.fg : c.dim}>{fit(commandLine(k), col.cmd - nameW - 1)}</Text>
      <Text> </Text>
      {live ? (
        <PortsCell row={live} probes={props.probes} width={col.ports} />
      ) : (
        <Text color={c.faint}>{fit((k.ports ?? []).map((p) => `:${p}`).join(" "), col.ports)}</Text>
      )}
      <Text> </Text>
      <Text color={c.dim}>{fit(k.cwd, col.cwd, "left")}</Text>
      <Text> </Text>
      <Text color={c.dim}>{(live ? fmtUptime(live.etimeSec) : "").padStart(col.up)}</Text>
      <Text> </Text>
      <Text color={c.dim}>{(live ? fmtMem(live.rssKb) : "").padStart(col.mem)}</Text>
      <Text> </Text>
    </Text>
  );
}

const Dot = () => <Text color={c.faint}>  ·  </Text>;
const L = (label: string, value: string, color: string = c.fg) => (
  <Text>
    <Text color={c.dim}>{label} </Text>
    <Text color={color}>{value}</Text>
  </Text>
);

function termLabel(r: Row): string {
  const t = r.term;
  if (t.tmux) return `tmux ${t.tmux}`;
  if (t.orca) return "Orca tab";
  if (t.app) return t.app.replace(/^Apple_/, "");
  return "";
}

function Details(props: { width: number; height: number; mode: Mode; row?: Row; kept?: Kept; probes: Probes }) {
  const { row: r, kept: k } = props;
  const inner = props.width - 4;

  const webLine = (r: Row) => {
    const pages = webPages(r, props.probes);
    if (pages.length)
      return (
        <Text key="web" wrap="truncate-end">
          <Text color={c.dim}>web </Text>
          {pages.map((p, i) => (
            <Text key={p.url}>
              {i > 0 && <Text color={c.faint}>  ·  </Text>}
              <Text color={c.cyan} underline>{p.url.replace(/\/$/, "")}</Text>
              {p.title && <Text color={c.dim}> {p.title}</Text>}
            </Text>
          ))}
          <Text color={c.dim}>   </Text><Text color={c.accent}>o</Text><Text color={c.dim}> open</Text>
        </Text>
      );
    if (r.ports.length) return <Text key="web" wrap="truncate-end">{L("ports", r.ports.map((p) => `:${p}`).join(" "), c.dimCyan)}<Text color={c.dim}>  (no web pages)</Text></Text>;
    return <Text key="web" color={c.faint}>no listening ports</Text>;
  };

  const origin = (r: Row) =>
    r.leaderGone ? (
      <Text color={c.yellow}>
        {r.source === "typed" ? "you ran" : r.source === "script" ? "started by" : r.source === "history" ? "probably started by" : "started by a command that"}{" "}
        {r.source !== "argv" && <Text bold>{r.command}</Text>}
        {r.source !== "argv" ? " — it exited, " : " exited — "}
        {r.pids.length === 1 ? "the process it started is" : `${r.pids.length} processes it started are`} still running
        {r.source === "history" && <Text color={c.dim}> (guessed from shell history)</Text>}
        {r.source === "script" && <Text color={c.dim}> (its package-script variables say so)</Text>}
      </Text>
    ) : r.source === "typed" && r.command !== r.argvCommand ? (
      <Text color={c.dim}>you typed this; the kernel sees: {r.argvCommand}</Text>
    ) : null;

  let lines: React.ReactNode[] = [];
  if (props.mode === "procs" && r) {
    const o = origin(r);
    lines = [
      <Text key="cmd" wrap="truncate-end"><Text color={c.accent}>$ </Text><Text color={c.fg} italic={r.source === "history"}>{r.command}</Text></Text>,
      <Text key="where" wrap="truncate-end">
        {L("in", tildify(r.cwd) || "?")}<Dot />{L("on", r.where + (r.tty !== "??" ? ` ${r.tty}` : ""))}
        {termLabel(r) && <Text color={c.dim}> ({termLabel(r)}, <Text color={c.accent}>f</Text> focus)</Text>}
        {r.via && <><Dot />{L("via", r.via)}</>}
      </Text>,
      <Text key="stats" wrap="truncate-end">
        {L("pid", r.leaderGone ? `${r.pgid} (exited)` : String(r.pid))}
        {r.pids.length > 1 && <Text color={c.dim}> +{r.pids.length - (r.leaderGone ? 0 : 1)} processes</Text>}<Dot />
        {L("up", fmtUptime(r.etimeSec))}<Dot />{L("mem", fmtMem(r.rssKb))}<Dot />{L("cpu", `${r.cpu.toFixed(1)}%`)}
      </Text>,
      agentInfo(r) ? <AgentLine key="agent" a={agentInfo(r)!} /> : webLine(r),
      k ? (
        <Text key="kept" color={c.green}>● kept as "{k.name}"{k.note ? <Text color={c.dim}> — {k.note}</Text> : null}</Text>
      ) : (
        o ?? (
          <Text key="kept" color={c.dim}>
            not kept — <Text color={c.accent}>space</Text> to keep{r.kind === "app" ? " (started by an app; may not be re-runnable)" : ""}
          </Text>
        )
      ),
    ];
    if (k && o) lines.splice(4, 0, o);
  } else if (props.mode === "kept" && k) {
    lines = [
      <Text key="cmd" wrap="truncate-end"><Text color={c.accent}>$ </Text><Text color={c.fg}>{commandLine(k)}</Text></Text>,
      <Text key="where" wrap="truncate-end">
        {L("in", k.cwd)}<Dot />{L("kept", ago(k.kept))}{k.note && <><Dot />{L("note", k.note)}</>}
      </Text>,
      r ? (
        <Text key="live" wrap="truncate-end">
          <Text color={c.green}>● running</Text><Dot />{L("on", r.where + (r.tty !== "??" ? ` ${r.tty}` : ""))}
          <Dot />{L("up", fmtUptime(r.etimeSec))}<Dot />{L("mem", fmtMem(r.rssKb))}
        </Text>
      ) : (
        <Text key="live" color={c.dim}>○ not running — <Text color={c.accent}>⏎</Text> start at your prompt, <Text color={c.accent}>t</Text> in tmux</Text>
      ),
      r ? (agentInfo(r) ? <AgentLine key="agent" a={agentInfo(r)!} /> : webLine(r)) : <Text key="web"> </Text>,
      <Text key="env" wrap="truncate-end" color={c.dim}>
        {Object.keys(k.env ?? {}).length ? `env: ${Object.keys(k.env!).join(", ")}` : "no extra environment"}
      </Text>,
    ];
  }
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={c.faint} paddingX={1} width={props.width} height={props.height}>
      {lines.length ? lines.slice(0, props.height - 2).map((l, i) => <Box key={i} width={inner}>{l}</Box>) : <Text color={c.faint}>nothing selected</Text>}
    </Box>
  );
}

function PeekView(props: { width: number; height: number; row?: Row; data: Peek | null; source?: string }) {
  const { data, row } = props;
  const room = props.height - 4;
  const lines = data ? data.lines.slice(-room) : [];
  const srcs = data?.sources ?? [];
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={c.accent} paddingX={1} width={props.width} height={props.height}>
      <Text wrap="truncate-end">
        <Text color={c.accent} bold>output </Text>
        <Text color={c.fg}>{row ? (agentInfo(row)?.title ? `${agentInfo(row)!.harness}: ${agentInfo(row)!.title}` : row.command) : "(gone)"}</Text>
        <Text color={c.dim}>  —  {data ? tildify(data.title) : "loading…"}</Text>
        {srcs.length > 0 && <Text color={c.dim}>   ←→ {srcs.length} log file{srcs.length > 1 ? "s" : ""}</Text>}
      </Text>
      <Text> </Text>
      {lines.map((l, i) => (
        <Text key={i} color={c.fg} wrap="truncate-end">{l || " "}</Text>
      ))}
    </Box>
  );
}

function UrlsView(props: { width: number; height: number; pages: Probe[]; command: string }) {
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={c.accent} paddingX={1} width={props.width} height={props.height}>
      <Text><Text color={c.accent} bold>open in browser </Text><Text color={c.dim}>{props.command}</Text></Text>
      <Text> </Text>
      {props.pages.slice(0, 9).map((p, i) => (
        <Text key={p.url} wrap="truncate-end">
          <Text color={c.accent} bold> {i + 1} </Text>
          <Text color={c.cyan}>{p.url.replace(/\/$/, "").padEnd(28)}</Text>
          <Text color={c.fg}>{p.title ?? ""}</Text>
          {p.status >= 400 && <Text color={c.yellow}>  ({p.status})</Text>}
        </Text>
      ))}
      <Text> </Text>
      <Text color={c.dim}> <Text color={c.accent}>1-9</Text> open  <Text color={c.accent}>a</Text> open all  <Text color={c.accent}>esc</Text> back</Text>
    </Box>
  );
}

function HelpView(props: { width: number; height: number }) {
  const section = (title: string, keys: [string, string][]) => (
    <Box flexDirection="column" marginBottom={1}>
      <Text color={c.magenta} bold>{title}</Text>
      {keys.map(([k, d]) => (
        <Text key={k}><Text color={c.accent}>{k.padEnd(12)}</Text><Text color={c.fg}>{d}</Text></Text>
      ))}
    </Box>
  );
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={c.accent} paddingX={2} width={props.width} height={props.height}>
      <Text color={c.accent} bold>keys</Text>
      <Text> </Text>
      <Box>
        <Box flexDirection="column" width={Math.floor((props.width - 6) / 2)}>
          {section("any running process", [
            ["o", "open its web page in the browser (↗ ports)"],
            ["f", "focus its terminal (tmux, Orca, Terminal, iTerm)"],
            ["p", "peek at its recent output (←→ between log files)"],
            ["c", "copy `cd dir && command`"],
            ["R", "restart: stop, then run it again (same terminal if possible)"],
            ["x", "stop it (again after 3s: force-kill)"],
          ])}
          {section("Processes tab", [
            ["space", "keep it"],
            ["a", "also show app & system servers (dimmed)"],
          ])}
        </Box>
        <Box flexDirection="column">
          {section("Kept tab", [
            ["⏎ / R", "start: cd + put the command on your prompt (R restarts if running)"],
            ["t", "start in a new tmux window"],
            ["e", "edit"],
            ["d", "forget"],
          ])}
          {section("everywhere", [
            ["↑↓ jk g G", "move"],
            ["/", "filter"],
            ["tab", "switch tab"],
            ["r", "refresh now"],
            ["q", "quit"],
          ])}
        </Box>
      </Box>
      <Text color={c.dim}>
        Rows marked <Text color={c.yellow}>⤷ left running</Text> are what a command left behind after it exited;
        the name comes from your command log or the processes' environment (<Text italic>italic</Text> = guessed from shell history).
        Agents (codex, claude, pi) show their conversation title; p → ←→ reads the conversation; R resumes it.
      </Text>
    </Box>
  );
}

function Empty({ mode, loading, filtered }: { mode: Mode; loading: boolean; filtered: boolean }) {
  const text = loading
    ? "scanning processes…"
    : filtered
      ? "nothing matches the filter — esc to clear"
      : mode === "kept"
        ? "nothing kept yet — in Processes, press space on a row to keep it"
        : "no relevant processes — press a to include app & system servers";
  return <Box paddingLeft={3} paddingTop={1}><Text color={c.dim}>{text}</Text></Box>;
}

function Footer(props: {
  width: number; mode: Mode; overlay?: Overlay["type"]; filtering: boolean; row?: Row; probes: Probes;
  confirm: Confirm | null; status: { text: string; tone: "ok" | "warn" | "err" } | null;
}) {
  if (props.confirm)
    return (
      <Text wrap="truncate">
        <Text color={c.red} bold> {props.confirm.text} </Text>
        <Text color={c.fg}>y</Text><Text color={c.dim}>/</Text><Text color={c.fg}>n</Text>
      </Text>
    );
  if (props.status) {
    const color = { ok: c.green, warn: c.yellow, err: c.red }[props.status.tone];
    return <Text color={color} wrap="truncate"> {props.status.text}</Text>;
  }
  const hasWeb = !!props.row && webPages(props.row, props.probes).length > 0;
  const keys: [string, string][] =
    props.overlay === "keep" || props.overlay === "edit"
      ? [["⏎", "save"], ["tab ↑↓", "fields"], ["space", "toggle env"], ["esc", "cancel"]]
      : props.overlay === "peek"
        ? [["←→", "terminal / conversation / logs"], ["f", "focus terminal"], ["esc", "back"]]
        : props.overlay
          ? [["esc", "back"]]
          : props.filtering
            ? [["type", "to filter"], ["⏎", "done"], ["esc", "clear"]]
            : props.mode === "procs"
              ? [["space", "keep"], ...(hasWeb ? [["o", "open"]] as [string, string][] : []), ["f", "focus"], ["p", "peek"], ["R", "restart"], ["x", "kill"], ["/", "filter"], ["a", "all"], ["tab", "kept"], ["?", "more"]]
              : [["⏎", "to prompt"], ["t", "tmux"], ["e", "edit"], ["d", "forget"], ...(props.row ? ([["R", "restart"], ["f", "focus"], ["x", "kill"]] as [string, string][]) : []), ["tab", "processes"], ["?", "more"]];
  return (
    <Text wrap="truncate">
      {keys.map(([k, label]) => (
        <Text key={k + label}>
          <Text color={c.accent}> {k}</Text>
          <Text color={c.dim}> {label} </Text>
        </Text>
      ))}
    </Text>
  );
}
