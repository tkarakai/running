import SwiftUI

/// Recent output of a job or one of its processes: terminal scrollback (tmux, Orca), the log
/// files it writes to, or an agent's conversation. Refreshes while shown.
struct OutputView: View {
    @Environment(Store.self) private var store
    var job: Job
    var member: Member?

    @State private var data: PeekData?
    @State private var source: String?
    @State private var follow = true
    @State private var filter = ""
    @State private var wrap = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let d = data {
                let lines = filter.isEmpty ? d.lines : d.lines.filter { $0.localizedCaseInsensitiveContains(filter) }
                if d.lines.isEmpty || d.title == "no output available" {
                    ContentUnavailableView {
                        Label("No Output Available", systemImage: "text.badge.xmark")
                    } description: {
                        Text(d.lines.filter { !$0.isEmpty }.joined(separator: "\n"))
                    } actions: {
                        if job.tty != "??" { Button("Focus Its Terminal") { store.focus(job) } }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                    line(l, kind: d.kind).id(i)
                                }
                                Color.clear.frame(height: 1).id("end")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .textSelection(.enabled)
                        }
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                        .onChange(of: d) { if follow && filter.isEmpty { proxy.scrollTo("end", anchor: .bottom) } }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source) {
            while !Task.isCancelled {
                if let d = await store.peek(pid: job.pid, child: member?.pid, source: source) {
                    if d != data { data = d }
                }
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    @ViewBuilder func line(_ s: String, kind: String) -> some View {
        let t = Text(s.isEmpty ? " " : s).font(.system(size: 11.5, design: .monospaced))
        if kind == "conversation" {
            if s.hasPrefix("› you:") { t.foregroundStyle(Color.accentColor).fontWeight(.semibold) }
            else if s.hasPrefix("‹ ") { t.foregroundStyle(.purple) }
            else if s.trimmingCharacters(in: .whitespaces).hasPrefix("⚙") { t.foregroundStyle(.secondary) }
            else { t }
        } else {
            t.foregroundStyle(tone(s))
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: false)
        }
    }

    func tone(_ s: String) -> Color {
        let l = s.lowercased()
        if l.contains("error") || l.contains("fatal") || l.contains("panic") || l.contains("exception") { return .red }
        if l.contains("warn") { return .orange }
        return .primary
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                let sources = data?.sources ?? []
                Menu {
                    Button { source = nil } label: { Label(defaultLabel, systemImage: "terminal") }
                    ForEach(sources, id: \.self) { s in
                        Button { source = s } label: {
                            if s == "@transcript" { Label("Conversation", systemImage: "bubble.left.and.text.bubble.right") }
                            else { Label(Fmt.tildify(s), systemImage: "doc.text") }
                        }
                    }
                } label: {
                    Label(currentLabel, systemImage: source == "@transcript" ? "bubble.left.and.text.bubble.right" : (source == nil ? "terminal" : "doc.text"))
                        .lineLimit(1).truncationMode(.head)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(sources.isEmpty)
                .help(data?.title ?? "")
                Spacer()
                Toggle(isOn: $wrap) { Image(systemName: "text.word.spacing") }.toggleStyle(.button).buttonStyle(.borderless).help("Wrap long lines")
                Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }.toggleStyle(.button).buttonStyle(.borderless).help("Follow new output")
                Button { store.copy(data?.lines.joined(separator: "\n") ?? "", label: "output") } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy all output")
                if job.tty != "??" || !job.termLabel.isEmpty {
                    Button { store.focus(job) } label: { Image(systemName: "macwindow") }.buttonStyle(.borderless).help("Focus its terminal (f)")
                }
            }
            TextField("Filter lines", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    var defaultLabel: String {
        if job.termLabel.hasPrefix("tmux") { return "tmux pane" }
        if job.termLabel == "Orca tab" { return "Orca terminal" }
        return "Terminal / log"
    }

    var currentLabel: String {
        guard let s = source else { return data.map { $0.title.hasPrefix("/") ? Fmt.basename($0.title) : $0.title } ?? defaultLabel }
        return s == "@transcript" ? "Conversation" : Fmt.basename(s)
    }
}
