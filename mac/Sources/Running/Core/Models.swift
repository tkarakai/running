import Foundation

// Wire types: exactly what src/serve.ts sends. Optional wherever the core may omit a field.

struct Listen: Codable, Hashable {
    var pid: Int
    var port: Int
    var host: String
}

struct AgentInfo: Codable, Hashable {
    var harness: String
    var sessionId: String?
    var title: String?
    var model: String?
    var tokens: Double?
    var costUsd: Double?
    var lastActive: Double?
    var status: String? // working | idle | new
    var branch: String?
    var transcript: String?
    var resume: String?
}

struct Member: Codable, Hashable, Identifiable {
    var pid: Int
    var ppid: Int
    var depth: Int
    var displayArgv: [String]
    var argvCommand: String
    var cwd: String
    var listen: [Listen]
    var tty: String
    var stat: String
    var etimeSec: Int
    var rssKb: Int
    var cpu: Double
    var pidCount: Int
    var id: Int { pid }
}

struct Job: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case term, server, daemon, app }
    enum Source: String, Codable { case typed, script, history, argv }

    var pid: Int
    var pgid: Int
    var kind: Kind
    var command: String
    var argvCommand: String
    var displayArgv: [String]
    var source: Source
    var leaderGone: Bool
    var exe: String
    var cwd: String
    var listen: [Listen]
    var `where`: String
    var tty: String
    var stat: String
    var etimeSec: Int
    var rssKb: Int
    var cpu: Double
    var pidCount: Int
    var members: [Member]
    var parentRow: Int?
    var via: String?
    var termLabel: String
    var shellAlive: Bool
    var keptIndex: Int?
    var agent: AgentInfo?
    var id: Int { pid }
}

struct KeptEntry: Codable, Hashable, Identifiable {
    var index: Int
    var name: String
    var command: String
    var cwd: String
    var env: [String: String]
    var note: String
    var ports: [Int]
    var session: String?
    var kept: String
    var line: String
    var livePid: Int?
    var id: String { "\(index)|\(name)|\(command)|\(cwd)" }
}

struct ProbeInfo: Codable, Hashable {
    var pid: Int
    var port: Int
    var pending: Bool
    var web: Bool?
    var url: String?
    var title: String?
    var status: Int?
}

struct SortSpec: Codable, Hashable {
    var key: String
    var desc: Bool
}

struct Snapshot: Codable {
    var at: Double
    var rows: [Job]
    var kept: [KeptEntry]
    var probes: [ProbeInfo]
    var branches: [String: String?]
    var sort: SortSpec
}

struct Hello: Codable {
    struct Shell: Codable { var zshrc: Bool; var logExists: Bool; var logAgeSec: Double? }
    struct Terminal: Codable { var label: String; var app: String? }
    struct Sort: Codable { var label: String; var desc: Bool; var dirLabel: [String] }
    var version: String
    var bun: String
    var pid: Int
    var keptFile: String
    var logFile: String
    var shell: Shell
    var terminals: [String: Terminal]
    var sorts: [String: Sort]
}

struct Outcome: Codable {
    var ok: Bool
    var message: String
}

struct KillResult: Codable { var sent: Int; var signal: String }
struct WhyAlive: Codable { var pid: Int; var alive: Bool; var reason: String }

struct PeekData: Codable, Equatable {
    var title: String
    var lines: [String]
    var sources: [String]
    var source: String?
    var kind: String
}

struct RestartPlan: Codable {
    var line: String
    var cwd: String
    var `where`: String
    var whereLabel: String
    var exact: Bool
    var why: String
}

struct PlanResult: Codable {
    var ok: Bool
    var plan: RestartPlan?
    var reason: String?
}

struct EnvChoice: Codable, Hashable, Identifiable {
    var key: String
    var value: String
    var secret: Bool
    var selected: Bool
    var id: String { key }
}

struct KeepDraft: Codable {
    struct Already: Codable { var index: Int; var name: String }
    var alreadyKept: Already?
    var title: String
    var name: String
    var command: String
    var cwd: String
    var note: String
    var env: [EnvChoice]
}

struct KeepResult: Codable { var ok: Bool; var message: String; var index: Int? }

struct ForgetResult: Codable {
    struct Raw: Codable {
        var name: String; var command: String; var cwd: String
        var env: [String: String]?; var note: String?; var ports: [Int]?; var session: String?; var kept: String
    }
    var ok: Bool
    var message: String
    var restore: Raw
}

struct CopyLine: Codable { var line: String }
