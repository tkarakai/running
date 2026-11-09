import AppKit
import Foundation
import SwiftUI

struct Toast: Identifiable, Equatable {
    enum Tone { case ok, warn, err, info }
    var id = UUID()
    var text: String
    var tone: Tone
    var undo: (() -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct Sample: Hashable { var t: Double; var cpu: Double; var rssKb: Int }

/// A question the UI should ask before doing something irreversible.
struct Confirmation: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var action: String
    var destructive: Bool
    var run: () -> Void
}

/// Everything the windows show, refreshed from the core every couple of seconds.
@MainActor @Observable
final class Store {
    let core = CoreClient()
    let prefs = Preferences.shared

    // ── data ──
    var hello: Hello?
    var rows: [Job] = []
    var kept: [KeptEntry] = []
    var probes: [String: ProbeInfo] = [:]
    var branches: [String: String?] = [:]
    var sort: SortKey = .started
    var sortDesc = true
    var loaded = false
    var fatal: String?
    var lastRefresh: Date?
    var lastError: String?

    // ── view state shared between the window and the popover ──
    var query = ""
    var expanded: Set<Int> = []
    var selection: ItemID?
    var keptSelection: Int?
    var stopping: [Int: (at: Date, force: Bool)] = [:]
    var history: [Int: [Sample]] = [:]
    var toast: Toast?
    var confirmation: Confirmation?
    var keepDraft: (pid: Int, draft: KeepDraft)?
    var editing: KeptEntry?
    var busy: Set<Int> = [] // jobs with an action in flight (restart)

    // ── visibility drives the refresh rate ──
    var windowVisible = false { didSet { reschedule() } }
    var popoverVisible = false { didSet { reschedule() } }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var engineStarted = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var statusById: [Int: Int] = [:] // request id → job pid

    static let stuckAfter: TimeInterval = 3

    init() {
        core.onChanged = { [weak self] in Task { @MainActor in self?.refreshSoon() } }
        core.onStatus = { [weak self] id, text in Task { @MainActor in self?.flash(text, .info) } }
        core.onFatal = { [weak self] msg in Task { @MainActor in self?.fatal = msg } }
    }

    func start() {
        Task.detached(priority: .userInitiated) { [core] in
            let env = LoginEnvironment.resolve()
            core.start(environment: env)
            await MainActor.run {
                self.engineStarted = true
                Task { await self.loadHello(); await self.refresh() }
                self.reschedule()
            }
        }
    }

