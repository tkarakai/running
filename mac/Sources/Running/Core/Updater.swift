import AppKit
import CryptoKit
import Foundation

/// Keeps the official app up to date from GitHub releases: checks now and then, and when a
/// newer release is out, downloads its disk image, checks it (SHA-256 from GitHub, bundle id,
/// version, code signature), swaps the app bundle in place and relaunches. The dev app never
/// updates itself — it's rebuilt from the checkout.
@MainActor @Observable
final class Updater {
    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL
        var size: Int64
        var sha256: String?
        var published: Date?
    }

    enum Phase: Equatable {
        case idle
        case confirming
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case relaunching
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .installing, .relaunching: return true
            default: return false
            }
        }
    }

    private(set) var available: Release?
    private(set) var checking = false
    /// The last check that got an answer (kept across restarts).
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date {
        didSet { UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked") }
    }
    /// The newest release GitHub knows of, newer or not.
    private(set) var latest: Release?
    private(set) var lastError: String?
    /// How often to look: GitHub allows 60 unauthenticated requests an hour; this is 4 a day.
    static let interval: TimeInterval = 6 * 3600
    var phase: Phase = .idle
    /// Bytes per second while downloading, smoothed.
    private(set) var speed: Double = 0

    var enabled: Bool { Variant.current == .official || ProcessInfo.processInfo.environment["RUNNING_UPDATE_FEED"] != nil }
    var sheetShown: Bool {
        get { phase != .idle }
        set { if !newValue && !phase.isBusy { phase = .idle } }
    }

    /// Where releases are listed. RUNNING_UPDATE_FEED points somewhere else (a local file or
    /// server) to try the whole update against a fake release.
    private let feed = URL(string: ProcessInfo.processInfo.environment["RUNNING_UPDATE_FEED"] ?? "https://api.github.com/repos/tkarakai/running/releases/latest")!
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var downloader: Downloader?

    /// Checks at launch (unless the last check was within the hour), then whenever the last one
    /// is 6 hours old — looked at every 15 minutes and on wake, since a plain 6-hour timer
    /// doesn't count time asleep. Opening the window checks too if it's been an hour.
    func start() {
        guard enabled else { return }
        checkIfDue(olderThan: 3600)
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 60
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The network takes a moment to come back after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { self?.checkIfDue() } }
        }
    }

    func checkIfDue(olderThan age: TimeInterval = Updater.interval) {
        guard enabled else { return }
        if let t = lastChecked, Date().timeIntervalSince(t) < age, lastError == nil { return }
        Task { await check() }
    }

    var nextCheck: Date? { lastChecked.map { $0.addingTimeInterval(Self.interval) } }

    // ── checking ─────────────────────────────────────────────────────────
    func check() async {
        guard enabled, !checking, !phase.isBusy else { return }
        checking = true
        defer { checking = false }
        do {
            var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Running/\(Variant.version)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("GitHub answered \(http.statusCode)") }
            let release = try Self.parse(data)
            lastError = nil
            lastChecked = Date()
            latest = release
            available = Self.isNewer(release.version, than: Variant.version) ? release : nil
        } catch {
            lastError = (error as? UpdateError)?.message ?? error.localizedDescription
        }
    }

    nonisolated static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { var name: String; var size: Int64; var browser_download_url: URL; var digest: String? }
        struct GHRelease: Decodable { var tag_name: String; var body: String?; var html_url: URL; var assets: [Asset]; var draft: Bool?; var prerelease: Bool?; var published_at: String? }
        let r = try JSONDecoder().decode(GHRelease.self, from: data)
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        guard let dmg = r.assets.first(where: { $0.name.hasSuffix("-arm64.dmg") }) else { throw UpdateError("The release has no disk image") }
        let sha = dmg.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        // The body is the CHANGELOG section, then download instructions — only the first is news.
        var notes = r.body ?? ""
        if let cut = notes.range(of: "\n## Downloads") { notes = String(notes[..<cut.lowerBound]) }
        return Release(version: version, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), page: r.html_url, dmg: dmg.browser_download_url, size: dmg.size, sha256: sha,
                       published: r.published_at.flatMap { try? Date($0, strategy: .iso8601) })
    }

    /// Semver-ish: numeric parts compared in order; "1.2.3-dev" counts as 1.2.3.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [] }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // ── installing ───────────────────────────────────────────────────────
    func askToInstall() {
        guard available != nil, !phase.isBusy else { return }
        phase = .confirming
    }

    func cancel() {
        downloader?.cancel()
        downloader = nil
        phase = .idle
    }

    func install() {
        guard let r = available else { return }
        Task { await run(r) }
    }

    private func run(_ r: Release) async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("running-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let target = try installTarget()
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            // 1. Download, with progress.
            phase = .downloading(received: 0, total: r.size)
            speed = 0
            let dmg = work.appendingPathComponent("Running.dmg")
            let d = Downloader()
            downloader = d
            var lastBytes: Int64 = 0, lastTime = Date()
            try await d.download(r.dmg, to: dmg) { [weak self] got, total in
                guard let self, case .downloading = self.phase else { return }
                let now = Date(), dt = now.timeIntervalSince(lastTime)
                if dt > 0.25 {
                    let inst = Double(got - lastBytes) / dt
                    self.speed = self.speed == 0 ? inst : self.speed * 0.7 + inst * 0.3
                    lastBytes = got; lastTime = now
                }
                self.phase = .downloading(received: got, total: total > 0 ? total : r.size)
            }
            downloader = nil

            // 2. Check it's what GitHub says it is, and that it's Running.
            phase = .verifying
            if let want = r.sha256 {
                let got = try await Task.detached { try Self.sha256(of: dmg) }.value
                guard got == want.lowercased() else { throw UpdateError("The download is damaged (checksum mismatch). Try again.") }
            }
            let mount = work.appendingPathComponent("mnt")
            try await Self.sh("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path)
            mounted = mount
            let newApp = mount.appendingPathComponent("Running.app")
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else { throw UpdateError("The disk image doesn't contain Running.app") }
            guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError("The disk image contains a different app") }
            guard info["CFBundleShortVersionString"] as? String == r.version else { throw UpdateError("The disk image holds a different version than announced") }
            try await Self.sh("/usr/bin/codesign", "--verify", "--strict", newApp.path)

            // 3. Copy it next to the current app (same volume, so the swap is a rename), then swap.
            phase = .installing
            let dir = target.deletingLastPathComponent()
            let staged = dir.appendingPathComponent(".Running-\(r.version)-\(UUID().uuidString.prefix(6)).app")
            let old = dir.appendingPathComponent(".Running-old-\(UUID().uuidString.prefix(6)).app")
            try await Self.sh("/usr/bin/ditto", newApp.path, staged.path)
            _ = try? await Self.sh("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)
            await detach() // done with the disk image
            do {
                try FileManager.default.moveItem(at: target, to: old)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw UpdateError("Couldn't replace \(target.path): \(error.localizedDescription)")
            }
            do {
                try FileManager.default.moveItem(at: staged, to: target)
            } catch {
                try? FileManager.default.moveItem(at: old, to: target) // put the old one back
                try? FileManager.default.removeItem(at: staged)
                throw UpdateError("Couldn't install the new version: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: old) // our own files stay readable while we run

            // 4. Start the new one; it quits this one (SingleInstance) and says hello.
            phase = .relaunching
            // Clean up now: the new instance quits this one as it starts, before any defer runs.
            try? FileManager.default.removeItem(at: work)
            UserDefaults.standard.set(Variant.version, forKey: "updatedFrom")
            try? await Task.sleep(for: .milliseconds(600)) // let the last step be seen
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            cfg.arguments = ["--open-window"]
            // Keep RUNNING_* settings (a test feed, a config dir) across the restart.
            cfg.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("RUNNING_") }
            _ = try await NSWorkspace.shared.openApplication(at: target, configuration: cfg)
            // Should SingleInstance not reach us, go anyway.
            try? await Task.sleep(for: .seconds(8))
            NSApp.terminate(nil)
        } catch is CancellationError {
            await detach()
            phase = .idle
        } catch {
            await detach()
            downloader = nil
            UserDefaults.standard.removeObject(forKey: "updatedFrom")
            if case .idle = phase { return } // cancelled
            phase = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    @ObservationIgnored private var mounted: URL?
    private func detach() async {
        guard let m = mounted else { return }
        mounted = nil
        _ = try? await Self.sh("/usr/bin/hdiutil", "detach", "-force", m.path)
    }

    /// The bundle to replace: this app, wherever it lives — unless macOS runs it from a
    /// read-only, translocated copy (opened straight from Downloads or the disk image).
    private func installTarget() throws -> URL {
        let url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") || url.path.hasPrefix("/Volumes/") {
            throw UpdateError("Move Running to your Applications folder first, then update.")
        }
        guard url.pathExtension == "app" else { throw UpdateError("This copy of Running isn't an app bundle.") }
        guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw UpdateError("Running can't write to \(url.deletingLastPathComponent().path).")
        }
        return url
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated static func sh(_ exe: String, _ args: String...) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.terminationHandler = { p in
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 { cont.resume(returning: text) } else {
                    cont.resume(throwing: UpdateError("\(URL(fileURLWithPath: exe).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct UpdateError: Error {
    var message: String
    init(_ m: String) { message = m }
}

/// A download with progress callbacks (URLSession's async download has none).
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var cont: CheckedContinuation<Void, Error>?
    private var dest: URL!
    private var progress: (@MainActor (Int64, Int64) -> Void)?

    func download(_ url: URL, to dest: URL, progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
        self.dest = dest
        self.progress = progress
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                cont = c
                var req = URLRequest(url: url)
                req.setValue("Running/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")", forHTTPHeaderField: "User-Agent")
                task = session.downloadTask(with: req)
                task?.resume()
            }
        } onCancel: { [weak self] in self?.cancel() }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = progress
        Task { @MainActor in p?(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(UpdateError("The download failed (HTTP \(http.statusCode))"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(nil)
        } catch { finish(error) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish((error as? URLError)?.code == .cancelled ? CancellationError() : error)
    }

    private func finish(_ error: Error?) {
        guard let c = cont else { return }
        cont = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
