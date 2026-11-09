import Foundation

/// The environment a new terminal would have. Apps started from Finder get launchd's bare
/// one (PATH=/usr/bin:/bin:/usr/sbin:/sbin), which wouldn't find tmux, orca, wezterm…
enum LoginEnvironment {
    /// Ask the login shell (interactive, so ~/.zshrc runs too: nvm, brew…), falling back to a
    /// plain login shell, then to launchd's environment plus the usual Homebrew paths.
    static func resolve(timeout: TimeInterval = 6) -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        for flags in [["-l", "-i"], ["-l"]] {
            if let env = run(shell: shell, flags: flags, timeout: timeout), env["PATH"] != nil {
                // The shell's view wins, but keep what launchd gave us that it doesn't set.
                for (k, v) in env where !k.hasPrefix("__CF") && k != "SHLVL" && k != "_" && k != "PWD" && k != "OLDPWD" { base[k] = v }
                return sanitize(base)
            }
        }
        let path = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        base["PATH"] = path + ":/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.bun/bin"
        return sanitize(base)
    }

    private static func sanitize(_ env: [String: String]) -> [String: String] {
        var e = env
        // We are not inside any terminal; these would only confuse the core.
        for k in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_SESSION_ID", "ORCA_TERMINAL_HANDLE", "RUNNING_ACTION_FILE"] { e[k] = nil }
        return e
    }

    private static func run(shell: String, flags: [String], timeout: TimeInterval) -> [String: String]? {
        // Written to a file, not read from a pipe: shells start helpers (gitstatusd…) that keep
        // the pipe open long after the shell itself has exited.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("running-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = flags + ["-c", "env -0 > \"$RUNNING_ENV_FILE\""]
        var env = ProcessInfo.processInfo.environment
        env["RUNNING_LOGIN_PROBE"] = "1"
        env["RUNNING_ENV_FILE"] = file.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        var out: [String: String] = [:]
        for chunk in data.split(separator: 0) {
            guard let s = String(data: Data(chunk), encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            out[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return out
    }

    static func which(_ name: String, path: String? = nil) -> String? {
        let dirs = (path ?? ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.bun/bin"]
        for d in dirs {
            let p = "\(d)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
