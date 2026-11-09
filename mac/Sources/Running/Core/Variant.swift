import AppKit
import Carbon.HIToolbox

/// Which Running this is. The official app comes from GitHub releases and updates itself;
/// the dev app is built from a checkout (`bun run install-app`), has an amber icon and its own
/// bundle id, so both can run side by side — one instance of each.
enum Variant: String {
    case official, dev

    static let current: Variant = (Bundle.main.object(forInfoDictionaryKey: "RunningVariant") as? String) == "official" ? .official : .dev

    var isDev: Bool { self == .dev }
    var appName: String { isDev ? "Running Dev" : "Running" }

    /// "0.8.0", or "0.8.0-dev · a1b2c3d" for a dev build.
    static var versionLabel: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "RunningCommit") as? String, !commit.isEmpty else { return v }
        return "\(v) · \(commit)"
    }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    /// The dev app adds ⌘ to the global shortcuts, so it never fights the official one for them.
    var hotKeyModifiers: UInt32 { UInt32(controlKey | optionKey) | (isDev ? UInt32(cmdKey) : 0) }
    var panelShortcut: String { isDev ? "⌃⌥⌘R" : "⌃⌥R" }
    var windowShortcut: String { isDev ? "⇧⌃⌥⌘R" : "⇧⌃⌥R" }

    /// The menu bar glyph's colour: the menu bar's own (template) for the official app, amber for dev.
    var glyphTint: NSColor? { isDev ? NSColor(red: 0.98, green: 0.62, blue: 0.12, alpha: 1) : nil }
}

/// One instance per variant: a newly launched copy (a fresh build, an update) quits the one
/// that's already running — politely, then by force.
@MainActor
enum SingleInstance {
    static func takeOver() {
        guard let id = Bundle.main.bundleIdentifier else { return } // an unbundled dev binary
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(4)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for app in others where !app.isTerminated { app.forceTerminate() }
    }
}
