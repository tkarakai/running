import SwiftUI

/// The menu bar panel: a glance at what's running, the common actions one click away, and a
/// way into the full window. Fully keyboard-driven: type to filter, ↑↓, ⏎, ⌘⏎, ⌘⌫, tab.
struct PopoverView: View {
    @Environment(Store.self) private var store
    var openWindow: (_ select: ItemID?, _ route: Route?) -> Void
    var close: () -> Void

    enum Tab: String { case processes, kept }
    @State private var tab: Tab = .processes
    @State private var highlight: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    struct Entry: Identifiable {
        var id: String
        var job: Job?
        var kept: KeptEntry?
        var section: String
    }

    var entries: [Entry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if tab == .kept {
            return store.kept
                .filter { q.isEmpty || "\($0.name) \($0.command) \($0.cwd)".lowercased().contains(q) }
                .map { Entry(id: "k\($0.index)", kept: $0, section: "") }
        }
        let jobs = store.rows.filter { (store.showAll || $0.kind != .app) && Grouping.matches($0, query: q, keptName: store.keptFor($0)?.name) }
        // Section order as in the window; within a section, oldest first like the default sort.
        let sections = Grouping.build(rows: jobs, kept: store.kept, branches: [:], showAll: true, query: "", expanded: [], sort: store.sort, desc: store.sortDesc)
        return sections.flatMap { s in s.dirs.flatMap { d in d.lines.compactMap { l -> Entry? in
            if case .job = l.kind { return Entry(id: "j\(l.job.pid)", job: l.job, section: s.key) }
            return nil
        } } }
    }