    private func loadHello() async {
        for _ in 0..<20 {
            if let h = try? await core.call("hello", as: Hello.self) { hello = h; return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // ── refresh ────────────────────────────────────────────────────────────
    var interval: TimeInterval {
        if windowVisible || popoverVisible { return 2 }
        return prefs.showCountInMenuBar ? 15 : 60
    }

    func reschedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if windowVisible || popoverVisible { Task { await refresh() } }
    }

    private var lastSoon = Date.distantPast
    func refreshSoon() {
        guard windowVisible || popoverVisible, Date().timeIntervalSince(lastSoon) > 0.5 else { return }
        lastSoon = Date()
        Task { await refresh() }
    }

    func refresh() async {
        guard engineStarted else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            do {
                let s = try await core.call("snapshot", as: Snapshot.self)
                apply(s)
                fatal = nil
            } catch {
                lastError = "\(error)"
                if loaded { flash("Refresh failed: \(error.localizedDescription)", .err) }
            }
        } while refreshAgain
    }

    private func apply(_ s: Snapshot) {
        rows = s.rows
        kept = s.kept
        branches = s.branches
        var p: [String: ProbeInfo] = [:]
        for x in s.probes { p["\(x.pid):\(x.port)"] = x }
        probes = p
        if let k = SortKey(rawValue: s.sort.key) { sort = k; sortDesc = s.sort.desc }
        lastRefresh = Date()
        loaded = true
        // Stopping state ends when the process is gone.
        let alive = Set(rows.flatMap { [$0.pid] + $0.members.map(\.pid) })
        stopping = stopping.filter { alive.contains($0.key) }
        expanded = expanded.filter { alive.contains($0) }
        // Sparkline history.
        let now = s.at
        var h: [Int: [Sample]] = [:]
        for r in rows {
            var list = history[r.pid] ?? []
            list.append(Sample(t: now, cpu: r.cpu, rssKb: r.rssKb))
            if list.count > 90 { list.removeFirst(list.count - 90) }
            h[r.pid] = list
        }
        history = h
        // Keep a selection only if it's still there.
        if let sel = selection, !ids.contains(sel) {
            if case .member(let j, _) = sel, rows.contains(where: { $0.pid == j }) { selection = .job(j) } else { selection = nil }
        }
    }

    // ── derived ────────────────────────────────────────────────────────────
    var showAll: Bool {
        get { prefs.showAppServers }
        set { prefs.showAppServers = newValue }
    }

    var sections: [WhereSection] {
        Grouping.build(rows: rows, kept: kept, branches: branches, showAll: showAll, query: query, expanded: expanded, sort: sort, desc: sortDesc)
    }

    var ids: Set<ItemID> {
        var s = Set<ItemID>()
        for r in rows { s.insert(.job(r.pid)); for m in r.members { s.insert(.member(job: r.pid, pid: m.pid)) } }
        return s
    }

    /// Jobs you started (what the menu bar counts): not app/system servers.
    var userJobs: [Job] { rows.filter { $0.kind != .app } }
    var visibleCount: Int { rows.filter { showAll || $0.kind != .app }.count }

    func job(_ pid: Int?) -> Job? { pid.flatMap { p in rows.first { $0.pid == p } } }
    func keptEntry(_ index: Int?) -> KeptEntry? { index.flatMap { i in kept.first { $0.index == i } } }
    func keptFor(_ j: Job) -> KeptEntry? { keptEntry(j.keptIndex) }
    func liveJob(_ k: KeptEntry) -> Job? { job(k.livePid) }

    var selectedJob: Job? { job(selection?.jobPid) }
    var selectedMember: Member? {
        if case .member(let j, let p) = selection { return job(j)?.members.first { $0.pid == p } }
        return nil
    }

    func probe(_ l: Listen) -> ProbeInfo? { probes["\(l.pid):\(l.port)"] }
    func isWeb(_ l: Listen) -> Bool { probe(l)?.web == true }
    func webPages(_ listen: [Listen]) -> [ProbeInfo] { listen.compactMap { probe($0) }.filter { $0.web == true && $0.url != nil } }

    func name(of j: Job) -> String {
        if let k = keptFor(j) { return k.name }
        if let a = j.agent, let t = a.title { return t }
        return j.command
    }

    /// A short title: kept name, agent topic, or the program (`vite`, `no-mistakes`).
    func title(of j: Job) -> String {
        if let k = keptFor(j) { return k.name }
        if let a = j.agent { return a.title ?? a.harness }
        let words = j.command == j.argvCommand ? j.displayArgv : j.command.split(separator: " ").map(String.init)
        let progIdx = words.firstIndex { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) == nil } ?? 0
        guard progIdx < words.count else { return j.command }
        var prog = words[progIdx]
        if prog.contains("/") && !prog.hasPrefix(".") { prog = Fmt.basename(prog) }
        // `npm run dev`, `bun dev`, `make serve`: the script name says what it is.
        let rest = words.dropFirst(progIdx + 1).filter { $0 != "run" }
        if ["npm", "pnpm", "yarn", "bun", "just", "make", "cargo", "go", "uv", "deno"].contains(prog), let sub = rest.first, !sub.hasPrefix("-") {
            return "\(prog) \(sub)"
        }
        return prog
    }

