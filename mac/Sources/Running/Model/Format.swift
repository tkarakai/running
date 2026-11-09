import Foundation

// Same formats as the TUI (src/ui/theme.ts), so numbers read the same in both.
enum Fmt {
    static func uptime(_ sec: Int) -> String {
        if sec < 60 { return "\(sec)s" }
        let m = sec / 60, h = m / 60, d = h / 24
        if h < 1 { return "\(m)m" }
        if d < 1 { return "\(h)h" + String(format: "%02d", m % 60) }
        return "\(d)d\(h % 24)h"
    }

    /// Spelled out, for tooltips and the inspector: "2 days 3 hours".
    static func uptimeLong(_ sec: Int) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        f.allowedUnits = sec < 60 ? [.second] : [.day, .hour, .minute]
        return f.string(from: TimeInterval(sec)) ?? uptime(sec)
    }

    static func mem(_ kb: Int) -> String {
        let mb = Double(kb) / 1024
        if mb < 1000 { return "\(Int(mb.rounded()))M" }
        return String(format: "%.1fG", mb / 1024)
    }

    static func memLong(_ kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)
    }

    static func cpu(_ v: Double) -> String { String(format: v >= 10 ? "%.0f%%" : "%.1f%%", v) }

    static func tokens(_ n: Double?) -> String {
        guard let n else { return "" }
        if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return "\(Int((n / 1e3).rounded()))k" }
        return "\(Int(n))"
    }

    static let home = NSHomeDirectory()

    static func tildify(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    static func untildify(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    static func ago(epoch: Double) -> String {
        uptime(max(0, Int(Date().timeIntervalSince1970 - epoch))) + " ago"
    }

    static func ago(iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        return ago(epoch: d.timeIntervalSince1970)
    }

    static func date(iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func basename(_ p: String) -> String { (p as NSString).lastPathComponent }
}

/// Unusual process states worth a glance (ps STAT): zombie, paused (Ctrl-Z), stuck in the kernel.
func stateLabel(_ stat: String) -> String? {
    if stat.hasPrefix("Z") { return "zombie" }
    if stat.hasPrefix("T") { return "paused" }
    if stat.hasPrefix("U") { return "D-wait" }
    return nil
}
