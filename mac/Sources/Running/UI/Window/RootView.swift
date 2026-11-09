import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    @FocusState private var searchFocused: Bool
    @State private var windowWidth: CGFloat = 1200
    @State private var autoHidSidebar = false

    var body: some View {
        @Bindable var ui = ui
        @Bindable var store = store
        @Bindable var prefs = store.prefs
        NavigationSplitView(columnVisibility: $ui.sidebarVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            detail
                .inspector(isPresented: inspectorBinding) {
                    inspector.inspectorColumnWidth(min: 280, ideal: 340, max: 520)
                }
                .searchable(text: $store.query, placement: .toolbar, prompt: searchPrompt)
                .searchFocused($searchFocused)
                .onSubmit(of: .search) { ui.focusListTick += 1 }
                .toolbar { toolbar }
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        }
        .toasts()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            windowWidth = w
            // Narrow window: the list keeps its room — the sidebar goes first, then the inspector.
            if w < (store.prefs.inspectorShown ? 960 : 760), ui.sidebarVisibility != .detailOnly {
                autoHidSidebar = true
                if w < 720 { ui.inspectorForced = false }
                withAnimation { ui.sidebarVisibility = .detailOnly }
            } else if w >= (store.prefs.inspectorShown ? 1040 : 840), autoHidSidebar {
                autoHidSidebar = false
                withAnimation { ui.sidebarVisibility = .all }
            }
        }
        .sheet(item: keepBinding) { item in
            KeepForm(mode: .keep(pid: item.pid), title: item.draft.title, name: item.draft.name, command: item.draft.command,
                     cwd: item.draft.cwd, note: item.draft.note, env: item.draft.env)
        }
        .sheet(item: $store.editing) { k in
            KeepForm(mode: .edit(index: k.index), title: "Edit “\(k.name)”", name: k.name, command: k.command, cwd: k.cwd, note: k.note,
                     env: k.env.keys.sorted().map { EnvChoice(key: $0, value: k.env[$0] ?? "", secret: false, selected: true) })
        }
        .sheet(isPresented: $ui.showShortcuts) { ShortcutsView() }
        .alert(store.confirmation?.title ?? "", isPresented: confirmBinding, presenting: store.confirmation) { c in
            Button(c.action, role: c.destructive ? .destructive : nil) { c.run() }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.message) }
        .onChange(of: ui.focusSearchTick) { searchFocused = true }
        .overlay {
            if let f = store.fatal {
                ContentUnavailableView {
                    Label("Running's engine isn't available", systemImage: "exclamationmark.triangle")
                } description: { Text(f) } actions: {
                    Button("Try Again") { store.fatal = nil; store.start() }
                }
                .background(.regularMaterial)
            }
        }
    }

    var inspectorBinding: Binding<Bool> {
        Binding(get: { store.prefs.inspectorShown && (ui.route == .processes || ui.route == .kept) && (windowWidth >= 720 || ui.inspectorForced) },
                set: { v in
                    // Hidden because the window got narrow: not the person's choice, keep the preference.
                    if !v && windowWidth < 720 && !ui.inspectorForced { return }
                    store.prefs.inspectorShown = v
                    ui.inspectorForced = v && windowWidth < 720
                })
    }

    struct DraftItem: Identifiable { var pid: Int; var draft: KeepDraft; var id: Int { pid } }
    var keepBinding: Binding<DraftItem?> {
        Binding(get: { store.keepDraft.map { DraftItem(pid: $0.pid, draft: $0.draft) } }, set: { if $0 == nil { store.keepDraft = nil } })
    }
    var confirmBinding: Binding<Bool> {
        Binding(get: { store.confirmation != nil && !store.popoverVisible }, set: { if !$0 { store.confirmation = nil } })
    }

    @ViewBuilder var detail: some View {
        switch ui.route {
        case .processes: ProcessesView()
        case .kept: KeptView()
        case .settings: SettingsView()
        case .tool: ContentUnavailableView("Coming Soon", systemImage: "hammer")
        }
    }

    @ViewBuilder var inspector: some View {
        switch ui.route {
        case .kept: KeptInspector()
        default: InspectorView()
        }
    }

    var title: String {
        switch ui.route {
        case .processes: return "Processes"
        case .kept: return "Kept"
        case .settings: return "Settings"
        case .tool(let t): return t
        }
    }

    var subtitle: String {
        switch ui.route {
        case .processes:
            guard store.loaded else { return "" }
            let n = store.visibleCount
            let web = store.rows.filter { store.showAll || $0.kind != .app }.filter { !store.webPages($0.listen).isEmpty }.count
            return "\(n) job\(n == 1 ? "" : "s")" + (web > 0 ? " · \(web) serving web pages" : "") + (store.showAll ? " · including apps" : "")
        case .kept:
            let live = store.kept.filter { $0.livePid != nil }.count
            return "\(store.kept.count) kept · \(live) running"
        default: return ""
        }
    }

    var searchPrompt: String { ui.route == .kept ? "Filter kept" : "Filter — command, directory, port…" }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        if ui.route == .processes {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: Binding(get: { store.sort }, set: { store.setSort($0) })) {
                        ForEach(SortKey.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("Order", selection: Binding(get: { store.sortDesc }, set: { store.setSort(store.sort, desc: $0) })) {
                        Text(store.sort.dirLabel.0).tag(false)
                        Text(store.sort.dirLabel.1).tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort: \(store.sort.label.lowercased()), \((store.sortDesc ? store.sort.dirLabel.1 : store.sort.dirLabel.0).lowercased())  (s)")

                Toggle(isOn: Binding(get: { store.showAll }, set: { store.showAll = $0 })) {
                    Label("App & System Servers", systemImage: "app.badge")
                }
                .help(store.showAll ? "Hide app & system servers (a)" : "Also show servers that belong to apps & macOS (a)")
            }
        }
        if ui.route == .processes || ui.route == .kept {
            ToolbarItem {
                Button {
                    if windowWidth < 720 && !ui.inspectorForced { store.prefs.inspectorShown = true; ui.inspectorForced = true }
                    else { store.prefs.inspectorShown.toggle(); ui.inspectorForced = false }
                } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show / hide the inspector (⌘I)")
            }
        }
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        List(selection: Binding<Route?>(get: { ui.route }, set: { if let r = $0 { ui.route = r } })) {
            ForEach(ToolRegistry.all, id: \.id) { tool in
                Section(tool.title) {
                    ForEach(tool.pages(store)) { page in
                        Label(page.title, systemImage: page.symbol)
                            .badge(tool.badge(page, store) ?? 0)
                            .tag(page.route)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button { ui.route = .settings } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(ui.route == .settings ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .help("Settings (⌘,)")
            }
        }
    }
}
