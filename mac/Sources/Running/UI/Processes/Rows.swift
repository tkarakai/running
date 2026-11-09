import SwiftUI

struct SectionHeaderView: View {
    var section: WhereSection
    var body: some View {
        HStack(spacing: 7) {
            WhereIconView(name: section.key, size: 16)
            Text(section.label).font(.headline).foregroundStyle(section.muted ? .secondary : .primary)
            if let tag = section.tag {
                Text(tag).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(section.count)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
        }
        .padding(.top, 4)
    }
}

struct DirHeaderView: View {
    @Environment(Store.self) private var store
    var group: DirGroup
    var muted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
            Text(group.dir.isEmpty ? "(unknown directory)" : Fmt.tildify(group.dir))
                .font(.callout.weight(.medium))
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.8)))
                .lineLimit(1).truncationMode(.head)
                .help(group.dir)
            if let b = group.branch {
                Label(b, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.teal)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 2)
        .contextMenu {
            if !group.dir.isEmpty {
                Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: group.dir)) }
                Button("Copy Path") { store.copy(group.dir, label: "path") }
            }
        }
    }
}

/// How much room a list row has: rows drop columns as the list narrows.
enum RowWidth: Int, Comparable {
    case narrow, medium, wide
    static func < (a: RowWidth, b: RowWidth) -> Bool { a.rawValue < b.rawValue }
    init(_ w: CGFloat) { self = w < 470 ? .narrow : w < 680 ? .medium : .wide }
}

extension EnvironmentValues {
    @Entry var rowWidth: RowWidth = .wide
}

/// Fixed-width trailing columns, so numbers line up down the list.
enum Cols {
    static let up: CGFloat = 50
    static let mem: CGFloat = 52
    static let ports: CGFloat = 150
}

struct JobRowView: View {
    @Environment(Store.self) private var store
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.rowWidth) private var width
    var job: Job
    var depth: Int
    var selected: Bool

    var body: some View {
        let kept = store.keptFor(job)
        let open = store.expanded.contains(job.pid)
        let (prog, args) = split(job)
        HStack(spacing: 6) {
            if depth > 0 {
                Color.clear.frame(width: CGFloat(depth) * 16 - 6)
                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
            }
            // disclosure
            Group {
                if !job.members.isEmpty {
                    Button { store.setExpanded(job.pid, !open) } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(open ? "Hide its processes  ←" : "Show its \(job.members.count + 1) processes  →")
                } else {
                    Color.clear.frame(width: 14)
                }
            }
            Image(systemName: kindSymbol(job))
                .font(.system(size: 12))
                .foregroundStyle(job.agent != nil ? Color.purple : (job.kind == .app ? Color.secondary : Color.accentColor))
                .frame(width: 16)
            if let k = kept {
                Text(k.name).fontWeight(.semibold).foregroundStyle(prominence == .increased ? Color.primary : Color.green)
                    .lineLimit(1).layoutPriority(3).frame(minWidth: 40, alignment: .leading)
            }
            if kept == nil || width > .narrow {
                Text(prog)
                    .fontWeight(kept == nil ? .semibold : .regular)
                    .italic(job.source == .history)
                    .foregroundStyle(job.kind == .app ? .secondary : (kept == nil ? .primary : .secondary))
                    .lineLimit(1)
                    .layoutPriority(kept == nil ? 3 : 1)
                    .frame(minWidth: kept == nil ? 40 : 0, alignment: .leading)
            }
            if let a = job.agent {
                if width > .narrow { AgentBadge(agent: a).fixedSize() }
                if let t = a.title { Text(t).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
            } else if !args.isEmpty && width > .narrow {
                Text(args).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).italic(job.source == .history)
            }
            if job.leaderGone {
                Text(width > .narrow ? "⤷ exited" : "⤷").font(.caption2.weight(.medium)).foregroundStyle(.orange).fixedSize()
                    .help("The command you ran exited; these \(job.pidCount) processes it started are still running")
            }
            if !job.members.isEmpty && !open && width == .wide {
                Text("\(job.members.count + 1) procs").font(.caption2).foregroundStyle(.tertiary).fixedSize()
            }
            Spacer(minLength: 6)
            if width > .narrow || !store.webPages(job.listen).isEmpty {
                PortChips(listen: job.listen, max: width == .wide ? 2 : 1).fixedSize()
            }
            StateCell(stat: job.stat, etime: job.etimeSec, stop: store.stopping[job.pid], busy: store.busy.contains(job.pid))
                .frame(width: Cols.up, alignment: .trailing)
            if width > .narrow {
                Text(Fmt.mem(job.rssKb))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(job.rssKb > 1024 * 1024 ? Color.orange : Color.secondary)
                    .frame(width: Cols.mem, alignment: .trailing)
                    .help(Fmt.memLong(job.rssKb) + (job.pidCount > 1 ? " across \(job.pidCount) processes" : ""))
            }
        }
        .opacity(job.kind == .app ? 0.75 : 1)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Program name (bold) and the rest of the command line.
    func split(_ j: Job) -> (String, String) {
        let words = j.command == j.argvCommand ? j.displayArgv : j.command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return (j.command, "") }
        var prog = first
        if prog.contains("/") && !prog.hasPrefix(".") { prog = Fmt.basename(prog) }
        let rest = words.dropFirst().map { $0.hasPrefix("/") && $0.count > 30 ? "…/" + Fmt.basename($0) : Fmt.tildify($0) }.joined(separator: " ")
        return (prog, rest)
    }
}

