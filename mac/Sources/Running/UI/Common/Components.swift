import AppKit
import Charts
import SwiftUI

// ── where a job runs: an icon for the section header ─────────────────────

@MainActor
enum WhereIcon {
    private static var cache: [String: NSImage?] = [:]

    static let symbols: [String: String] = [
        "detached": "moon.zzz", "macOS": "apple.logo", "ssh": "network", "tmux": "rectangle.split.3x1",
        "terminal": "terminal", "unknown": "questionmark.square.dashed",
    ]

    /// The app's real icon (Orca, Terminal, VS Code…), or nil when it isn't an app.
    static func appIcon(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var img: NSImage?
        if !name.hasPrefix("tmux"), symbols[name] == nil {
            let fm = FileManager.default
            let candidates = ["/Applications/\(name).app", "/System/Applications/Utilities/\(name).app", "/System/Applications/\(name).app", "\(NSHomeDirectory())/Applications/\(name).app"]
            if let path = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                img = NSWorkspace.shared.icon(forFile: path)
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                img = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        cache[name] = img
        return img
    }

    static func symbol(_ name: String) -> String {
        if name.hasPrefix("tmux") { return "rectangle.split.3x1" }
        return symbols[name] ?? "macwindow"
    }
}

struct WhereIconView: View {
    var name: String
    var size: CGFloat = 16
    var body: some View {
        if let img = WhereIcon.appIcon(name) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: WhereIcon.symbol(name))
                .font(.system(size: size * 0.72, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

// ── ports ─────────────────────────────────────────────────────────────────

/// `↗3000 :5432` — web pages first, clickable; the rest plain.
struct PortChips: View {
    @Environment(Store.self) private var store
    var listen: [Listen]
    var max: Int = 3
    var compact = false

    var body: some View {
        let sorted = listen.sorted { a, b in
            let wa = store.isWeb(a), wb = store.isWeb(b)
            return wa != wb ? wa : a.port < b.port
        }
        HStack(spacing: 4) {
            ForEach(sorted.prefix(max), id: \.self) { l in PortChip(listen: l, compact: compact) }
            if sorted.count > max {
                Text("+\(sorted.count - max)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(sorted.dropFirst(max).map { ":\($0.port)" }.joined(separator: " "))
            }
        }
    }
}

struct PortChip: View {
    @Environment(Store.self) private var store
    @Environment(\.backgroundProminence) private var prominence
    var listen: Listen
    var compact = false
    @State private var hover = false

    var body: some View {
        let probe = store.probe(listen)
        let web = probe?.web == true
        let label = Text(web ? "\(Image(systemName: "arrow.up.right")) \(String(listen.port))" : ":\(String(listen.port))")
            .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(web ? .semibold : .regular))
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(Capsule().fill(prominence == .increased ? Color.white.opacity(web ? 0.25 : 0.12) : web ? Color.accentColor.opacity(hover ? 0.28 : 0.16) : Color.secondary.opacity(0.12)))
            .foregroundStyle(prominence == .increased ? Color.white : web ? Color.accentColor : Color.secondary)
        if web, let url = probe?.url {
            Button { store.open(url: url) } label: { label }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .help("Open \(url)\(probe?.title.map { " — \($0)" } ?? "")")
                .pointerStyle(.link)
        } else {
            label.help(probe?.pending == true ? "Checking port \(listen.port)…" : "Port \(listen.port) on \(listen.host) — not a web page")
        }
    }
}

// ── toast ────────────────────────────────────────────────────────────────

struct ToastView: View {
    var toast: Toast
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.body.weight(.semibold))
            Text(toast.text).lineLimit(2).font(.callout).textSelection(.enabled)
            if let undo = toast.undo {
                Button("Undo") { undo(); dismiss() }.buttonStyle(.borderless).keyboardShortcut("z", modifiers: .command)
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 560)
    }

    var icon: String {
        switch toast.tone {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .err: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch toast.tone {
        case .ok: return .green
        case .warn: return .orange
        case .err: return .red
        case .info: return .accentColor
        }
    }
}

struct ToastOverlay: ViewModifier {
    @Environment(Store.self) private var store
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = store.toast {
                ToastView(toast: t) { withAnimation { store.toast = nil } }
                    .padding(.bottom, 14)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
            }
        }
    }
}

extension View {
    func toasts() -> some View { modifier(ToastOverlay()) }
}

// ── sparkline ────────────────────────────────────────────────────────────

struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("v", v))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", i), y: .value("v", v))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(Swift.max(values.max() ?? 1, 0.0001) * 1.15))
        .chartXScale(domain: 0...Swift.max(values.count - 1, 1))
    }
}

// ── small bits ───────────────────────────────────────────────────────────

/// A keycap: `⌘K`.
struct Kbd: View {
    var keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
            .fixedSize()
    }
}

struct StatusDot: View {
    var color: Color
    var pulse = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 3).scaleEffect(on ? 2.2 : 1).opacity(on ? 0 : 0.8).opacity(pulse ? 1 : 0))
            .onAppear { if pulse { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } } }
    }
}

/// The badge for an AI agent's status.
struct AgentBadge: View {
    @Environment(\.backgroundProminence) private var prominence
    var agent: AgentInfo
    var body: some View {
        HStack(spacing: 4) {
            switch agent.status {
            case "working":
                ProgressView().controlSize(.mini).scaleEffect(0.8)
                Text("working")
            case "new":
                Text("new")
            default:
                if let t = agent.lastActive { Text("idle \(Fmt.uptime(max(0, Int(Date().timeIntervalSince1970 - t))))") } else { Text("idle") }
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(prominence == .increased ? Color.white.opacity(0.2) : color.opacity(0.15)))
        .foregroundStyle(prominence == .increased ? Color.white : color)
    }
    var color: Color { agent.status == "working" ? .orange : agent.status == "new" ? .teal : .purple }
}

struct HarnessIcon: View {
    var harness: String
    var body: some View {
        Image(systemName: "sparkles").foregroundStyle(.purple).help("\(harness) agent")
    }
}

/// Human labels for how a job was started.
func kindSymbol(_ j: Job) -> String {
    if j.agent != nil { return "sparkles" }
    switch j.kind {
    case .term: return j.leaderGone ? "arrow.turn.down.right" : "terminal"
    case .server: return "server.rack"
    case .daemon: return "moon.stars"
    case .app: return "app.dashed"
    }
}
