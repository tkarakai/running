import Foundation

/// Talks to `running-core` (src/serve.ts) over stdin/stdout, one JSON object per line.
/// Restarts it if it dies; requests in flight fail with a readable error.
final class CoreClient: @unchecked Sendable {
    enum CoreError: LocalizedError {
        case core(String)
        case stopped
        var errorDescription: String? {
            switch self {
            case .core(let m): return m
            case .stopped: return "the Running engine stopped — restarting it"
            }
        }
    }

    /// Something changed on the core's side (a port probe finished): worth a refresh.
    var onChanged: (@Sendable () -> Void)?
    /// Progress text for a request (restart: "stopping…").
    var onStatus: (@Sendable (_ id: Int, _ text: String) -> Void)?
    /// The core failed to start or keeps dying.
    var onFatal: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]
    private var environment: [String: String] = [:]
    private var restarts: [Date] = []
    private var stopping = false

    func start(environment env: [String: String]) {
        lock.lock()
        environment = env
        lock.unlock()
        launch()
    }

    func stop() {
        lock.lock()
        stopping = true
        let p = process
        lock.unlock()
        p?.terminate()
    }

    /// The core to run: inside the app bundle, or (development) `bun src/serve.ts`.
    static func command() -> (URL, [String])? {
        if let exe = Bundle.main.url(forAuxiliaryExecutable: "running-core"), FileManager.default.isExecutableFile(atPath: exe.path) {
            return (exe, [])
        }
        let env = ProcessInfo.processInfo.environment
        if let script = env["RUNNING_CORE_SCRIPT"] {
            let bun = env["RUNNING_BUN"] ?? LoginEnvironment.which("bun") ?? "/opt/homebrew/bin/bun"
            return (URL(fileURLWithPath: bun), [script])
        }
        return nil
    }

    private func launch() {
        guard let (exe, args) = Self.command() else {
            onFatal?("running-core is missing from the app bundle")
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        lock.lock()
        p.environment = environment
        lock.unlock()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.receive(data)
        }
        p.terminationHandler = { [weak self] proc in self?.terminated(proc) }
        do {
            try p.run()
        } catch {
            onFatal?("couldn't start the Running engine: \(error.localizedDescription)")
            return
        }
        lock.lock()
        process = p
        stdin = inPipe.fileHandleForWriting
        buffer = Data()
        lock.unlock()
    }

    private func terminated(_ p: Process) {
        lock.lock()
        let waiting = pending
        pending = [:]
        process = nil
        stdin = nil
        let quitting = stopping
        restarts = restarts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        let tooMany = restarts.count > 5
        lock.unlock()
        for (_, done) in waiting { done(.failure(CoreError.stopped)) }
        if quitting { return }
        if tooMany {
            onFatal?("the Running engine keeps stopping (exit \(p.terminationStatus))")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.launch() }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(Data(line)) }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            if event == "changed" { onChanged?() }
            if event == "status", let id = obj["id"] as? Int, let text = obj["text"] as? String { onStatus?(id, text) }
            return
        }
        guard let id = obj["id"] as? Int else { return }
        lock.lock()
        let done = pending.removeValue(forKey: id)
        lock.unlock()
        if let err = obj["error"] as? String {
            done?(.failure(CoreError.core(err)))
        } else {
            let result = obj["result"] ?? NSNull()
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            done?(.success(data))
        }
    }

    /// Drop nil optionals (JSONSerialization can't encode them), unwrap the rest.
    static func clean(_ v: Any) -> Any? {
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional {
            guard let inner = m.children.first?.value else { return nil }
            return clean(inner)
        }
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in d { if let c = clean(x) { out[k] = c } }
            return out
        }
        if let a = v as? [Any] { return a.compactMap { clean($0) } }
        return v
    }

    /// Send a request; `id` is reported before sending so status events can be matched.
    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as: T.Type = T.self, onId: ((Int) -> Void)? = nil) async throws -> T {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            guard let stdin else {
                lock.unlock()
                cont.resume(throwing: CoreError.stopped)
                return
            }
            let id = nextId
            nextId += 1
            pending[id] = { cont.resume(with: $0) }
            lock.unlock()
            onId?(id)
            let req: [String: Any] = ["id": id, "method": method, "params": Self.clean(params)]
            guard var line = try? JSONSerialization.data(withJSONObject: req) else {
                lock.lock(); pending.removeValue(forKey: id); lock.unlock()
                cont.resume(throwing: CoreError.core("couldn't encode the request"))
                return
            }
            line.append(0x0A)
            do { try stdin.write(contentsOf: line) } catch {
                lock.lock(); let done = pending.removeValue(forKey: id); lock.unlock()
                done?(.failure(CoreError.stopped))
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