struct MemberRowView: View {
    @Environment(Store.self) private var store
    @Environment(\.rowWidth) private var width
    var job: Job
    var member: Member
    var depth: Int

    var body: some View {
        let words = member.displayArgv
        let prog = Fmt.basename(words.first ?? member.argvCommand)
        let args = words.dropFirst().map { $0.hasPrefix("/") && $0.count > 30 ? "…/" + Fmt.basename($0) : Fmt.tildify($0) }.joined(separator: " ")
        let rel: String = {
            guard !member.cwd.isEmpty, member.cwd != job.cwd else { return "" }
            if member.cwd.hasPrefix(job.cwd + "/") { return String(member.cwd.dropFirst(job.cwd.count + 1)) }
            return Fmt.tildify(member.cwd)
        }()
        HStack(spacing: 6) {
            Color.clear.frame(width: (width == .narrow ? 20 : 36) + CGFloat(depth) * (width == .narrow ? 8 : 14))
            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.quaternary)
            Text(prog).foregroundStyle(.primary.opacity(0.85)).lineLimit(1).layoutPriority(2).frame(minWidth: 30, alignment: .leading)
            if width > .narrow { Text(args).font(.callout).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            if !rel.isEmpty && width == .wide {
                Text("@\(rel)").font(.caption).foregroundStyle(.blue.opacity(0.8)).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            PortChips(listen: member.listen, max: width == .wide ? 2 : 1, compact: true).fixedSize()
            StateCell(stat: member.stat, etime: member.etimeSec, stop: store.stopping[member.pid], busy: false)
                .frame(width: Cols.up, alignment: .trailing)
            if width > .narrow {
                Text(Fmt.mem(member.rssKb))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(member.rssKb > 1024 * 1024 ? Color.orange : Color.secondary.opacity(0.8))
                    .frame(width: Cols.mem, alignment: .trailing)
            }
        }
        .font(.callout)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

/// Uptime, or a state that needs attention: stopping…, stuck, paused, zombie, D-wait.
struct StateCell: View {
    var stat: String
    var etime: Int
    var stop: (at: Date, force: Bool)?
    var busy: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Group {
                if busy {
                    HStack(spacing: 3) { ProgressView().controlSize(.mini); Text("…") }.foregroundStyle(.orange)
                } else if let s = stop {
                    let stuck = ctx.date.timeIntervalSince(s.at) > Store.stuckAfter
                    Text(stuck ? "stuck" : "stop…").foregroundStyle(stuck ? .red : .orange)
                        .help(stuck ? "Still running — stop again to force-kill (kill -9)" : "Stopping…")
                } else if let st = stateLabel(stat) {
                    Text(st).foregroundStyle(.red).help(stateHelp(st))
                } else {
                    Text(Fmt.uptime(etime)).foregroundStyle(.secondary).help("Running for \(Fmt.uptimeLong(etime))")
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    func stateHelp(_ s: String) -> String {
        switch s {
        case "paused": return "Paused (Ctrl-Z). Stopping it also continues it, so it can exit."
        case "zombie": return "Already dead, waiting for its parent to collect it."
        default: return "Stuck in the kernel (disk, network mount or driver)."
        }
    }
}