    // ── toasts ─────────────────────────────────────────────────────────────
    func flash(_ text: String, _ tone: Toast.Tone = .ok, undo: (() -> Void)? = nil) {
        let t = Toast(text: text, tone: tone, undo: undo)
        withAnimation(.snappy(duration: 0.25)) { toast = t }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 7))
            guard !Task.isCancelled else { return }
            await MainActor.run { if self?.toast?.id == t.id { withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil } } }
        }
    }

    private func report(_ error: Error) { flash(error.localizedDescription, .err) }

    // ── expand / collapse ──
    func setExpanded(_ pid: Int, _ open: Bool) {
        withAnimation(.snappy(duration: 0.2)) {
            if open { expanded.insert(pid) } else { expanded.remove(pid) }
        }
    }

    // ── sort ──
    func setSort(_ key: SortKey, desc: Bool? = nil) {
        let d = desc ?? (key == sort ? sortDesc : key.naturalDesc)
        sort = key
        sortDesc = d
        Task {
            _ = try? await core.call("setSort", ["key": key.rawValue, "desc": d], as: SortSpec.self)
        }
    }

    func reverseSort() { setSort(sort, desc: !sortDesc) }

    // ── actions ────────────────────────────────────────────────────────────
    func openWeb(_ j: Job, member m: Member? = nil) {
        let listen = m?.listen ?? j.listen
        let pages = webPages(listen)
        if let p = pages.first, pages.count == 1 || m != nil {
            open(url: p.url!)
            flash("Opened \(p.url!.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(p.title.map { " — \($0)" } ?? "")")
            return
        }
        if pages.count > 1 {
            setExpanded(j.pid, true)
            if let first = j.members.first(where: { $0.listen.contains { isWeb($0) } }) { selection = .member(job: j.pid, pid: first.pid) }
            flash("\(pages.count) web pages — pick one", .info)
            return
        }
        if listen.isEmpty { return flash("Not listening on any port", .warn) }
        let pending = listen.contains { probe($0)?.pending ?? true }
        flash(pending ? "Still checking its ports…" : "Its ports don't serve web pages (API or another protocol)", .warn)
    }

    func open(url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    func focus(_ j: Job) {
        Task {
            do {
                let r = try await core.call("focus", ["pid": j.pid, "terminal": prefs.terminal], as: Outcome.self)
                flash(r.message.capitalizedFirst, r.ok ? .ok : .warn)
            } catch { report(error) }
        }
    }

    func copyCommand(_ j: Job, member m: Member? = nil) {
        Task {
            let cwd = m?.cwd ?? j.cwd
            let cmd = m?.argvCommand ?? j.command
            let line = (try? await core.call("copyLine", ["cwd": cwd, "command": cmd], as: CopyLine.self).line) ?? "cd \(cwd) && \(cmd)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
            flash("Copied: \(line)")
        }
    }

    func copy(_ text: String, label: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied \(label ?? text)")
    }

    func isStuck(_ pid: Int) -> Bool {
        guard let s = stopping[pid] else { return false }
        return Date().timeIntervalSince(s.at) > Self.stuckAfter
    }

    /// Stop (SIGTERM; a second time after 3s escalates to kill -9; after that: explain).
    func stop(_ j: Job, member m: Member? = nil, force forceNow: Bool = false, confirmed: Bool = false) {
        let key = m?.pid ?? j.pid
        if let st = stopping[key], st.force, Date().timeIntervalSince(st.at) > 1.5 {
            Task {
                if let w = try? await core.call("whyAlive", ["pid": j.pid, "child": m?.pid as Any], as: WhyAlive.self) {
                    flash("pid \(w.pid): \(w.reason)", .warn)
                }
            }
            return
        }
        let force = forceNow || isStuck(key)
        let label = m?.argvCommand ?? name(of: j)
        let short = label.count > 60 ? String(label.prefix(59)) + "…" : label
        let count = m?.pidCount ?? j.pidCount
        let go = { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let r = try await self.core.call("kill", ["pid": j.pid, "child": m?.pid as Any, "force": force], as: KillResult.self)
                    withAnimation { self.stopping[key] = (Date(), force) }
                    self.flash(r.sent > 0 ? (force ? "Sent kill -9" : "Sent SIGTERM — stopping…") : "Already gone", .warn)
                    try? await Task.sleep(for: .milliseconds(400))
                    await self.refresh()
                } catch { self.report(error) }
            }
        }
        if confirmed || (!prefs.confirmStop && !force) { return go() }
        confirmation = Confirmation(
            title: force ? "Force-kill “\(short)”?" : "Stop “\(short)”?",
            message: (force ? "kill -9 gives it no chance to clean up. " : "Sends SIGTERM (and SIGCONT, so paused processes stop too). ")
                + (count > 1 ? "\(count) processes" : "pid \(key)") + (m != nil ? " — just this part of the job." : "."),
            action: force ? "Force Kill" : "Stop", destructive: true, run: go)
    }

    func restart(_ j: Job) {
        Task {
            do {
                let res = try await core.call("planRestart", ["pid": j.pid], as: PlanResult.self)
                guard res.ok, let p = res.plan else { return flash((res.reason ?? "can't restart it").capitalizedFirst, .warn) }
                confirmation = Confirmation(
                    title: "Restart “\(name(of: j).prefix(50))”?",
                    message: "Stops \(j.pidCount > 1 ? "its \(j.pidCount) processes" : "it"), then runs\n\n\(p.line)\n\nin \(p.whereLabel == "your prompt" ? "a new \(Preferences.label(forTerminal: prefs.terminal)) window" : p.whereLabel)" + (p.why.isEmpty ? "." : " — \(p.why).") + (p.exact ? "" : "\n\n⚠︎ Not verified: the command was reconstructed."),
                    action: "Restart", destructive: false) { [weak self] in self?.runRestart(j) }
            } catch { report(error) }
        }
    }

    private func runRestart(_ j: Job) {
        busy.insert(j.pid)
        stopping[j.pid] = (Date(), false)
        Task {
            defer { busy.remove(j.pid) }
            do {
                let r = try await core.call("restart", ["pid": j.pid, "terminal": prefs.terminal], as: Outcome.self)
                flash(r.message.capitalizedFirst, r.ok ? .ok : .err)
                try? await Task.sleep(for: .milliseconds(800))
                await refresh()
            } catch { report(error) }
        }
    }

    // ── keep / edit / forget / start ──
    func beginKeep(_ j: Job) {
        if let k = keptFor(j) { return flash("Already kept as “\(k.name)”", .info) }
        Task {
            do {
                let d = try await core.call("keepDraft", ["pid": j.pid], as: KeepDraft.self)
                if let a = d.alreadyKept { return flash("Already kept as “\(a.name)”", .info) }
                keepDraft = (j.pid, d)
            } catch { report(error) }
        }
    }

    struct FormValues {
        var name: String, command: String, cwd: String, note: String, env: [EnvChoice]
        var dict: [String: Any] {
            ["name": name, "command": command, "cwd": cwd, "note": note,
             "env": env.map { ["key": $0.key, "value": $0.value, "selected": $0.selected] }]
        }
    }

    func saveKeep(pid: Int, _ v: FormValues) async -> Bool {
        do {
            let r = try await core.call("keep", ["pid": pid, "values": v.dict], as: KeepResult.self)
            flash(r.message.capitalizedFirst, r.ok ? .ok : .warn)
            await refresh()
            return r.ok
        } catch { report(error); return false }
    }

    func saveEdit(index: Int, _ v: FormValues) async -> Bool {
        do {
            let r = try await core.call("edit", ["index": index, "values": v.dict], as: Outcome.self)
            flash(r.message.capitalizedFirst, r.ok ? .ok : .warn)
            await refresh()
            return r.ok
        } catch { report(error); return false }
    }

    func forget(_ k: KeptEntry) {
        Task {
            do {
                let r = try await core.call("forget", ["index": k.index], as: ForgetResult.self)
                await refresh()
                let raw = r.restore
                var obj: [String: Any] = ["name": raw.name, "command": raw.command, "cwd": raw.cwd, "kept": raw.kept]
                if let e = raw.env { obj["env"] = e }
                if let n = raw.note { obj["note"] = n }
                if let p = raw.ports { obj["ports"] = p }
                if let s = raw.session { obj["session"] = s }
                flash("Forgot “\(k.name)” — the process itself is untouched", .warn) { [weak self] in
                    guard let self else { return }
                    Task {
                        _ = try? await self.core.call("restoreKept", ["kept": obj, "index": k.index], as: Outcome.self)
                        await self.refresh()
                        self.flash("“\(k.name)” is back")
                    }
                }
            } catch { report(error) }
        }
    }

    func confirmForget(_ k: KeptEntry) {
        confirmation = Confirmation(title: "Forget “\(k.name)”?", message: "It's removed from your kept list. The process itself is not touched.", action: "Forget", destructive: true) { [weak self] in self?.forget(k) }
    }

    func move(from: Int, to: Int) {
        Task {
            _ = try? await core.call("move", ["from": from, "to": to], as: [String: Bool].self)
            await refresh()
        }
    }

    func start(_ k: KeptEntry, in terminal: String? = nil, confirmed: Bool = false) {
        if !confirmed, let live = liveJob(k) {
            confirmation = Confirmation(title: "“\(k.name)” is already running", message: "It's running in \(Grouping.sectionLabel(live.where)). Start another one?", action: "Start Another", destructive: false) { [weak self] in
                self?.start(k, in: terminal, confirmed: true)
            }
            return
        }
        let t = terminal ?? prefs.terminal
        Task {
            do {
                let r = try await core.call("start", ["index": k.index, "terminal": t], as: Outcome.self)
                flash(r.message.capitalizedFirst, r.ok ? .ok : .err)
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            } catch { report(error) }
        }
    }

    // ── peek ──
    func peek(pid: Int, child: Int?, source: String?, lines: Int = 600) async -> PeekData? {
        var p: [String: Any] = ["pid": pid, "lines": lines]
        if let child { p["child"] = child }
        if let source { p["source"] = source }
        return try? await core.call("peek", p, as: PeekData.self)
    }
}

extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