    var body: some View {
        let list = entries
        VStack(spacing: 0) {
            header
            searchBar(list)
            Divider().opacity(0.5)
            if !store.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if list.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                                if let j = e.job, i == 0 || list[i - 1].section != e.section {
                                    PopoverSectionHeader(name: j.where).padding(.top, i == 0 ? 4 : 10)
                                }
                                Group {
                                    if let j = e.job { PopoverJobRow(job: j, highlighted: highlight == e.id, openWindow: { openWindow(.job(j.pid), .processes) }) }
                                    else if let k = e.kept { PopoverKeptRow(kept: k, highlighted: highlight == e.id, openWindow: { store.keptSelection = k.index; openWindow(nil, .kept) }) }
                                }
                                .id(e.id)
                                .onHover { if $0 { highlight = e.id } }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: highlight) { _, h in if let h { proxy.scrollTo(h) } }
                }
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 400, height: 540)
        .toasts()
        .alert(store.confirmation?.title ?? "", isPresented: Binding(get: { store.confirmation != nil && store.popoverVisible }, set: { if !$0 { store.confirmation = nil } }), presenting: store.confirmation) { c in
            Button(c.action, role: c.destructive ? .destructive : nil) { c.run() }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.message) }
        .onAppear { searchFocused = true; highlight = nil; query = "" }
        .onChange(of: tab) { highlight = nil }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppArt.menuBarImage(count: nil))
                .renderingMode(.template)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("Running").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text("Processes").tag(Tab.processes)
                Text("Kept").tag(Tab.kept)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    var summary: String {
        guard store.loaded else { return "Looking…" }
        let n = store.userJobs.count
        let k = store.kept.filter { $0.livePid != nil }.count
        return "\(n) job\(n == 1 ? "" : "s") running" + (store.kept.isEmpty ? "" : " · \(k)/\(store.kept.count) kept up")
    }

    func searchBar(_ list: [Entry]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tab == .kept ? "Filter kept" : "Filter — command, directory, port", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(phases: .down) { press in key(press, list) }
                .onSubmit { activate(list, alt: false) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    func key(_ press: KeyPress, _ list: [Entry]) -> KeyPress.Result {
        let idx = highlight.flatMap { h in list.firstIndex { $0.id == h } }
        switch press.key {
        case .downArrow:
            highlight = list[min(list.count - 1, (idx ?? -1) + 1)].id
            return list.isEmpty ? .ignored : .handled
        case .upArrow:
            guard !list.isEmpty else { return .ignored }
            highlight = list[max(0, (idx ?? list.count) - 1)].id
            return .handled
        case .tab:
            tab = tab == .processes ? .kept : .processes
            return .handled
        case .escape:
            if !query.isEmpty { query = ""; return .handled }
            close()
            return .handled
        case .return:
            activate(list, alt: press.modifiers.contains(.command))
            return .handled
        case .delete:
            if press.modifiers.contains(.command), let i = idx, let j = list[i].job {
                store.stop(j)
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }

    /// ⏎: open its web page / focus its terminal / start a kept one. ⌘⏎: show it in the window.
    func activate(_ list: [Entry], alt: Bool) {
        let e = highlight.flatMap { h in list.first { $0.id == h } } ?? (list.count == 1 ? list.first : nil)
        guard let e else { return }
        if let j = e.job {
            if alt { return openWindow(.job(j.pid), .processes) }
            if !store.webPages(j.listen).isEmpty { store.openWeb(j) } else { store.focus(j) }
            close()
        } else if let k = e.kept {
            if alt { store.keptSelection = k.index; return openWindow(nil, .kept) }
            store.start(k)
        }
    }

    var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? (tab == .kept ? "bookmark" : "moon.stars") : "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
            Text(query.isEmpty ? (tab == .kept ? "Nothing kept yet" : "Nothing running") : "No matches").font(.headline).foregroundStyle(.secondary)
            if query.isEmpty && tab == .kept {
                Text("Keep a process from the Running window to start it again later.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        }
    }

    var footer: some View {
        HStack(spacing: 10) {
            Button { openWindow(nil, nil) } label: {
                Label("Open", systemImage: "macwindow").fixedSize()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("o", modifiers: .command)
            .help("Open the Running window (⌘O)")
            .layoutPriority(1)
            Spacer()
            HStack(spacing: 4) { Kbd("⏎"); Text("open"); Text("·"); Kbd("⌘⏎"); Text("details"); Text("·"); Kbd("⌘⌫"); Text("stop") }
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            Spacer()
            Menu {
                Button("Settings…") { openWindow(nil, .settings) }
                Button("Keyboard Shortcuts…") { openWindow(nil, nil); NotificationCenter.default.post(name: .showShortcuts, object: nil) }
                Divider()
                Button("Quit Running") { NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings, Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct PopoverSectionHeader: View {
    var name: String
    var body: some View {
        HStack(spacing: 5) {
            WhereIconView(name: name, size: 12)
            Text(Grouping.sectionLabel(name)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

struct PopoverJobRow: View {
    @Environment(Store.self) private var store
    var job: Job
    var highlighted: Bool
    var openWindow: () -> Void

    var body: some View {
        let j = job
        let k = store.keptFor(j)
        let pages = store.webPages(j.listen)
        HStack(spacing: 8) {
            Image(systemName: kindSymbol(j)).font(.system(size: 11)).foregroundStyle(j.agent != nil ? Color.purple : Color.accentColor).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if k != nil { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.green) }
                    Text(store.name(of: j)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(k != nil ? Color.green : Color.primary)
                        .help(store.name(of: j))
                }
                Text(Fmt.tildify(j.cwd)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if highlighted {
                HStack(spacing: 2) {
                    if !pages.isEmpty { iconButton("safari", "Open \(pages[0].url ?? "")") { store.openWeb(j) } }
                    iconButton("macwindow", "Focus its terminal") { store.focus(j) }
                    iconButton("info.circle", "Show in the Running window (⌘⏎)") { openWindow() }
                    iconButton("stop.circle", "Stop (⌘⌫)", tint: .red) { store.stop(j) }
                }
                .transition(.opacity)
            } else {
                if let a = j.agent, a.status == "working" || a.status == "new" { AgentBadge(agent: a).fixedSize() }
                PortChips(listen: j.listen, max: 1, compact: true).fixedSize()
                StateCell(stat: j.stat, etime: j.etimeSec, stop: store.stopping[j.pid], busy: store.busy.contains(j.pid))
                    .font(.caption)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openWindow() }
        .help("\(j.command)\n\(Fmt.tildify(j.cwd))")
    }

    func iconButton(_ symbol: String, _ help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .secondary)
        .help(help)
    }
}

struct PopoverKeptRow: View {
    @Environment(Store.self) private var store
    var kept: KeptEntry
    var highlighted: Bool
    var openWindow: () -> Void

    var body: some View {
        let live = store.liveJob(kept)
        HStack(spacing: 8) {
            StatusDot(color: live != nil ? .green : Color.secondary.opacity(0.35)).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(kept.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(kept.line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let live {
                PortChips(listen: live.listen, max: 1, compact: true).fixedSize()
                Text(Fmt.uptime(live.etimeSec)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button {
                if let live { store.restart(live) } else { store.start(kept) }
            } label: {
                Image(systemName: live != nil ? "arrow.clockwise" : "play.fill").font(.system(size: 11)).frame(width: 22, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(live != nil ? "Restart" : "Start in \(Preferences.label(forTerminal: store.prefs.terminal)) (⏎)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openWindow() }
    }
}
