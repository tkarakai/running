import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater
    @State private var launchAtLogin = Preferences.shared.launchAtLogin
    @State private var options = Preferences.terminalOptions()

    var updateStatus: String {
        if let r = updater.available { return "v\(r.version) available" }
        if let e = updater.lastError { return "Couldn't check: \(e)" }
        guard let t = updater.lastChecked else { return "Checks GitHub every few hours" }
        return "Up to date · checked \(t.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        @Bindable var prefs = store.prefs
        Form {
            if let r = updater.available {
                Section {
                    HStack(spacing: 12) {
                        UpdateDot(size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update app: v\(Variant.version) → v\(r.version)").font(.headline)
                            Text("Running quits and reopens; your processes keep running.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update…") { updater.askToInstall() }.buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { updater.askToInstall() }
                }
            }
            Section("Starting processes") {
                Picker("Start kept processes in", selection: $prefs.terminal) {
                    ForEach(options) { t in
                        HStack {
                            if let i = t.icon { Image(nsImage: i).resizable().frame(width: 16, height: 16) }
                            Text(t.label + (t.installed ? "" : " — not installed"))
                        }
                        .tag(t.id)
                    }
                }
                Text("A new window opens in the process's directory and the command is typed into its shell — as if you typed it, so it's in your history and Running can find it again. Restarts use the same terminal when they can (tmux pane, Orca tab).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Menu bar") {
                Toggle(isOn: $prefs.hotKeyEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shortcuts from any app")
                        HStack(spacing: 6) { Kbd(Variant.current.panelShortcut); Text("the menu bar panel").foregroundStyle(.secondary) }.font(.callout)
                        HStack(spacing: 6) { Kbd(Variant.current.windowShortcut); Text("this window").foregroundStyle(.secondary) }.font(.callout)
                    }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in prefs.launchAtLogin = v; launchAtLogin = prefs.launchAtLogin }
            }

            Section("Safety") {
                Toggle("Ask before stopping a process", isOn: $prefs.confirmStop)
                Text("Force-kill (kill -9) always asks.").font(.callout).foregroundStyle(.secondary)
            }

            Section("Shell integration") {
                if let h = store.hello {
                    LabeledContent("Command log") {
                        if h.shell.zshrc {
                            Label(h.shell.logAgeSec.map { "active — last command \(Fmt.uptime(Int($0))) ago" } ?? "set up in ~/.zshrc", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("not set up", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                    }
                    if !h.shell.zshrc {
                        Text("Add this line to ~/.zshrc so Running can name jobs whose launcher exited (`bun dev`), show what you typed, and find terminal tabs. It needs the `running` command on your PATH.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(#"eval "$(command running init)""#).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Copy") { store.copy(#"eval "$(command running init)""#, label: "the line") }
                        }
                    }
                    LabeledContent("Kept processes") {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.keptFile)]) } label: {
                            Text(Fmt.tildify(h.keptFile)).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help("Show in Finder — plain YAML, safe to edit by hand")
                    }
                    LabeledContent("Command log file") { Text(Fmt.tildify(h.logFile)).textSelection(.enabled).foregroundStyle(.secondary) }
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(Variant.versionLabel).textSelection(.enabled)
                        if Variant.current.isDev { Text("DEV").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).background(.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange) }
                    }
                }
                if updater.enabled {
                    LabeledContent("Updates") {
                        HStack(spacing: 10) {
                            if updater.checking { ProgressView().controlSize(.small) }
                            Text(updateStatus).foregroundStyle(.secondary)
                            Button("Check Now") { Task { await updater.check() } }.disabled(updater.checking)
                        }
                    }
                } else {
                    LabeledContent("Updates") { Text("Dev build — rebuild with `bun run install-app`").foregroundStyle(.secondary) }
                }
                if let h = store.hello { LabeledContent("Engine") { Text("running \(h.version) · Bun \(h.bun)").foregroundStyle(.secondary) } }
                LabeledContent("Also in your terminal") { Text("running").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary) }
                Button("Keyboard Shortcuts…") { NotificationCenter.default.post(name: .showShortcuts, object: nil) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .onAppear { options = Preferences.terminalOptions(); launchAtLogin = Preferences.shared.launchAtLogin }
    }
}

extension Notification.Name {
    static let showShortcuts = Notification.Name("running.showShortcuts")
}

struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    let groups: [(String, [(String, String)])] = [
        ("From any app", [
            (Variant.current.panelShortcut, "Open the menu bar panel"),
            (Variant.current.windowShortcut, "Open this window (again: put it away)"),
            ("⌘-Tab", "Back to this window while it's open"),
        ]),
        ("A job or one of its processes", [
            ("→  ←", "Show / hide a job's processes"),
            ("⏎  or double-click", "Open its web page, else focus its terminal"),
            ("o", "Open its web page"),
            ("f", "Focus its terminal (tmux, Orca, Terminal, iTerm2, Ghostty…)"),
            ("p", "Show its output (terminal, conversation, log files)"),
            ("i", "Show its details"),
            ("c  ⌘C", "Copy `cd dir && command`"),
            ("x  ⌘⌫", "Stop (SIGTERM; again after 3 s: kill -9)"),
            ("X", "Force-kill now (kill -9)"),
        ]),
        ("Processes", [
            ("space", "Keep it"),
            ("⇧R", "Restart: stop, then run it again"),
            ("a", "Show app & system servers"),
            ("s  then t m c n r", "Sort: started, memory, CPU, name, reverse"),
        ]),
        ("Kept", [
            ("⏎", "Start in your terminal"),
            ("t", "Start in a new tmux window"),
            ("e", "Edit"),
            ("d  ⌫", "Forget (with undo)"),
            ("⇧R", "Restart if running"),
        ]),
        ("Everywhere", [
            ("↑ ↓  j k  g G", "Move"),
            ("/  ⌘F", "Filter"),
            ("esc", "Clear the filter"),
            ("⌘1  ⌘2", "Processes / Kept"),
            ("⌘I", "Show / hide the inspector"),
            ("⌃⌘S", "Show / hide the sidebar"),
            ("⌘R", "Refresh now"),
            ("⌘,", "Settings"),
            ("⌘W", "Close the window (Running stays in the menu bar)"),
            ("⌘Q", "Quit Running"),
            ("?", "This list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(groups, id: \.0) { g in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(g.0).font(.headline)
                            ForEach(g.1, id: \.0) { k, d in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(k).font(.system(.callout, design: .rounded).weight(.medium)).foregroundStyle(Color.accentColor)
                                        .frame(width: 128, alignment: .leading)
                                    Text(d).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 560)
    }
}
