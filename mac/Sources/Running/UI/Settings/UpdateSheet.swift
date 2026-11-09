import SwiftUI

/// The update, start to finish, in one sheet: what's new and a warning that Running restarts,
/// then a checklist — download (with a real progress bar), verify, install, restart.
struct UpdateSheet: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch updater.phase {
                case .confirming, .idle: notes
                case .failed(let msg): failure(msg)
                default: progress
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 520, height: 500)
        .interactiveDismissDisabled(updater.phase.isBusy)
        .animation(.smooth(duration: 0.35), value: stepIndex)
    }

    var release: Updater.Release? { updater.available }

    // ── header: the icon and the versions ────────────────────────────────
    var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    VersionPill(text: "v\(Variant.version)", current: false)
                    Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    VersionPill(text: "v\(release?.version ?? "?")", current: true)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    var title: String {
        switch updater.phase {
        case .confirming, .idle: return "A new version of Running"
        case .failed: return "The update didn't finish"
        case .relaunching: return "Restarting…"
        default: return "Updating Running"
        }
    }

    // ── confirm: release notes and the warning ───────────────────────────
    var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                ReleaseNotes(markdown: release?.notes ?? "")
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running will quit and reopen").font(.callout.weight(.semibold))
                    Text("Your processes keep running — Running only watches them. It takes a few seconds.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding([.horizontal, .bottom], 20)
        }
    }

    // ── progress: a checklist, the download with a bar ───────────────────
    var stepIndex: Int {
        switch updater.phase {
        case .downloading: return 0
        case .verifying: return 1
        case .installing: return 2
        case .relaunching: return 3
        default: return -1
        }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepRow(index: 0, current: stepIndex, title: "Download", detail: downloadDetail) {
                if case .downloading(let got, let total) = updater.phase {
                    ProgressView(value: Double(got), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            StepRow(index: 1, current: stepIndex, title: "Verify", detail: "Checksum from GitHub, code signature, version") { EmptyView() }
            StepRow(index: 2, current: stepIndex, title: "Install", detail: Fmt.tildify(Bundle.main.bundlePath)) { EmptyView() }
            StepRow(index: 3, current: stepIndex, title: "Restart", detail: "Running reopens with v\(release?.version ?? "")") { EmptyView() }
            Spacer()
        }
        .padding(24)
    }

    var downloadDetail: String {
        guard case .downloading(let got, let total) = updater.phase else {
            return release.map { "Disk image · \(Self.mb($0.size))" } ?? ""
        }
        var s = "\(Self.mb(got)) of \(Self.mb(total))"
        if updater.speed > 1 {
            s += " · \(Self.mb(Int64(updater.speed)))/s"
            let left = Double(total - got) / updater.speed
            if left >= 1 { s += " · \(Int(left.rounded())) s left" }
        }
        return s
    }

    static func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }

    // ── failure ──────────────────────────────────────────────────────────
    func failure(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
            Text(msg).font(.body).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Nothing was changed — this version keeps working.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(30)
    }

    // ── footer: the buttons for each phase ───────────────────────────────
    var footer: some View {
        HStack {
            if let page = release?.page {
                Link(destination: page) { Label("Release on GitHub", systemImage: "arrow.up.right.square") }
                    .font(.callout)
            }
            Spacer()
            switch updater.phase {
            case .confirming, .idle:
                Button("Later") { updater.phase = .idle }.keyboardShortcut(.cancelAction)
                Button("Update & Restart") { updater.install() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            case .downloading:
                Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction)
            case .failed:
                Button("Close") { updater.phase = .idle }.keyboardShortcut(.cancelAction)
                Button("Try Again") { updater.install() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            default:
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
    }
}

private struct VersionPill: View {
    var text: String
    var current: Bool
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(current ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(current ? Color.accentColor : .secondary)
    }
}

/// One line of the checklist: a numbered circle that turns into a spinner, then a checkmark.
private struct StepRow<Extra: View>: View {
    var index: Int
    var current: Int
    var title: String
    var detail: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if index < current {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else if index == current {
                    Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 24, height: 24)
                    ProgressView().controlSize(.small)
                } else {
                    Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 22, height: 22)
                    Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(index > current ? .secondary : .primary)
                Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .contentTransition(.numericText())
                if index == current { extra() }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The CHANGELOG section a release carries: `### Heading`, `- bullet` (wrapped lines indented),
/// inline **bold** / `code` / links.
struct ReleaseNotes: View {
    var markdown: String

    enum Block: Hashable { case heading(String), bullet(String), text(String) }

    var blocks: [Block] {
        var out: [Block] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else if raw.hasPrefix(" "), case .bullet(let b)? = out.last {
                out[out.count - 1] = .bullet(b + " " + line)
            } else if case .text(let t)? = out.last {
                out[out.count - 1] = .text(t + " " + line)
            } else {
                out.append(.text(line))
            }
        }
        return out
    }

    func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if blocks.isEmpty { Text("No release notes.").foregroundStyle(.secondary) }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h): Text(h).font(.headline).padding(.top, 6)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                    }
                case .text(let t): Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}
