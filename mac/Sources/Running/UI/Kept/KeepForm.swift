import SwiftUI

/// Keep a running process, or edit a kept one: name, command, directory, note, environment.
struct KeepForm: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Mode { case keep(pid: Int), edit(index: Int) }
    var mode: Mode
    var title: String

    @State var name: String
    @State var command: String
    @State var cwd: String
    @State var note: String
    @State var env: [EnvChoice]
    @State private var saving = false
    @State private var revealed: Set<String> = []
    @State private var newKey = ""
    @State private var newValue = ""
    @FocusState private var nameFocused: Bool

    init(mode: Mode, title: String, name: String, command: String, cwd: String, note: String, env: [EnvChoice]) {
        self.mode = mode
        self.title = title
        _name = State(initialValue: name)
        _command = State(initialValue: command)
        _cwd = State(initialValue: cwd)
        _note = State(initialValue: note)
        _env = State(initialValue: env)
    }

    var isEdit: Bool { if case .edit = mode { return true }; return false }
    var valid: Bool { !command.trimmingCharacters(in: .whitespaces).isEmpty && !cwd.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bookmark.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(isEdit ? "Changes are saved to kept.yaml." : "Remember exactly how it was run, to start it again later.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            label("Name")
                            TextField("", text: $name, prompt: Text("A short name"))
                                .textFieldStyle(.roundedBorder)
                                .focused($nameFocused)
                        }
                        GridRow {
                            label("Command")
                            TextField("", text: $command, prompt: Text("What gets typed at the prompt"), axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1...5)
                        }
                        GridRow {
                            label("Directory")
                            HStack {
                                TextField("", text: $cwd, prompt: Text("~/path/to/project"))
                                    .textFieldStyle(.roundedBorder)
                                    .truncationMode(.head)
                                Button("Choose…") { chooseDir() }
                            }
                        }
                        GridRow {
                            label("Note")
                            TextField("", text: $note, prompt: Text("Optional — e.g. best settings so far"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Environment").font(.headline)
                            Text("checked variables are put in front of the command").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            if env.isEmpty {
                                Text(isEdit ? "No extra variables." : "No variables differ from a fresh shell.").foregroundStyle(.secondary).font(.callout)
                            }
                            ForEach($env) { $e in
                                Toggle(isOn: $e.selected) {
                                    HStack(spacing: 6) {
                                        Text(e.key).font(.system(.callout, design: .monospaced).weight(.medium))
                                        Text("=").foregroundStyle(.tertiary)
                                        Text(e.secret && !revealed.contains(e.key) ? String(repeating: "•", count: min(12, max(4, e.value.count))) : e.value)
                                            .font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                            .textSelection(.enabled)
                                        if e.secret {
                                            Button { if revealed.contains(e.key) { revealed.remove(e.key) } else { revealed.insert(e.key) } } label: {
                                                Image(systemName: revealed.contains(e.key) ? "eye.slash" : "eye")
                                            }.buttonStyle(.borderless).help("Show / hide — looks like a secret, so it's off by default")
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                            Divider().padding(.vertical, 2)
                            HStack(spacing: 6) {
                                TextField("", text: $newKey, prompt: Text("NAME"))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced)).frame(width: 150)
                                Text("=").foregroundStyle(.tertiary)
                                TextField("", text: $newValue, prompt: Text("value"))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced))
                                    .onSubmit { addVar() }
                                Button("Add Variable") { addVar() }.disabled(!validKey)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if isEdit, case .edit(let i) = mode, let k = store.keptEntry(i) {
                    Button("Forget…", role: .destructive) { dismiss(); store.confirmForget(k) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Keep") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || saving)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 560)
        .onAppear { nameFocused = true }
    }

    func label(_ t: String) -> some View {
        Text(t).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    var validKey: Bool { newKey.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }

    func addVar() {
        guard validKey else { return }
        env.removeAll { $0.key == newKey }
        env.append(EnvChoice(key: newKey, value: newValue, secret: false, selected: true))
        newKey = ""; newValue = ""
    }

    func chooseDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: Fmt.untildify(cwd))
        if p.runModal() == .OK, let u = p.url { cwd = Fmt.tildify(u.path) }
    }

    func save() {
        saving = true
        let v = Store.FormValues(name: name, command: command, cwd: cwd, note: note, env: env)
        Task {
            let ok: Bool
            switch mode {
            case .keep(let pid): ok = await store.saveKeep(pid: pid, v)
            case .edit(let i): ok = await store.saveEdit(index: i, v)
            }
            saving = false
            if ok { dismiss() }
        }
    }
}
