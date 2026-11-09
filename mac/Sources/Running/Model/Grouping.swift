import Foundation

// How the process list is organized — a port of the TUI's (src/ui/App.tsx): sections by where
// jobs run (terminal app, tmux pane, detached), then by the directory each job was started in,
// then jobs, each optionally expanded into its processes. Sorting applies at every level.

enum ItemID: Hashable {
    case job(Int)
    case member(job: Int, pid: Int)
    case kept(Int)

    var jobPid: Int? {
        switch self {
        case .job(let p): return p
        case .member(let j, _): return j
        case .kept: return nil
        }
    }
}

struct ListLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case job(depth: Int)
        case member(Member, depth: Int)
    }
    var job: Job
    var kind: Kind
    var id: ItemID {
        switch kind {
        case .job: return .job(job.pid)
        case .member(let m, _): return .member(job: job.pid, pid: m.pid)
        }
    }
}

struct DirGroup: Identifiable, Hashable {
    var dir: String
    var branch: String?
    var count: Int
    var lines: [ListLine]
    var id: String { dir }
}

struct WhereSection: Identifiable, Hashable {
    var key: String // r.where
    var label: String
    var tag: String?
    var count: Int
    var muted: Bool
    var dirs: [DirGroup]
    var id: String { key }
}

enum SortKey: String, CaseIterable, Identifiable {
    case started, memory, cpu, name
    var id: String { rawValue }
    var label: String { self == .cpu ? "CPU" : rawValue.capitalized }
    var naturalDesc: Bool { self != .name }
    /// [ascending, descending], as the TUI words them.
    var dirLabel: (String, String) {
        switch self {
        case .started: return ("Newest first", "Oldest first")
        case .memory: return ("Smallest first", "Largest first")
        case .cpu: return ("Idlest first", "Busiest first")
        case .name: return ("A → Z", "Z → A")
        }
    }
    var symbol: String {
        switch self {
        case .started: return "clock"
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .name: return "textformat"
        }
    }
    var group: String { self == .memory || self == .cpu ? "sum" : "label" }
}

enum Grouping {
    private static let kindRank: [Job.Kind: Int] = [.term: 0, .server: 1, .daemon: 2, .app: 3]

    static func displayName(_ j: Job) -> String { j.agent?.title ?? j.command }

    static func sectionLabel(_ w: String) -> String { w == "detached" ? "Detached" : w }

    static func matches(_ j: Job, query q: String, keptName: String?) -> Bool {
        if q.isEmpty { return true }
        let hay = "\(j.command) \(j.cwd) \(j.where) \(j.listen.map { String($0.port) }.joined(separator: " ")) \(keptName ?? "") \(j.agent?.title ?? "")".lowercased()
        return hay.contains(q) || j.members.contains { memberMatches($0, q) }
    }

    static func memberMatches(_ m: Member, _ q: String) -> Bool {
        "\(m.argvCommand) \(m.cwd) \(m.listen.map { String($0.port) }.joined(separator: " "))".lowercased().contains(q)
    }

    enum Val: Comparable {
        case n(Double), s(String)
        static func < (a: Val, b: Val) -> Bool {
            switch (a, b) {
            case (.n(let x), .n(let y)): return x < y
            case (.s(let x), .s(let y)): return x.localizedStandardCompare(y) == .orderedAscending
            default: return false
            }
        }
    }

    static func build(rows: [Job], kept: [KeptEntry], branches: [String: String?], showAll: Bool, query: String,
                      expanded: Set<Int>, sort: SortKey, desc: Bool) -> [WhereSection] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let keptName = { (j: Job) in j.keptIndex.flatMap { i in kept.first { $0.index == i }?.name } }
        let visible = rows.filter { (showAll || $0.kind != .app) && matches($0, query: q, keptName: keptName($0)) }

        let dirSign: Double = desc ? -1 : 1
        func cmp(_ a: Val, _ b: Val) -> Int {
            let r: Int = a < b ? -1 : (b < a ? 1 : 0)
            return Int(dirSign) * r
        }
        func jobVal(_ j: Job) -> Val {
            switch sort {
            case .started: return .n(Double(j.etimeSec))
            case .memory: return .n(Double(j.rssKb))
            case .cpu: return .n(j.cpu)
            case .name: return .s(displayName(j).lowercased())
            }
        }
        func memberVal(_ m: Member) -> Val {
            switch sort {
            case .started: return .n(Double(m.etimeSec))
            case .memory: return .n(Double(m.rssKb))
            case .cpu: return .n(m.cpu)
            case .name: return .s(m.argvCommand.lowercased())
            }
        }
        func groupVal(_ js: [Job], _ label: String) -> Val {
            if sort.group == "label" { return .s(label) }
            return .n(js.reduce(0) { acc, j in if case .n(let v) = jobVal(j) { return acc + v } else { return acc } })
        }
        let byKey = { (a: Job, b: Job) -> Bool in
            let c = cmp(jobVal(a), jobVal(b))
            return c != 0 ? c < 0 : a.pid < b.pid
        }

