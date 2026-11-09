import SwiftUI

struct InspectorView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            Picker("", selection: $ui.inspectorTab) {
                Text("Details").tag(UIState.InspectorTab.details)
                Text("Output").tag(UIState.InspectorTab.output)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if let j = store.selectedJob {
                switch ui.inspectorTab {
                case .details:
                    ScrollView {
                        if let m = store.selectedMember { MemberDetails(job: j, member: m) } else { JobDetails(job: j) }
                    }
                    .scrollContentBackground(.hidden)
                case .output:
                    OutputView(job: j, member: store.selectedMember)
                        .id("\(j.pid)-\(store.selectedMember?.pid ?? 0)")
                }
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "cursorarrow.click.2", description: Text("Select a process to see what it is, where it runs, and what it's printing."))
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

// ── shared pieces ────────────────────────────────────────────────────────

struct InfoRow<V: View>: View {
    var label: String
    @ViewBuilder var value: V
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

struct Card<C: View>: View {
    var title: String?
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.leading, 2) }
            VStack(alignment: .leading, spacing: 7) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
        }
    }
}

struct CommandBlock: View {
    @Environment(Store.self) private var store
    var command: String
    var cwd: String
    var italic = false
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("$").font(.system(.callout, design: .monospaced)).foregroundStyle(Color.accentColor)
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .italic(italic)
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task {
                    let line = (try? await store.core.call("copyLine", ["cwd": cwd, "command": command], as: CopyLine.self).line) ?? command
                    store.copy(line, label: "cd + command")
                }
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .opacity(hover ? 1 : 0.45)
                .help("Copy `cd dir && command`  (c)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onHover { hover = $0 }
    }
}

struct ActionButton: View {
    var title: String
    var symbol: String
    var key: String
    var role: ButtonRole? = nil
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(height: 18)
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!enabled)
        .help("\(title)  (\(key))")
        .foregroundStyle(role == .destructive && enabled ? Color.red : Color.primary)
    }
}

