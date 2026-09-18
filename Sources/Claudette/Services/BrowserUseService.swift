import Foundation
import Combine

/// Where a browser task has got to.
enum BrowserRunState: Equatable {
    case idle, running, finished, failed, cancelled

    var isBusy: Bool { self == .running }
}

/// Whether the machine can actually run the browser-use sidecar.
///
/// Deliberately a top-level type rather than nested inside `BrowserTaskRunner`:
/// the probe that produces it runs off the main actor, and a type nested in a
/// `@MainActor` class inherits that isolation.
enum BrowserAgentEnvironment: Equatable {
    /// Not probed yet.
    case unknown
    /// browser-use is importable from `interpreter`.
    case ready(interpreter: String, version: String)
    /// A usable Python 3.11+ exists, but browser-use isn't installed in it.
    case missingPackage(interpreter: String)
    /// No Python 3.11+ on the machine at all.
    case missingPython(detail: String)

    var isReady: Bool { if case .ready = self { return true }; return false }

    /// Human-readable next step for whatever the probe found.
    var advice: String {
        switch self {
        case .unknown:
            return "Claudette hasn't checked for browser-use yet."
        case .ready:
            return ""
        case .missingPackage(let interpreter):
            let which = interpreter.isEmpty ? "your Python" : interpreter
            return "browser-use isn't installed in \(which). Install it below and Claudette will use it."
        case .missingPython(let detail):
            return "Claudette needs Python 3.11 or newer to run browser-use. \(detail)"
        }
    }
}

/// What one interpreter turned out to be.
private struct PythonProbe: Sendable {
    var major = 0
    var minor = 0
    var browserUseVersion = ""

    var exists: Bool { major > 0 }
    var hasBrowserUse: Bool { !browserUseVersion.isEmpty }
    /// browser-use declares `requires-python >=3.11`.
    var versionIsSupported: Bool { major > 3 || (major == 3 && minor >= 11) }
}

/// Everything site-specific about a run, handed to the sidecar as JSON on stdin.
///
/// Built from the user's recipe plus whatever they typed. Claudette contributes
/// no rules of its own here — if a field is empty, it's because the user left it
/// empty.
struct BrowserTaskSpec: Codable, Sendable {
    var goal: String
    var instructions: String = ""
    var startURL: String = ""
    var allowedDomains: [String] = []
    var maxFindings: Int = 8
    var readOnly: Bool = true
    var persona: String = ""
    var tone: String = ""
    var drafts: [Slot] = []

    struct Slot: Codable, Sendable {
        var label: String
        var limit: Int?
        var guidance: String = ""
    }

    enum CodingKeys: String, CodingKey {
        case goal, instructions, drafts, persona, tone
        case startURL = "start_url"
        case allowedDomains = "allowed_domains"
        case maxFindings = "max_findings"
        case readOnly = "read_only"
    }
}

/// Runtime knobs — which model, which browser, how long. Snapshotted off the
/// config so the launch can happen after an `await` without reaching back into
/// UI state.
private struct LaunchPlan: Sendable {
    var sidecar: String
    var provider: String
    var model: String
    var maxSteps: Int
    var headless: Bool
    var profileDir: String
    var chromePath: String
    var apiKeyEnvVar: String?
    var apiKey: String
    var spec: BrowserTaskSpec

    var arguments: [String] {
        var args = [
            sidecar,
            "--provider", provider,
            "--model", model,
            "--max-steps", String(maxSteps)
        ]
        if headless { args.append("--headless") }
        if !profileDir.isEmpty { args += ["--user-data-dir", profileDir] }
        if !chromePath.isEmpty { args += ["--chrome-path", chromePath] }
        return args
    }
}

/// Drives the bundled `browser-use` sidecar: spawns it, feeds it a task spec,
/// parses its JSONL event stream, and publishes progress for the panel to render.
@MainActor
final class BrowserTaskRunner: ObservableObject {
    @Published private(set) var state: BrowserRunState = .idle
    /// Live trace of what the agent is looking at, oldest first.
    @Published private(set) var steps: [BrowserStep] = []
    @Published private(set) var report: TaskReport?
    /// One-line "what's happening now" for the panel header.
    @Published private(set) var statusLine: String = ""
    @Published private(set) var lastError: String?
    /// Raw stderr plus any stdout line that wasn't one of our events, shown behind
    /// a disclosure triangle. Capped so a chatty run can't grow unbounded.
    @Published private(set) var log: String = ""
    @Published private(set) var environment: BrowserAgentEnvironment = .unknown
    @Published private(set) var installLog: String = ""
    @Published private(set) var isInstalling: Bool = false
    /// Goal text of the run in flight, or the last one.
    @Published private(set) var goal: String = ""
    /// Draft labels and their character caps, carried from the recipe that
    /// started the run so the cards can count against them.
    @Published private(set) var draftLimits: [String: Int] = [:]

