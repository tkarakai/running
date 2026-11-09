import SwiftUI

struct ProcessesView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    @FocusState private var listFocused: Bool
    @State private var width: CGFloat = 900

    var body: some View {
        @Bindable var store = store
        let sections = store.sections
        Group {
            if !store.loaded {
                ProgressView("Looking at what's running…").controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sections.isEmpty {
                empty
            } else {
                List(selection: $store.selection) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.dirs) { group in
                                DirHeaderView(group: group, muted: section.muted)
                                    .selectionDisabled()
                                    .listRowSeparator(.hidden)
                                ForEach(group.lines) { line in
                                    row(line).tag(line.id).listRowSeparator(.hidden)
                                }
                            }
                        } header: {
                            SectionHeaderView(section: section)
                        }
                    }
                }
                .listStyle(.inset)
                .environment(\.rowWidth, RowWidth(width))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .alternatingRowBackgrounds(.disabled)
                .environment(\.defaultMinListRowHeight, 26)
                .focused($listFocused)
                .contextMenu(forSelectionType: ItemID.self) { ids in
                    if let id = ids.first { ItemMenu(id: id) }
                } primaryAction: { ids in
                    if let id = ids.first { primary(id) }
                }
                .onKeyPress(phases: .down) { press in keys(press) }
                .onCopyCommand {
                    guard let j = store.selectedJob else { return [] }
                    let m = store.selectedMember
                    return [NSItemProvider(object: "cd \(Fmt.tildify(m?.cwd ?? j.cwd)) && \(m?.argvCommand ?? j.command)" as NSString)]
                }
            }
        }
        .overlay(alignment: .top) { if ui.sortMenu { SortHUD().padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity)) } }
        .onAppear { listFocused = true }
        .onChange(of: ui.focusListTick) { listFocused = true }
    }

    @ViewBuilder func row(_ line: ListLine) -> some View {
        switch line.kind {
        case .job(let depth):
            JobRowView(job: line.job, depth: depth, selected: store.selection == line.id)
        case .member(let m, let depth):
            MemberRowView(job: line.job, member: m, depth: depth)
        }
    }

    var empty: some View {
        Group {
            if !store.query.isEmpty {
                ContentUnavailableView.search(text: store.query)
            } else {
                ContentUnavailableView {
                    Label("Nothing running", systemImage: "moon.stars")
                } description: {
                    Text("No processes you started are running right now.")
                } actions: {
                    Button("Show App & System Servers") { store.showAll = true }
                }
            }
        }
    }

    /// Double-click / Return: open its web page if it has one, otherwise focus its terminal.
    func primary(_ id: ItemID) {
        guard let j = store.job(id.jobPid) else { return }
        let m: Member? = { if case .member(_, let p) = id { return j.members.first { $0.pid == p } }; return nil }()
        if !store.webPages(m?.listen ?? j.listen).isEmpty { store.openWeb(j, member: m) } else { store.focus(j) }
    }

    func keys(_ press: KeyPress) -> KeyPress.Result {
        if ui.sortMenu { return ui.sortKey(press, store: store) }
        let mods = press.modifiers.subtracting([.numericPad, .function, .capsLock])
        guard mods.isEmpty || mods == .shift else { return .ignored }
        let sel = store.selection
        let j = store.selectedJob
        let m = store.selectedMember
        switch press.key {
        case .rightArrow:
            if let j, m == nil, !j.members.isEmpty {
                if !store.expanded.contains(j.pid) { store.setExpanded(j.pid, true) } else { ui.move(store: store, by: 1) }
                return .handled
            }
            return .ignored
        case .leftArrow:
            if let j, m != nil { store.setExpanded(j.pid, false); store.selection = .job(j.pid); return .handled }
            if let j, store.expanded.contains(j.pid) { store.setExpanded(j.pid, false); return .handled }
            return .ignored
        case .space:
            guard let j else { return .ignored }
            if m != nil { store.flash("This process is part of “\(store.name(of: j))” — keep the whole job from its row (←)", .info); return .handled }
            store.beginKeep(j)
            return .handled
        case .escape:
            if !store.query.isEmpty { store.query = ""; return .handled }
            return .ignored
        default: break
        }
        switch press.characters {
        case "j": ui.move(store: store, by: 1)
        case "k": ui.move(store: store, by: -1)
        case "g": ui.moveTo(store: store, first: true)
        case "G": ui.moveTo(store: store, first: false)
        case "o": if let j { store.openWeb(j, member: m) }
        case "f": if let j { store.focus(j) }
        case "p": if j != nil { ui.inspectorTab = .output; store.prefs.inspectorShown = true }
        case "i", "d": if j != nil { ui.inspectorTab = .details; store.prefs.inspectorShown = true }
        case "c": if let j { store.copyCommand(j, member: m) }
        case "x": if let j { store.stop(j, member: m) }
        case "X": if let j { store.stop(j, member: m, force: true) }
        case "R":
            guard let j else { return .ignored }
            if m != nil { store.flash("This process is part of “\(store.name(of: j))” — restart the whole job from its row (←)", .info) } else { store.restart(j) }
        case "r": Task { await store.refresh() }; store.flash("Refreshed", .info)
        case "a":
            store.showAll.toggle()
            store.flash(store.showAll ? "Showing app & system servers too" : "Hiding app & system servers", .info)
        case "s": withAnimation(.snappy) { ui.sortMenu = true }
        case "/": ui.focusSearchTick += 1
        case "?": ui.showShortcuts = true
        default: return .ignored
        }
        _ = sel
        return .handled
    }
}