struct WebPagesList: View {
    @Environment(Store.self) private var store
    var listen: [Listen]
    var body: some View {
        let pages = store.webPages(listen)
        let other = listen.filter { !store.isWeb($0) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pages, id: \.self) { p in
                Button { store.open(url: p.url ?? "") } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "safari").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title ?? "Untitled page").foregroundStyle(.primary).lineLimit(1)
                            Text(p.url?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Open \(p.url ?? "")")
            }
            if !other.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                    Text(other.map { ":\(String($0.port))" }.joined(separator: "  ")).font(.callout.monospacedDigit())
                    Text(other.contains { store.probe($0)?.pending ?? true } ? "checking…" : "not web pages").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct Stat: View {
    var label: String
    var value: String
    var spark: [Double]?
    var color: Color = .accentColor
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
            if let spark, spark.count > 1 {
                Sparkline(values: spark, color: color).frame(height: 22)
            } else {
                Color.clear.frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ── a job ────────────────────────────────────────────────────────────────

struct JobDetails: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    var job: Job

    var body: some View {
        let j = job
        let k = store.keptFor(j)
        let hist = store.history[j.pid] ?? []
        VStack(alignment: .leading, spacing: 16) {
            // title
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kindSymbol(j))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(j.agent != nil ? Color.purple : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((j.agent != nil ? Color.purple : Color.accentColor).opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.title(of: j)).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 6) {
                        if k != nil { Label("Kept", systemImage: "bookmark.fill").foregroundStyle(.green) }
                        if let a = j.agent { AgentBadge(agent: a) }
                        if j.leaderGone { Text("⤷ exited").foregroundStyle(.orange) }
                        if let st = stateLabel(j.stat) { Text(st).foregroundStyle(.red) }
                    }
                    .font(.caption.weight(.medium))
                }
            }

            CommandBlock(command: j.command, cwd: j.cwd, italic: j.source == .history)

            // actions
            let hasWeb = !store.webPages(j.listen).isEmpty
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ActionButton(title: "Open", symbol: "safari", key: "o", enabled: hasWeb || !j.listen.isEmpty) { store.openWeb(j) }
                    ActionButton(title: "Focus", symbol: "macwindow", key: "f") { store.focus(j) }
                    ActionButton(title: "Output", symbol: "text.alignleft", key: "p") { ui.inspectorTab = .output }
                }
                GridRow {
                    if k == nil {
                        ActionButton(title: "Keep", symbol: "bookmark", key: "space") { store.beginKeep(j) }
                    } else {
                        ActionButton(title: "Kept", symbol: "bookmark.fill", key: "space") { ui.route = .kept; store.keptSelection = k?.index }
                    }
                    ActionButton(title: "Restart", symbol: "arrow.clockwise", key: "⇧R", enabled: !store.busy.contains(j.pid)) { store.restart(j) }
                    ActionButton(title: store.isStuck(j.pid) ? "Kill -9" : "Stop", symbol: "stop.fill", key: "x", role: .destructive) { store.stop(j) }
                }
            }

            // origin
            if let note = originNote(j) {
                Label { Text(note) } icon: { Image(systemName: j.leaderGone ? "arrow.turn.down.right" : "info.circle") }
                    .font(.callout)
                    .foregroundStyle(j.leaderGone ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // stats
            Card(title: "Activity") {
                HStack(spacing: 14) {
                    Stat(label: "CPU", value: Fmt.cpu(j.cpu), spark: hist.map(\.cpu), color: .accentColor)
                    Stat(label: "Memory", value: Fmt.memLong(j.rssKb), spark: hist.map { Double($0.rssKb) }, color: .orange)
                    Stat(label: "Up", value: Fmt.uptime(j.etimeSec))
                }
                .help("Since this window started watching; whole job (\(j.pidCount) process\(j.pidCount == 1 ? "" : "es"))")
            }

            if let a = j.agent { AgentCard(agent: a) }

            if !j.listen.isEmpty {
                Card(title: "Web") { WebPagesList(listen: j.listen) }
            }

            Card(title: "Where") {
                InfoRow(label: "Directory") {
                    HStack(spacing: 4) {
                        Text(j.cwd.isEmpty ? "unknown" : Fmt.tildify(j.cwd)).textSelection(.enabled).lineLimit(2).truncationMode(.head)
                        if !j.cwd.isEmpty {
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: j.cwd)) } label: { Image(systemName: "arrow.forward.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open in Finder")
                        }
                    }
                }
                if let b = store.branches[j.cwd] ?? nil {
                    InfoRow(label: "Branch") { Label(b, systemImage: "arrow.triangle.branch").foregroundStyle(.teal) }
                }
                InfoRow(label: "Runs in") {
                    HStack(spacing: 5) {
                        WhereIconView(name: j.where, size: 14)
                        Text(Grouping.sectionLabel(j.where) + (j.tty != "??" ? " · \(j.tty)" : ""))
                        if !j.termLabel.isEmpty && !j.where.hasPrefix("tmux") { Text("(\(j.termLabel))").foregroundStyle(.secondary) }
                    }
                }
                if let via = j.via { InfoRow(label: "Via") { Text(via) } }
                InfoRow(label: "PID") {
                    (Text(verbatim: j.leaderGone ? "\(j.pgid) (exited)" : "\(j.pid)").monospacedDigit()
                        + Text(j.members.isEmpty ? "" : "  +\(j.members.count) more").foregroundStyle(.secondary)).textSelection(.enabled)
                }
                InfoRow(label: "Kind") { Text(kindLabel(j)) }
            }

            if let k {
                Card(title: "Kept") {
                    InfoRow(label: "Name") { Text(k.name).foregroundStyle(.green) }
                    if !k.note.isEmpty { InfoRow(label: "Note") { Text(k.note) } }
                    InfoRow(label: "Since") { Text(Fmt.ago(iso: k.kept)) }
                }
            }
        }
        .padding(16)
    }

    func originNote(_ j: Job) -> String? {
        if j.leaderGone {
            let who: String
            switch j.source {
            case .typed: who = "You ran “\(j.command)” — it exited"
            case .script: who = "Started by “\(j.command)” (its package-script variables say so) — it exited"
            case .history: who = "Probably started by “\(j.command)” (guessed from shell history) — it exited"
            case .argv: who = "Started by a command that exited"
            }
            return who + "; " + (j.pidCount == 1 ? "the process it started is still running." : "\(j.pidCount) processes it started are still running.")
        }
        if j.source == .typed && j.command != j.argvCommand { return "You typed this; the kernel sees: \(j.argvCommand)" }
        if j.source == .history { return "Command guessed from shell history — not verified." }
        return nil
    }

    func kindLabel(_ j: Job) -> String {
        switch j.kind {
        case .term: return j.leaderGone ? "Left running by a finished command" : "Started in a terminal"
        case .server: return "Server (listens on a port)"
        case .daemon: return "Detached (no terminal)"
        case .app: return "Belongs to an app or macOS"
        }
    }
}