    private var process: Process?
    private var stdoutBuffer = Data()
    /// Set when the user hits Stop, so the termination handler reports a
    /// cancellation rather than a crash.
    private var userCancelled = false

    private static let logLimit = 24_000

    // MARK: - Running

    func run(spec: BrowserTaskSpec, config: BrowserAgentConfig) {
        let trimmedGoal = spec.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty, !state.isBusy else { return }

        guard let sidecar = Self.sidecarURL() else {
            state = .failed
            lastError = "Couldn't find the browser-agent sidecar inside the app bundle. Rebuild Claudette with ./build.sh."
            return
        }
        if config.provider.needsKey && config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            state = .failed
            lastError = "Add a \(config.provider.label) API key in Settings → Browser agent, or switch to Ollama to run locally without one."
            return
        }

        var resolvedSpec = spec
        resolvedSpec.goal = trimmedGoal
        resolvedSpec.persona = config.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedSpec.tone = config.tone.trimmingCharacters(in: .whitespacesAndNewlines)

        goal = trimmedGoal
        draftLimits = Dictionary(
            resolvedSpec.drafts.compactMap { slot in slot.limit.map { (slot.label, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        steps.removeAll()
        report = nil
        lastError = nil
        log = ""
        stdoutBuffer = Data()
        userCancelled = false
        state = .running
        statusLine = "Looking for a Python with browser-use…"

        let plan = LaunchPlan(
            sidecar: sidecar.path,
            provider: config.provider.rawValue,
            model: config.effectiveModel,
            maxSteps: config.maxSteps,
            headless: config.headless,
            profileDir: config.profileDir.trimmingCharacters(in: .whitespaces),
            chromePath: config.chromePath.trimmingCharacters(in: .whitespaces),
            apiKeyEnvVar: config.provider.apiKeyEnvVar,
            apiKey: config.apiKey.trimmingCharacters(in: .whitespaces),
            spec: resolvedSpec
        )

        // Finding the interpreter shells out to every candidate on the machine, so
        // it happens off the main actor — otherwise the panel freezes for a second
        // on the way into every run.
        let preferred = config.pythonPath
        Task { [weak self] in
            let resolved = await Self.resolveEnvironment(preferred: preferred)
            guard let self else { return }
            self.environment = resolved
            guard case .ready(let interpreter, _) = resolved else {
                self.state = .failed
                self.statusLine = ""
                self.lastError = resolved.advice
                return
            }
            // The user may have hit Stop while we were probing.
            guard self.state.isBusy else { return }
            self.spawn(interpreter: interpreter, plan: plan)
        }
    }

    private func spawn(interpreter: String, plan: LaunchPlan) {
        statusLine = "Starting the browser agent…"

        let specData: Data
        do {
            specData = try JSONEncoder().encode(plan.spec)
        } catch {
            state = .failed
            lastError = "Couldn't encode the task: \(error.localizedDescription)"
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: interpreter)
        task.arguments = plan.arguments

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // The API key travels over the environment, never argv — argv is readable
        // by every process on the machine through `ps`.
        if let envVar = plan.apiKeyEnvVar {
            if plan.apiKey.isEmpty { env.removeValue(forKey: envVar) } else { env[envVar] = plan.apiKey }
        }
        task.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingestStdout(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text) }
        }
        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.handleTermination(status: status) }
        }

