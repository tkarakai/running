import SwiftUI

struct KeptView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 900

    var body: some View {
        @Bindable var store = store
        let items = filtered
        Group {
            if store.kept.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Kept Yet", systemImage: "bookmark")
                } description: {
                    Text("Keep a process to remember exactly how you ran it — command, directory and environment — and start it again with one click.\n\nIn Processes, select a row and press Space.")
                } actions: {
                    Button("Go to Processes") { ui.route = .processes }
                }
            } else if items.isEmpty {
                ContentUnavailableView.search(text: store.query)
            } else {
                List(selection: $store.keptSelection) {
                    ForEach(items) { k in
                        KeptRowView(kept: k).tag(k.index).listRowSeparator(.hidden)
                    }
                    .onMove { from, to in
                        guard store.query.isEmpty, let f = from.first else { return }
                        store.move(from: f, to: to > f ? to - 1 : to)
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 44)
                .environment(\.rowWidth, RowWidth(width))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .focused($focused)
                .contextMenu(forSelectionType: Int.self) { ids in
                    if let i = ids.first, let k = store.keptEntry(i) { KeptMenu(kept: k) }
                } primaryAction: { ids in
                    if let i = ids.first, let k = store.keptEntry(i) { store.start(k) }
                }
                .onKeyPress(phases: .down) { press in keys(press) }
                .onDeleteCommand { if let k = store.keptEntry(store.keptSelection) { store.confirmForget(k) } }
            }
        }
        .onAppear { focused = true; if store.keptSelection == nil { store.keptSelection = items.first?.index } }
        .onChange(of: ui.focusListTick) { focused = true }
    }

    var filtered: [KeptEntry] {
        let q = store.query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.kept }
        return store.kept.filter { "\($0.name) \($0.command) \($0.cwd) \($0.note) \($0.ports.map(String.init).joined(separator: " "))".lowercased().contains(q) }
    }

    func keys(_ press: KeyPress) -> KeyPress.Result {
        let mods = press.modifiers.subtracting([.numericPad, .function, .capsLock])
        guard mods.isEmpty || mods == .shift else { return .ignored }
        guard let k = store.keptEntry(store.keptSelection) else { return .ignored }
        let live = store.liveJob(k)
        switch press.characters {
        case "j": ui.move(store: store, by: 1)
        case "k": ui.move(store: store, by: -1)
        case "g": ui.moveTo(store: store, first: true)
        case "G": ui.moveTo(store: store, first: false)
        case "t": store.start(k, in: "tmux")
        case "e": store.editing = k
        case "d": store.confirmForget(k)
        case "R": if let live { store.restart(live) } else { store.start(k) }
        case "f": if let live { store.focus(live) } else { store.flash("Not running", .warn) }
        case "o": if let live { store.openWeb(live) } else { store.flash("Not running", .warn) }
        case "x": if let live { store.stop(live) } else { store.flash("Not running", .warn) }
        case "X": if let live { store.stop(live, force: true) } else { store.flash("Not running", .warn) }
        case "c": store.copy("cd \(k.cwd) && \(k.line)", label: "cd + command")
        case "/": ui.focusSearchTick += 1
        case "?": ui.showShortcuts = true
        default: return .ignored
        }
        return .handled
    }
}

struct KeptRowView: View {
    @Environment(Store.self) private var store
    @Environment(\.rowWidth) private var width
    @Environment(\.backgroundProminence) private var prominence
    var kept: KeptEntry
    @State private var hover = false