struct AgentCard: View {
    var agent: AgentInfo
    var body: some View {
        Card(title: "\(agent.harness) agent") {
            if agent.status == "new" {
                Text("No conversation yet").foregroundStyle(.secondary).font(.callout)
            } else {
                if let t = agent.title { InfoRow(label: "Topic") { Text(t).lineLimit(3) } }
                InfoRow(label: "Status") {
                    HStack(spacing: 6) {
                        AgentBadge(agent: agent)
                        if let l = agent.lastActive { Text("last activity \(Fmt.ago(epoch: l))").foregroundStyle(.secondary) }
                    }
                }
                if let m = agent.model { InfoRow(label: "Model") { Text(m) } }
                if agent.tokens != nil || agent.costUsd != nil {
                    InfoRow(label: "Usage") {
                        Text([agent.tokens.map { "\(Fmt.tokens($0)) tokens" }, agent.costUsd.map { String(format: "$%.2f", $0) }].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                if let b = agent.branch { InfoRow(label: "Branch") { Text(b) } }
                if let s = agent.sessionId { InfoRow(label: "Session") { Text(s).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle) } }
            }
        }
    }
}

// ── one process of a job ─────────────────────────────────────────────────

struct MemberDetails: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    var job: Job
    var member: Member

    var body: some View {
        let m = member
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Fmt.basename(m.displayArgv.first ?? m.argvCommand)).font(.title3.weight(.semibold))
                Button { store.selection = .job(job.pid) } label: {
                    HStack(spacing: 4) {
                        Text("part of").foregroundStyle(.secondary)
                        Text(store.name(of: job)).lineLimit(1)
                        Image(systemName: "arrow.up.left").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .help("Go to the job (←)")
            }
            CommandBlock(command: m.argvCommand, cwd: m.cwd)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ActionButton(title: "Open", symbol: "safari", key: "o", enabled: !m.listen.isEmpty) { store.openWeb(job, member: m) }
                    ActionButton(title: "Output", symbol: "text.alignleft", key: "p") { ui.inspectorTab = .output }
                    ActionButton(title: store.isStuck(m.pid) ? "Kill -9" : "Stop", symbol: "stop.fill", key: "x", role: .destructive) { store.stop(job, member: m) }
                }
            }
            Text("One process of a job: it can be opened, read and stopped on its own; keep or restart the whole job from its row.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card(title: "Activity") {
                HStack(spacing: 14) {
                    Stat(label: "CPU", value: Fmt.cpu(m.cpu))
                    Stat(label: "Memory", value: Fmt.memLong(m.rssKb))
                    Stat(label: "Up", value: Fmt.uptime(m.etimeSec))
                }
            }
            if !m.listen.isEmpty { Card(title: "Web") { WebPagesList(listen: m.listen) } }
            Card(title: "Where") {
                InfoRow(label: "Directory") { Text(Fmt.tildify(m.cwd)).textSelection(.enabled).lineLimit(2).truncationMode(.head) }
                InfoRow(label: "PID") {
                    (Text(verbatim: "\(m.pid)").monospacedDigit() + Text(m.pidCount > 1 ? "  +\(m.pidCount - 1) below it" : "").foregroundStyle(.secondary)).textSelection(.enabled)
                }
                InfoRow(label: "Parent") { Text(verbatim: "\(m.ppid)").monospacedDigit() }
            }
        }
        .padding(16)
    }
}