        do {
            try task.run()
            process = task
            // The spec goes over stdin rather than argv: it carries the user's
            // own rules, and argv is world-readable via `ps`. EOF tells the
            // sidecar the spec is complete.
            try stdin.fileHandleForWriting.write(contentsOf: specData)
            try stdin.fileHandleForWriting.close()
        } catch {
            state = .failed
            lastError = "Couldn't launch \(interpreter): \(error.localizedDescription)"
            statusLine = ""
        }
    }

    func cancel() {
        userCancelled = true
        guard let process, process.isRunning else {
            // Still probing for an interpreter — nothing to signal, just stop.
            if state.isBusy {
                state = .cancelled
                statusLine = "Cancelled."
            }
            return
        }
        statusLine = "Stopping…"
        // SIGTERM. The sidecar traps it, cancels the agent and closes the browser,
        // so we don't strand a headless Chrome.
        process.terminate()
    }

    /// Seed the goal without starting a run — how `/browse <goal>` hands off from
    /// the chat. Clears any previous result so the panel opens on the new goal
    /// rather than on an old report.
    func prefill(goal: String) {
        guard !state.isBusy else { return }
        clear()
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop the current result so the panel goes back to the goal field.
    func clear() {
        guard !state.isBusy else { return }
        state = .idle
        steps.removeAll()
        report = nil
        lastError = nil
        statusLine = ""
        log = ""
    }

    // MARK: - Event stream

    private func ingestStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[stdoutBuffer.startIndex..<newline])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            if !line.isEmpty { handleLine(line) }
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else {
            // Not one of ours — a stray library print. Keep it in the log rather
            // than dropping it; it's usually the clue when something misbehaves.
            if let text = String(data: data, encoding: .utf8) { appendLog(text + "\n") }
            return
        }

        switch type {
        case "ready":
            let version = obj["browserUse"] as? String ?? "?"
            statusLine = "browser-use \(version) ready."
            if let interpreter = obj["executable"] as? String, !interpreter.isEmpty {
                environment = .ready(interpreter: interpreter, version: version)
            }

        case "status":
            if let message = obj["message"] as? String { statusLine = message }

        case "step":
            let step = BrowserStep(
                number: obj["step"] as? Int ?? steps.count + 1,
                url: obj["url"] as? String ?? "",
                title: obj["title"] as? String ?? "",
                goal: obj["goal"] as? String ?? "",
                evaluation: obj["evaluation"] as? String ?? "",
                actions: obj["actions"] as? [String] ?? []
            )
            steps.append(step)
            statusLine = step.goal.isEmpty ? "Step \(step.number)" : step.goal

        case "result":
            guard let payload = obj["report"] else { return }
            do {
                let json = try JSONSerialization.data(withJSONObject: payload)
                var decoded = try JSONDecoder().decode(TaskReport.self, from: json)
                if decoded.goal.isEmpty { decoded.goal = goal }
                report = decoded
            } catch {
                lastError = "The agent returned a report Claudette couldn't read: \(error.localizedDescription)"
                appendLog("decode error: \(error)\n")
            }

        case "done":
            let count = obj["steps"] as? Int ?? steps.count
            if let seconds = obj["durationSeconds"] as? Double {
                statusLine = "Finished in \(Int(seconds))s over \(count) steps."
            } else {
                statusLine = "Finished after \(count) steps."
            }

        case "error":
            lastError = obj["message"] as? String ?? "The agent reported an error."
            if (obj["kind"] as? String) == "missing_dependency" {
                environment = .missingPackage(interpreter: obj["executable"] as? String ?? "")
            }

        default:
            break
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        // Flush a final line that didn't end in a newline.
        if !stdoutBuffer.isEmpty {
            let tail = stdoutBuffer
            stdoutBuffer = Data()
            handleLine(tail)
        }

        if userCancelled {
            state = .cancelled
            statusLine = "Cancelled."
            return
        }
        if report != nil {
            state = .finished
            return
        }
        state = .failed
        if lastError == nil {
            lastError = status == 0
                ? "The agent exited without returning anything. Check the log below."
                : "The browser agent exited with status \(status). Check the log below."
        }
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > Self.logLimit {
            log = String(log.suffix(Self.logLimit))
        }
    }

    // MARK: - Environment

    /// Probe (or re-probe) the Python situation. Runs off the main actor — it
    /// shells out once per candidate interpreter.
    func refreshEnvironment(config: BrowserAgentConfig) {
        let preferred = config.pythonPath
        Task { [weak self] in
            let result = await Self.resolveEnvironment(preferred: preferred)
            self?.environment = result
        }
    }

    /// Create a managed virtualenv under Application Support and install
    /// browser-use into it. Prefers `uv` when it's on the machine — it provisions
    /// its own Python 3.12, so this works even on a Mac whose only Python is the
    /// system 3.9 — and falls back to `venv` + `pip`.
    func installBrowserUse(config: BrowserAgentConfig) {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = "Setting up a Python environment for browser-use…\n"

        let venv = BrowserAgentConfig.managedVenvDir
        let managedPython = venv.appendingPathComponent("bin/python").path

        Task { [weak self] in
            let script = await Self.installScript(venv: venv.path)
            guard let script else {
                self?.isInstalling = false
                self?.installLog = """
                No Python 3.11 or newer found, and `uv` isn't installed either.

                Install one of these, then hit Re-check:
                  brew install uv           # smallest — provisions its own Python
                  brew install python@3.12
                """
                self?.environment = .missingPython(detail: "No Python 3.11+ and no uv on this Mac.")
                return
            }

            let result = await Self.runShell(script)
            guard let self else { return }
            self.installLog = result.output
            self.isInstalling = false
            if result.status == 0 {
                // Point future runs at the venv we just built.
                config.pythonPath = managedPython
                self.environment = await Self.resolveEnvironment(preferred: managedPython)
            } else {
                self.installLog += "\n\nInstall failed with status \(result.status)."
            }
        }
    }

    // MARK: - Discovery (off-main)

    nonisolated static func sidecarURL() -> URL? {
        if let bundled = Bundle.module.url(
            forResource: "runner",
            withExtension: "py",
            subdirectory: "browser_agent"
        ) {
            return bundled
        }
        // Running from `swift run` against the source tree rather than a built
        // .app — resolve next to this file so development needs no bundle.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services/
            .deletingLastPathComponent()   // Claudette/
            .appendingPathComponent("Resources/browser_agent/runner.py")
        return FileManager.default.isReadableFile(atPath: here.path) ? here : nil
    }

    /// Interpreters worth trying, most-preferred first.
    nonisolated static func candidateInterpreters(preferred: String) -> [String] {
        var out: [String] = []
        let trimmed = preferred.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append((trimmed as NSString).expandingTildeInPath) }
        out.append(BrowserAgentConfig.managedVenvDir.appendingPathComponent("bin/python").path)
        out += [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3"
        ]
        if let onPath = which("python3") { out.append(onPath) }
        // Preserve order while removing duplicates — `which` usually repeats a
        // Homebrew path that's already in the list.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Walk the candidates once and classify the machine.
    nonisolated static func resolveEnvironment(preferred: String) async -> BrowserAgentEnvironment {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var usablePython: String?
                for path in candidateInterpreters(preferred: preferred)
                where FileManager.default.isExecutableFile(atPath: path) {
                    let result = probe(interpreter: path)
                    guard result.exists else { continue }
                    if result.hasBrowserUse {
                        continuation.resume(returning: .ready(interpreter: path, version: result.browserUseVersion))
                        return
                    }
                    if result.versionIsSupported && usablePython == nil { usablePython = path }
                }
                if let usablePython {
                    continuation.resume(returning: .missingPackage(interpreter: usablePython))
                } else {
                    continuation.resume(returning: .missingPython(
                        detail: "Install it with `brew install python@3.12`, or `brew install uv` and let Claudette handle the rest."
                    ))
                }
            }
        }
    }

    /// Build the install script for whatever tooling this Mac has, or nil if it
    /// has neither `uv` nor a new enough Python.
    private nonisolated static func installScript(venv: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let uv = locate([
                    "/opt/homebrew/bin/uv",
                    "/usr/local/bin/uv",
                    "\(NSHomeDirectory())/.local/bin/uv"
                ]) ?? which("uv") {
                    continuation.resume(returning: """
                    set -e
                    "\(uv)" venv --python 3.12 "\(venv)"
                    "\(uv)" pip install --python "\(venv)/bin/python" --upgrade browser-use
                    "\(venv)/bin/python" -c 'from importlib.metadata import version; print("browser-use", version("browser-use"), "installed")'
                    """)
                    return
                }

                var bootstrap: String?
                for path in candidateInterpreters(preferred: "")
                where FileManager.default.isExecutableFile(atPath: path) {
                    if probe(interpreter: path).versionIsSupported { bootstrap = path; break }
                }
                guard let bootstrap else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: """
                set -e
                "\(bootstrap)" -m venv "\(venv)"
                "\(venv)/bin/python" -m pip install --upgrade pip
                "\(venv)/bin/python" -m pip install --upgrade browser-use
                "\(venv)/bin/python" -c 'from importlib.metadata import version; print("browser-use", version("browser-use"), "installed")'
                """)
            }
        }
    }

    /// Ask one interpreter what it is and whether browser-use lives in it.
    /// Deliberately reads package metadata rather than importing browser_use —
    /// the import costs about a second, the metadata read is instant.
    private nonisolated static func probe(interpreter: String) -> PythonProbe {
        let code = """
        import json, sys
        out = {"major": sys.version_info[0], "minor": sys.version_info[1], "bu": ""}
        try:
            from importlib.metadata import version
            out["bu"] = version("browser-use")
        except Exception:
            pass
        print(json.dumps(out))
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: interpreter)
        task.arguments = ["-c", code]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return PythonProbe() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let major = obj["major"] as? Int,
            let minor = obj["minor"] as? Int
        else { return PythonProbe() }
        return PythonProbe(major: major, minor: minor, browserUseVersion: obj["bu"] as? String ?? "")
    }

    private nonisolated static func locate(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func which(_ tool: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", tool]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    /// Run a bash script to completion, capturing stdout and stderr together.
    /// Used only by the install flow, which is slow and chatty and wants its
    /// output shown verbatim.
    private nonisolated static func runShell(_ script: String) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = ["-lc", script]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                } catch {
                    continuation.resume(returning: (1, "Failed to start bash: \(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                continuation.resume(returning: (task.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
