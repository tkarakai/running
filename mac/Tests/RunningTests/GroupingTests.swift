import Testing
@testable import Running

private func job(_ pid: Int, where w: String = "Orca", cwd: String = "/p", kind: Job.Kind = .term, etime: Int = 10, rss: Int = 100, cmd: String = "bun dev", members: [Member] = [], parent: Int? = nil) -> Job {
    Job(pid: pid, pgid: pid, kind: kind, command: cmd, argvCommand: cmd, displayArgv: cmd.split(separator: " ").map(String.init), source: .typed,
        leaderGone: false, exe: "/x", cwd: cwd, listen: [], where: w, tty: "ttys001", stat: "S", etimeSec: etime, rssKb: rss, cpu: 0,
        pidCount: 1 + members.count, members: members, parentRow: parent, via: nil, termLabel: "", shellAlive: true, keptIndex: nil, agent: nil)
}

private func member(_ pid: Int, ppid: Int, depth: Int = 0, rss: Int = 1) -> Member {
    Member(pid: pid, ppid: ppid, depth: depth, displayArgv: ["node"], argvCommand: "node \(pid)", cwd: "/p", listen: [], tty: "??", stat: "S", etimeSec: 5, rssKb: rss, cpu: 0, pidCount: 1)
}

@Test func formatsLikeTheTUI() {
    #expect(Fmt.uptime(59) == "59s")
    #expect(Fmt.uptime(3600 + 5 * 60) == "1h05")
    #expect(Fmt.uptime(2 * 86400 + 3 * 3600) == "2d3h")
    #expect(Fmt.mem(1024 * 512) == "512M")
    #expect(Fmt.mem(1024 * 1024 * 3) == "3.0G")
}

@Test func sectionsGroupByWhereThenDirectory() {
    let rows = [job(1, where: "Orca", cwd: "/a"), job(2, where: "detached", cwd: "/b", kind: .daemon), job(3, where: "Orca", cwd: "/a"), job(4, where: "Orca", cwd: "/c")]
    let s = Grouping.build(rows: rows, kept: [], branches: [:], showAll: false, query: "", expanded: [], sort: .started, desc: true)
    #expect(s.map(\.label) == ["Orca", "Detached"])
    #expect(s[0].dirs.map(\.dir) == ["/a", "/c"])
    #expect(s[0].dirs[0].lines.count == 2)
    #expect(s[1].tag == "no terminal")
}

@Test func appServersHiddenUnlessShowAll() {
    let rows = [job(1), job(2, where: "Docker", kind: .app)]
    #expect(Grouping.build(rows: rows, kept: [], branches: [:], showAll: false, query: "", expanded: [], sort: .started, desc: true).count == 1)
    #expect(Grouping.build(rows: rows, kept: [], branches: [:], showAll: true, query: "", expanded: [], sort: .started, desc: true).count == 2)
}

@Test func sortsJobsByMemory() {
    let rows = [job(1, rss: 10), job(2, rss: 300), job(3, rss: 20)]
    let s = Grouping.build(rows: rows, kept: [], branches: [:], showAll: false, query: "", expanded: [], sort: .memory, desc: true)
    #expect(s[0].dirs[0].lines.map(\.job.pid) == [2, 3, 1])
}

@Test func expandedJobsListTheirProcessesAsATree() {
    let ms = [member(11, ppid: 1), member(12, ppid: 11, depth: 1), member(13, ppid: 1)]
    let rows = [job(1, members: ms)]
    let closed = Grouping.build(rows: rows, kept: [], branches: [:], showAll: false, query: "", expanded: [], sort: .started, desc: true)
    #expect(closed[0].dirs[0].lines.count == 1)
    let open = Grouping.build(rows: rows, kept: [], branches: [:], showAll: false, query: "", expanded: [1], sort: .started, desc: true)
    let ids = open[0].dirs[0].lines.map(\.id)
    #expect(ids == [.job(1), .member(job: 1, pid: 11), .member(job: 1, pid: 12), .member(job: 1, pid: 13)])
}

@Test func filterMatchesCommandPortAndMembers() {
    let rows = [job(1, cmd: "vite"), job(2, cmd: "postgres", members: [member(21, ppid: 2)])]
    let s = Grouping.build(rows: rows, kept: [], branches: [:], showAll: false, query: "node 21", expanded: [], sort: .started, desc: true)
    // A member hit shows its job, expanded.
    #expect(s[0].dirs[0].lines.map(\.id) == [.job(2), .member(job: 2, pid: 21)])
}

@Test func nestedJobsSitUnderTheirParent() {
    let rows = [job(1, cmd: "claude"), job(2, cmd: "vite", parent: 1)]
    let s = Grouping.build(rows: rows, kept: [], branches: [:], showAll: false, query: "", expanded: [], sort: .started, desc: true)
    let lines = s[0].dirs[0].lines
    #expect(lines.map(\.job.pid) == [1, 2])
    if case .job(let d) = lines[1].kind { #expect(d == 1) } else { Issue.record("expected a job line") }
}
