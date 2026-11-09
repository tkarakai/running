import AppKit

// A write to the engine's stdin after it died must not kill the app.
signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
    // Build step: render the app icon (scripts/build-app.ts).
    MainActor.assumeIsolated {
        do {
            try AppArt.renderIconset(to: URL(fileURLWithPath: args[i + 1]), dev: args.contains("--dev"))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render-icon failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