    var body: some View {
        let k = kept
        let live = store.liveJob(k)
        HStack(spacing: 10) {
            StatusDot(color: live != nil ? .green : Color.secondary.opacity(0.35), pulse: live != nil)
                .frame(width: 12)
                .help(live != nil ? "Running" : "Not running")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(k.name).fontWeight(.semibold).foregroundStyle(live != nil && prominence != .increased ? Color.green : Color.primary).lineLimit(1)
                    if !k.note.isEmpty { Text(k.note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                HStack(spacing: 6) {
                    Text(k.line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if width == .wide { Text("in \(k.cwd)").font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
                }
            }
            Spacer(minLength: 8)
            if let live {
                PortChips(listen: live.listen, max: 2).fixedSize()
                Text(Fmt.uptime(live.etimeSec)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: Cols.up, alignment: .trailing)
                if width > .narrow { Text(Fmt.mem(live.rssKb)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: Cols.mem, alignment: .trailing) }
            } else if !k.ports.isEmpty {
                Text(k.ports.map { ":\($0)" }.joined(separator: " ")).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button {
                if let live { store.restart(live) } else { store.start(k) }
            } label: {
                Image(systemName: live != nil ? "arrow.clockwise" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .opacity(hover || live == nil ? 1 : 0.6)
            .help(live != nil ? "Restart (⇧R)" : "Start in \(Preferences.label(forTerminal: store.prefs.terminal)) (⏎)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct KeptMenu: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    var kept: KeptEntry

    var body: some View {
        let live = store.liveJob(kept)
        Button("Start in \(Preferences.label(forTerminal: store.prefs.terminal))", systemImage: "play") { store.start(kept) }
        Menu("Start In", systemImage: "play.rectangle") {
            ForEach(Preferences.terminalOptions().filter(\.installed)) { t in
                Button(t.label) { store.start(kept, in: t.id) }
            }
        }
        if let live {
            Divider()
            Button("Restart…", systemImage: "arrow.clockwise") { store.restart(live) }
            Button("Focus Terminal", systemImage: "macwindow") { store.focus(live) }
            Button("Show in Processes", systemImage: "list.bullet.indent") { store.selection = .job(live.pid); ui.route = .processes }
            Button("Stop", systemImage: "stop.circle") { store.stop(live) }
        }
        Divider()
        Button("Edit…", systemImage: "pencil") { store.editing = kept }
        Button("Copy Command", systemImage: "doc.on.doc") { store.copy("cd \(kept.cwd) && \(kept.line)", label: "cd + command") }
        Button("Open Directory in Finder", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: Fmt.untildify(kept.cwd))) }
        Divider()
        Button("Forget…", systemImage: "trash", role: .destructive) { store.confirmForget(kept) }
    }
}

/// Inspector for a kept entry.
struct KeptInspector: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        if let k = store.keptEntry(store.keptSelection) {
            let live = store.liveJob(k)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: live != nil ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.green)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(k.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                            Text(live != nil ? "Running · \(Grouping.sectionLabel(live!.where))" : "Not running").font(.callout).foregroundStyle(live != nil ? .green : .secondary)
                        }
                    }
                    CommandBlock(command: k.line, cwd: Fmt.untildify(k.cwd))
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            if let live {
                                ActionButton(title: "Restart", symbol: "arrow.clockwise", key: "⇧R") { store.restart(live) }
                                ActionButton(title: "Focus", symbol: "macwindow", key: "f") { store.focus(live) }
                                ActionButton(title: "Stop", symbol: "stop.fill", key: "x", role: .destructive) { store.stop(live) }
                            } else {
                                ActionButton(title: "Start", symbol: "play.fill", key: "⏎") { store.start(k) }
                                ActionButton(title: "In tmux", symbol: "rectangle.split.3x1", key: "t") { store.start(k, in: "tmux") }
                                ActionButton(title: "Edit", symbol: "pencil", key: "e") { store.editing = k }
                            }
                        }
                    }
                    if let live {
                        Card(title: "Live") {
                            InfoRow(label: "Runs in") { HStack(spacing: 5) { WhereIconView(name: live.where, size: 14); Text(Grouping.sectionLabel(live.where)) } }
                            InfoRow(label: "Up") { Text(Fmt.uptimeLong(live.etimeSec)) }
                            InfoRow(label: "Memory") { Text(Fmt.memLong(live.rssKb)) }
                            if !live.listen.isEmpty { WebPagesList(listen: live.listen) }
                            Button("Show in Processes") { store.selection = .job(live.pid); ui.route = .processes }.buttonStyle(.link)
                        }
                    }
                    Card(title: "Kept") {
                        InfoRow(label: "Directory") { Text(k.cwd).textSelection(.enabled).lineLimit(2).truncationMode(.head) }
                        if !k.note.isEmpty { InfoRow(label: "Note") { Text(k.note) } }
                        InfoRow(label: "Since") { Text(Fmt.ago(iso: k.kept)) }
                        if !k.ports.isEmpty { InfoRow(label: "Ports") { Text(k.ports.map { ":\($0)" }.joined(separator: " ")).monospacedDigit() } }
                        InfoRow(label: "Env") {
                            if k.env.isEmpty { Text("no extra variables").foregroundStyle(.secondary) }
                            else { Text(k.env.keys.sorted().joined(separator: ", ")).font(.callout.monospaced()) }
                        }
                        if let s = k.session { InfoRow(label: "Session") { Text(s).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle) } }
                    }
                    HStack {
                        Button("Edit…") { store.editing = k }
                        Spacer()
                        Button("Forget…", role: .destructive) { store.confirmForget(k) }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "bookmark", description: Text("Select a kept process."))
        }
    }
}