/// `s` then a letter, as in the TUI.
struct SortHUD: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    var body: some View {
        HStack(spacing: 14) {
            Text("Sort by").font(.callout.weight(.semibold))
            ForEach(SortKey.allCases) { k in
                Button {
                    store.setSort(k); ui.sortMenu = false
                } label: {
                    HStack(spacing: 4) {
                        Kbd(String(k == .started ? "t" : k.rawValue.prefix(1)))
                        Text(k.label).fontWeight(store.sort == k ? .semibold : .regular)
                        if store.sort == k { Image(systemName: store.sortDesc ? "arrow.down" : "arrow.up").font(.caption) }
                    }
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 14)
            Button { store.reverseSort(); ui.sortMenu = false } label: { HStack(spacing: 4) { Kbd("r"); Text("Reverse") } }.buttonStyle(.plain)
            Button { ui.sortMenu = false } label: { Kbd("esc") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
    }
}

/// The right-click menu for a job or one of its processes.
struct ItemMenu: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    var id: ItemID

    var body: some View {
        if let j = store.job(id.jobPid) {
            let m: Member? = { if case .member(_, let p) = id { return j.members.first { $0.pid == p } }; return nil }()
            let pages = store.webPages(m?.listen ?? j.listen)
            if pages.count == 1, let u = pages[0].url {
                Button("Open \(u.trimmingCharacters(in: CharacterSet(charactersIn: "/")))", systemImage: "safari") { store.open(url: u) }
            } else if pages.count > 1 {
                Menu("Open Web Page", systemImage: "safari") {
                    ForEach(pages, id: \.self) { p in Button("\(p.url ?? "")\(p.title.map { " — \($0)" } ?? "")") { store.open(url: p.url ?? "") } }
                }
            }
            Button("Focus Terminal", systemImage: "macwindow") { store.focus(j) }
            Button("Show Output", systemImage: "text.alignleft") { store.selection = id; ui.inspectorTab = .output; store.prefs.inspectorShown = true }
            Divider()
            Button("Copy Command", systemImage: "doc.on.doc") { store.copyCommand(j, member: m) }
            if m == nil {
                Button("Copy PID") { store.copy(String(j.pid), label: "pid \(j.pid)") }
                if !j.cwd.isEmpty { Button("Open Directory in Finder", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: j.cwd)) } }
                Divider()
                if let k = store.keptFor(j) {
                    Button("Kept as “\(k.name)”…", systemImage: "bookmark.fill") { ui.route = .kept; store.keptSelection = k.index }
                } else {
                    Button("Keep…", systemImage: "bookmark") { store.beginKeep(j) }
                }
                Button("Restart…", systemImage: "arrow.clockwise") { store.restart(j) }
            }
            Divider()
            Button(m == nil ? "Stop" : "Stop This Process", systemImage: "stop.circle") { store.stop(j, member: m) }
            Button("Force Kill (kill -9)", systemImage: "xmark.octagon") { store.stop(j, member: m, force: true) }
        }
    }
}
