import AppKit
import Foundation
import ServiceManagement

/// Desktop-only preferences. (Sort order lives in ~/.config/running/settings.json, shared
/// with the TUI; kept processes in kept.yaml.)
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    /// Where "Start" and restart-fallbacks open: terminal | iterm | ghostty | tmux.
    var terminal: String { didSet { d.set(terminal, forKey: "terminal") } }
    var confirmStop: Bool { didSet { d.set(confirmStop, forKey: "confirmStop") } }
    var hotKeyEnabled: Bool { didSet { d.set(hotKeyEnabled, forKey: "hotKeyEnabled"); onHotKeyChange?() } }
    var showAppServers: Bool { didSet { d.set(showAppServers, forKey: "showAppServers") } }
    var inspectorShown: Bool { didSet { d.set(inspectorShown, forKey: "inspectorShown") } }

    @ObservationIgnored var onHotKeyChange: (() -> Void)?

    private init() {
        d.register(defaults: [
            "confirmStop": true, "hotKeyEnabled": true,
            "showAppServers": false, "inspectorShown": true,
        ])
        terminal = d.string(forKey: "terminal") ?? Preferences.guessTerminal()
        confirmStop = d.bool(forKey: "confirmStop")
        hotKeyEnabled = d.bool(forKey: "hotKeyEnabled")
        showAppServers = d.bool(forKey: "showAppServers")
        inspectorShown = d.bool(forKey: "inspectorShown")
    }

    // ── launch at login ──
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login: \(error)")
            }
        }
    }

    // ── terminals ──
    struct TerminalOption: Identifiable, Hashable {
        var id: String
        var label: String
        var installed: Bool
        var icon: NSImage?
    }

    static let terminalApps: [(id: String, label: String, bundle: String?)] = [
        ("ghostty", "Ghostty", "com.mitchellh.ghostty"),
        ("iterm", "iTerm2", "com.googlecode.iterm2"),
        ("terminal", "Terminal", "com.apple.Terminal"),
        ("tmux", "tmux — new window", nil),
    ]

    static func terminalOptions() -> [TerminalOption] {
        terminalApps.map { t in
            if let b = t.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                return TerminalOption(id: t.id, label: t.label, installed: true, icon: NSWorkspace.shared.icon(forFile: url.path))
            }
            let tmux = t.id == "tmux" && LoginEnvironment.which("tmux") != nil
            return TerminalOption(id: t.id, label: t.label, installed: t.bundle == nil ? tmux : false, icon: nil)
        }
    }

    static func label(forTerminal id: String) -> String {
        terminalApps.first { $0.id == id }?.label ?? id
    }

    /// The terminal you type into most, from the command log's `app=` field.
    static func guessTerminal() -> String {
        let log = (ProcessInfo.processInfo.environment["RUNNING_LOG_FILE"]).map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/running/commands.log")
        var counts: [String: Int] = [:]
        if let h = try? FileHandle(forReadingFrom: log) {
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
            if let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let r = line.range(of: ";app=") else { continue }
                    let rest = line[r.upperBound...]
                    let app = rest.prefix { $0 != ";" && $0 != "\t" }
                    switch app {
                    case "ghostty": counts["ghostty", default: 0] += 1
                    case "iTerm.app": counts["iterm", default: 0] += 1
                    case "Apple_Terminal": counts["terminal", default: 0] += 1
                    default: break
                    }
                }
            }
            try? h.close()
        }
        let installed = Set(terminalOptions().filter(\.installed).map(\.id))
        if let best = counts.filter({ installed.contains($0.key) }).max(by: { $0.value < $1.value })?.key { return best }
        for id in ["ghostty", "iterm"] where installed.contains(id) { return id }
        return "terminal"
    }
}