        var sections: [String: [Job]] = [:]
        var order: [String] = []
        for j in visible {
            if sections[j.where] == nil { order.append(j.where) }
            sections[j.where, default: []].append(j)
        }
        let rank = { (js: [Job]) in js.map { kindRank[$0.kind] ?? 9 }.min() ?? 9 }
        var ordered = order.map { ($0, sections[$0]!) }
        ordered.sort { a, b in
            let ra = rank(a.1), rb = rank(b.1)
            return ra != rb ? ra < rb : a.0.localizedStandardCompare(b.0) == .orderedAscending
        }
        if sort != .started && sort != .name {
            ordered.sort { a, b in cmp(groupVal(a.1, a.0), groupVal(b.1, b.0)) < 0 }
        }

        var out: [WhereSection] = []
        for (w, js) in ordered {
            let isApp = js.allSatisfy { $0.kind == .app }
            let inSection = Set(js.map(\.pid))
            var dirsMap: [String: [Job]] = [:]
            var dirOrder: [String] = []
            for j in js where j.parentRow == nil || !inSection.contains(j.parentRow!) {
                if dirsMap[j.cwd] == nil { dirOrder.append(j.cwd) }
                dirsMap[j.cwd, default: []].append(j)
            }
            var dirList = dirOrder.map { ($0, dirsMap[$0]!) }
            dirList.sort { a, b in
                if sort == .started || sort == .name { return Fmt.tildify(a.0).localizedStandardCompare(Fmt.tildify(b.0)) == .orderedAscending }
                return cmp(groupVal(a.1, a.0), groupVal(b.1, b.0)) < 0
            }

            var groups: [DirGroup] = []
            for (dir, djs) in dirList {
                var lines: [ListLine] = []
                func place(_ j: Job, _ depth: Int) {
                    lines.append(ListLine(job: j, kind: .job(depth: depth)))
                    if !j.members.isEmpty && (expanded.contains(j.pid) || (!q.isEmpty && j.members.contains { memberMatches($0, q) })) {
                        for m in sortTree(j.members, value: memberVal, cmp: cmp) {
                            lines.append(ListLine(job: j, kind: .member(m, depth: m.depth)))
                        }
                    }
                    for c in js.filter({ $0.parentRow == j.pid }).sorted(by: byKey) { place(c, depth + 1) }
                }
                for j in djs.sorted(by: byKey) { place(j, 0) }
                let branch = (dir.isEmpty || dir == "/") ? nil : (branches[dir] ?? nil)
                groups.append(DirGroup(dir: dir, branch: branch, count: djs.count, lines: lines))
            }
            out.append(WhereSection(
                key: w, label: sectionLabel(w),
                tag: w == "detached" ? "no terminal" : (isApp ? "app" : nil),
                count: js.count, muted: isApp, dirs: groups))
        }
        return out
    }

    /// Siblings follow the sort; parents stay above their children.
    static func sortTree(_ members: [Member], value: (Member) -> Val, cmp: (Val, Val) -> Int) -> [Member] {
        let pids = Set(members.map(\.pid))
        var kids: [Int: [Member]] = [:]
        var tops: [Member] = []
        for m in members { if pids.contains(m.ppid) { kids[m.ppid, default: []].append(m) } else { tops.append(m) } }
        var out: [Member] = []
        func walk(_ list: [Member]) {
            for m in list.sorted(by: { a, b in let c = cmp(value(a), value(b)); return c != 0 ? c < 0 : a.pid < b.pid }) {
                out.append(m)
                walk(kids[m.pid] ?? [])
            }
        }
        walk(tops)
        return out
    }

    /// The flat order a keyboard walks: every selectable item, top to bottom.
    static func flatIDs(_ sections: [WhereSection]) -> [ItemID] {
        sections.flatMap { $0.dirs.flatMap { $0.lines.map(\.id) } }
    }
}
